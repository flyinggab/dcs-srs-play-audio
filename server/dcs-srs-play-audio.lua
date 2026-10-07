-- dcs-srs-play-audio: DCS server hook that plays a mission's radio calls over SRS.
-- https://github.com/flyinggab/dcs-srs-play-audio (MIT license)
-- install.cmd puts it in <Saved Games>\<profile>\Scripts\Hooks.
--
-- SRSRadioCalls.lua in the mission requests a call by writing its number into mission flags (a 16-slot ring plus a
-- counter). This hook reads the call list from the .miz, polls the flags, extracts the clip and writes a request file
-- for the helper (dcs-srs-play-audio.ps1), which starts SRS External Audio.
-- Why the detour: hooks can't start programs (os.execute is a no-op, the dedicated server has no io.popen), and the
-- Lua state a hook can query sees mission flags but not the mission script's globals.
--
-- Optional: <profile>\Config\dcs-srs-play-audio.cfg containing "srsPort = 5002".
local S = Sim or DCS
local NAME = 'dcs-srs-play-audio'
local VERSION = 1
local POLL = 0.5
local SLOTS = 16
local CALLS_FILE = 'l10n/DEFAULT/SRSRadioCalls.lua'
-- Sets the ready flag (0 makes the mission fall back to trigger sounds) and returns "counter:slot1,slot2,...".
local function readCode(marker)
    return 'trigger.action.setUserFlag("SRSRadioCall_HOOK", ' .. marker .. ') local s = {} for i = 1, ' .. SLOTS ..
           ' do s[i] = trigger.misc.getUserFlag("SRSRadioCall_" .. i) end' ..
           ' return trigger.misc.getUserFlag("SRSRadioCall_N") .. ":" .. table.concat(s, ",")'
end

local root = lfs.writedir() .. NAME   -- lfs.writedir() ends with a backslash
local cache, queue = root .. '\\', root .. '\\queue\\'
lfs.mkdir(root)
lfs.mkdir(root .. '\\queue')

local function log(text) net.log(NAME .. ': ' .. text) end
local zipLoaded, minizip = pcall(require, 'minizip')

-- SRS port of this server, 5002 unless the cfg file says otherwise.
local function readPort()
    local chunk = loadfile(lfs.writedir() .. 'Config\\' .. NAME .. '.cfg')
    if not chunk then return 5002 end
    local box = {}
    setfenv(chunk, box)
    local ok = pcall(chunk)
    local port = tonumber(box.srsPort)
    if ok and port and port >= 1 and port <= 65535 and port == math.floor(port) then return port end
    log('Config\\' .. NAME .. '.cfg: srsPort is not a port number; using 5002')
    return 5002
end
local PORT = readPort()

-- The helper touches helper.alive every 2 s while it runs and SRS is listening.
local ALIVE = root .. '\\helper.alive'
local function helperReady()
    local a = lfs.attributes(ALIVE)
    return a ~= nil and type(a.modification) == 'number' and os.time() - a.modification <= 10
end

local ready = nil        -- helper state at the last poll
local loaded = false
local calls = nil        -- validated calls by number, false if the mission has none
local seen = 0           -- requests handled so far (SRSRadioCall_N)
local copied = {}        -- clips already extracted for this mission
local lastError = nil    -- don't repeat the same error every poll
local nextPoll = 0
local sent = os.time() * 100   -- request file numbers, unique across DCS restarts

local function problem(text)
    if text ~= lastError then log(text) end
    lastError = text
end

-- Remove the previous mission's clips and External Audio output.
local function emptyCache()
    for name in lfs.dir(root) do
        local lower = name:lower()
        if lower:match('%.ogg$') or lower:match('%.mp3$') or lower:match('^request%-%d+%.txt$') or
           lower:match('^request%-%d+%.err$') then
            os.remove(cache .. name)
        end
    end
    copied = {}
end

local function fromMission(name)
    if not zipLoaded or type(minizip) ~= 'table' then return nil, 'DCS module minizip not available' end
    local miz = S.getMissionFilename()
    local zip = miz and minizip.unzOpen(miz, 'rb')
    if not zip then return nil, 'cannot open the mission file ' .. tostring(miz) end
    local data
    if zip:unzLocateFile(name) then data = zip:unzReadAllCurrentFile(true) end
    zip:unzClose()
    if type(data) ~= 'string' or #data == 0 then return nil, 'not in the mission: ' .. name end
    return data
end

