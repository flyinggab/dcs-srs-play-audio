-- demo.lua - F10 menu for the dcs-srs-play-audio demo mission. The calls are in SRSRadioCalls.lua.
local BLUE = coalition.side.BLUE

local menu = missionCommands.addSubMenuForCoalition(BLUE, 'SRS play audio demo')
missionCommands.addCommandForCoalition(BLUE, 'Tower call on 124.0 AM', menu, SRSRadioCall, 'tower')
missionCommands.addCommandForCoalition(BLUE, 'Overlord call on 251.0 AM', menu, SRSRadioCall, 'awacs')
missionCommands.addCommandForCoalition(BLUE, 'Status', menu, function()
    local text = trigger.misc.getUserFlag('SRSRadioCall_HOOK') > 0
        and 'Calls go over SRS. Tune 124.0 AM and 251.0 AM.'
        or 'No SRS playback on this server: calls play as trigger sounds.'
    trigger.action.outTextForCoalition(BLUE, text, 15)
end)
