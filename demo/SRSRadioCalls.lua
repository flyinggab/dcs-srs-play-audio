-- SRSRadioCalls.lua - dcs-srs-play-audio, https://github.com/flyinggab/dcs-srs-play-audio (MIT license)
--
-- Load this file with DO SCRIPT FILE at mission start (keep the file name), then play a call from any trigger with
-- DO SCRIPT: SRSRadioCall('tower')
-- On a server running dcs-srs-play-audio the clip goes out over SRS on the call's frequencies. Anywhere else it plays
-- as a normal trigger sound for the call's coalition.
--
--   file       clip in the mission (.ogg or .mp3)
--   freqs      MHz, comma separated for several: '251' or '251,305'
--   mods       AM or FM for each frequency: 'AM' or 'AM,AM'
--   name       speaker name shown in SRS, no spaces
--   coalition  2 blue (default), 1 red, 0 everyone
--   volume     0 to 1 (default 1)
SRS_RADIO_CALLS = {
    tower   = { file = 'demo-tower-124.ogg', freqs = '124', mods = 'AM', name = 'Batumi_Tower' },
    awacs   = { file = 'demo-awacs-251.ogg', freqs = '251', mods = 'AM', name = 'Overlord' },
    welcome = { file = 'demo-welcome.ogg',   freqs = '124', mods = 'AM', name = 'Batumi_Tower' },
}

-- No need to edit below this line.
do
    local SLOTS = 16   -- must match the server hook
    local keys = {}
    for key in pairs(SRS_RADIO_CALLS) do
        if type(key) == 'string' then keys[#keys + 1] = key end
    end
    table.sort(keys)   -- the hook numbers calls the same way
    local number = {}
    for i, key in ipairs(keys) do number[key] = i end

    function SRSRadioCall(key)
        local call = SRS_RADIO_CALLS[key]
        if not call then
            env.error('SRSRadioCall: no call named ' .. tostring(key) .. ' in SRS_RADIO_CALLS')
            return
        end
        if trigger.misc.getUserFlag('SRSRadioCall_HOOK') > 0 then
            local n = trigger.misc.getUserFlag('SRSRadioCall_N') + 1
            trigger.action.setUserFlag('SRSRadioCall_' .. ((n - 1) % SLOTS + 1), number[key])
            trigger.action.setUserFlag('SRSRadioCall_N', n)
        elseif (call.coalition or 2) == 0 then
            trigger.action.outSound('l10n/DEFAULT/' .. call.file)
        else
            trigger.action.outSoundForCoalition(call.coalition or 2, 'l10n/DEFAULT/' .. call.file)
        end
    end
end