-- Runs SRSRadioCalls.lua in an empty environment (no os, io, require, net) just to read SRS_RADIO_CALLS.
local function callList(text)
    local chunk, err = loadstring(text, 'SRSRadioCalls.lua')
    if not chunk then return nil, 'does not load: ' .. tostring(err) end
    local box = { pairs = pairs, ipairs = ipairs, next = next, type = type, tostring = tostring, tonumber = tonumber,
                  string = { format = string.format, sub = string.sub, lower = string.lower, upper = string.upper },
                  table = { sort = table.sort, insert = table.insert, concat = table.concat },
                  math = { floor = math.floor, min = math.min, max = math.max },
                  coalition = { side = { NEUTRAL = 0, RED = 1, BLUE = 2 } },
                  trigger = { action = {}, misc = {} }, env = {}, timer = {}, missionCommands = {} }
    setfenv(chunk, box)
    local limited = type(debug) == 'table' and type(debug.sethook) == 'function'
    if limited then debug.sethook(function() error('SRSRadioCalls.lua runs too long', 0) end, '', 1000000) end
    local ran, runErr = pcall(chunk)
    if limited then debug.sethook() end
    if type(box.SRS_RADIO_CALLS) ~= 'table' then
        return nil, ran and 'it sets no SRS_RADIO_CALLS table' or ('it failed: ' .. tostring(runErr))
    end
    return box.SRS_RADIO_CALLS
end

-- Requests are built only from values that pass here.
local function check(entry)
    if type(entry) ~= 'table' then return nil, 'not a table' end
    local file, name = entry.file, entry.name
    local freqs = type(entry.freqs) == 'number' and tostring(entry.freqs) or entry.freqs
    local mods = entry.mods
    local side, volume = tonumber(entry.coalition or 2), tonumber(entry.volume or 1)
    if type(file) ~= 'string' or not file:match('^[%w_%-%.]+$') or file:find('%.%.') or
       not (file:lower():match('%.ogg$') or file:lower():match('%.mp3$')) then
        return nil, 'file is not a plain .ogg or .mp3 name'
    end
    if type(freqs) ~= 'string' or type(mods) ~= 'string' then return nil, 'freqs and mods must be text' end
    local count = 0
    for f in (freqs .. ','):gmatch('([^,]*),') do
        local mhz = tonumber(f)
        if not f:match('^%d+%.?%d*$') or not mhz or mhz < 1 or mhz > 1000 then return nil, 'bad frequency: ' .. freqs end
        count = count + 1
    end
    local modCount = 0
    for m in (mods .. ','):gmatch('([^,]*),') do
        if m ~= 'AM' and m ~= 'FM' then return nil, 'bad modulation: ' .. mods end
        modCount = modCount + 1
    end
    if count ~= modCount or count > 4 then return nil, 'frequencies and modulations do not pair: ' .. freqs .. ' / ' .. mods end
    if side ~= 0 and side ~= 1 and side ~= 2 then return nil, 'bad coalition' end
    if type(name) ~= 'string' or not name:match('^[%w_%-]+$') or #name > 32 then return nil, 'bad name' end
    if not volume or volume < 0 or volume > 1 then return nil, 'bad volume' end
    return { file = file, freqs = freqs, mods = mods, side = tostring(side), name = name,
             volume = string.format('%.2f', volume) }
end

