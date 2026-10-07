# Removes dcs-srs-play-audio for the current user. Run it through uninstall.cmd.
# https://github.com/flyinggab/dcs-srs-play-audio (MIT license)
param([string[]]$DcsProfile)
$ErrorActionPreference = 'Stop'
$name = 'dcs-srs-play-audio'
$taskName = 'DCS SRS play audio'
$appFolder = Join-Path $env:LOCALAPPDATA $name

if (-not $DcsProfile) {
    $config = Join-Path $appFolder 'config.json'
    if (Test-Path -LiteralPath $config) {
        $DcsProfile = @((Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json).profiles)
    }
}

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task '$taskName'"
}
if (Test-Path -LiteralPath $appFolder) {
    Remove-Item -LiteralPath $appFolder -Recurse -Force
    Write-Host "Removed $appFolder"
}
# Only what the installer, hook and helper created. Missions are left alone.
foreach ($p in @($DcsProfile)) {
    foreach ($item in @((Join-Path $p "Scripts\Hooks\$name.lua"), (Join-Path $p "Config\$name.cfg"), (Join-Path $p $name))) {
        if (Test-Path -LiteralPath $item) {
            Remove-Item -LiteralPath $item -Recurse -Force
            Write-Host "Removed $item"
        }
    }
}
Write-Host ''
Write-Host 'Done. Restart DCS. Missions using SRSRadioCalls.lua will play their calls as trigger sounds.'