local function loadCalls()
    calls = false
    local text, err = fromMission(CALLS_FILE)
    if not text then log('no SRS radio calls in this mission (' .. err .. ')') return end
    local list, why = callList(text)
    if not list then log(CALLS_FILE .. ': ' .. why) return end
    local names = {}
    for key in pairs(list) do
        if type(key) == 'string' then names[#names + 1] = key end
    end
    table.sort(names)
    local checked, usable = {}, 0
    for i, key in ipairs(names) do
        local call, bad = check(list[key])
        if call then
            call.key = key
            checked[i], usable = call, usable + 1
        else
            log('call ' .. key .. ' refused: ' .. bad)
        end
    end
    log(string.format('%d calls listed, %d usable: %s; SRS port %d', #names, usable, table.concat(names, ', '), PORT))
    if usable > 0 then calls = checked end
end

local function clipFile(file)
    local path = cache .. file
    if copied[file] and lfs.attributes(path) then return path end
    local data, err = fromMission('l10n/DEFAULT/' .. file)
    if not data then return nil, err end
    local f = io.open(path, 'wb')
    if not f then return nil, 'cannot write ' .. path end
    f:write(data)
    f:close()
    copied[file] = true
    return path
end

local function waiting()
    local n = 0
    for name in lfs.dir(root .. '\\queue') do
        if name:match('%.req$') then n = n + 1 end
    end
    return n
end

-- Written to a .tmp file and renamed so the helper never reads a partial request.
local function send(call)
    local path, err = clipFile(call.file)
    if not path then return nil, err end
    sent = sent + 1
    local number = string.format('%.0f', sent)   -- %d overflows past 2^31 in DCS's Lua
    local tmp = queue .. number .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return nil, 'cannot write ' .. tmp end
    f:write(net.lua2json({ file = path, freqs = call.freqs, mods = call.mods, coalition = call.side, name = call.name,
                           volume = call.volume, port = tostring(PORT) }))
    f:close()
    local renamed, rerr = os.rename(tmp, queue .. number .. '.req')
    if not renamed then
        os.remove(tmp)
        return nil, 'cannot rename ' .. tmp .. ': ' .. tostring(rerr)
    end
    return number
end

-- Lua state that sees the mission's flags: 'server' on DCS 2.9, 'scripting' in ED's API notes. Retried every 10 s.
local ROUTES = { 'server', 'scripting' }
local PROBE = 'return "' .. NAME .. ' probe " .. tostring(type(trigger) == "table")'
local route, nextProbe = nil, 0

local function findRoute(now)
    local tried = {}
    for _, state in ipairs(ROUTES) do
        local called, answer = pcall(net.dostring_in, state, PROBE)
        tried[#tried + 1] = state .. ' -> ' .. (called and string.format('%q', tostring(answer)) or ('error ' .. tostring(answer)))
        if called and answer == NAME .. ' probe true' then route = state break end
    end
    local text = 'reaching the mission: ' .. table.concat(tried, '; ')
    if route then
        log(text .. '; using ' .. route)
    else
        nextProbe = now + 10
        problem(text .. '; none answers (probe again every 10 s)')
    end
end

local function poll(now)
    if calls == nil then loadCalls() end
    if not calls then loaded = false return end   -- no calls in this mission
    if not route then
        if now < nextProbe then return end
        findRoute(now)
        if not route then return end
    end
    local nowReady = helperReady()
    if nowReady ~= ready then
        ready = nowReady
        log(ready and 'the helper is ready: calls go over SRS' or
            'the helper is not ready (not running, or this server\'s SRS does not listen): calls fall back to trigger sounds')
    end
    local called, answer = pcall(net.dostring_in, route, readCode(ready and VERSION or 0))
    if not called or type(answer) ~= 'string' then problem('cannot read the mission flags: ' .. tostring(answer)) return end
    local count, ring = answer:match('^([^:]+):(.*)$')
    count = tonumber(count)
    if not count then problem('unexpected answer from the mission: ' .. answer) return end
    if count < seen then seen = 0 end   -- mission restarted
    if count == seen then return end
    if not ready then   -- requested just before the mission saw the flag drop
        log(string.format('%d call(s) asked while the helper was not ready: not played', count - seen))
        seen = count
        return
    end
    local slots = {}
    for v in (ring .. ','):gmatch('([^,]*),') do slots[#slots + 1] = tonumber(v) end
    if count - seen > SLOTS then
        log(string.format('%d calls asked within half a second: the first %d are lost', count - seen, count - seen - SLOTS))
        seen = count - SLOTS
    end
    for k = seen + 1, count do
        local number = slots[(k - 1) % SLOTS + 1]
        local call = number and calls[number]
        if not call then
            log('call number ' .. tostring(number) .. ' asked, but it is not listed (or was refused)')
        else
            local request, err = send(call)
            if request then
                lastError = nil
                log(string.format('call %s: %s on %s %s, coalition %s, as %s, volume %s (request %s)', call.key,
                                  call.file, call.freqs, call.mods, call.side, call.name, call.volume, request))
            else
                problem('call ' .. call.key .. ', ' .. call.file .. ': ' .. err)
            end
        end
    end
    seen = count
    local backlog = waiting()
    if backlog > 3 then
        problem(backlog .. ' requests wait in the queue: is the helper task "DCS SRS play audio" running?')
    end
end

local callbacks = {}

function callbacks.onSimulationFrame()
    if not loaded then return end
    local now = S.getRealTime()
    if now < nextPoll then return end
    nextPoll = now + POLL
    local ok, err = pcall(poll, now)
    if not ok then problem('error: ' .. tostring(err)) end
end

function callbacks.onMissionLoadEnd()
    loaded, calls, seen, lastError, nextPoll = true, nil, 0, nil, 0
    route, nextProbe, ready = nil, 0, nil
    local ok, err = pcall(emptyCache)
    if not ok then log('cannot empty ' .. root .. ': ' .. tostring(err)) end
end

function callbacks.onSimulationStop()
    loaded = false
end

S.setUserCallbacks(callbacks)
log('version ' .. VERSION .. ' loaded; minizip ' .. (zipLoaded and 'available' or 'MISSING') .. '; SRS port ' .. PORT ..
    '; requests go to ' .. queue)
