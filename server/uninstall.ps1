# Removes dcs-srs-play-audio for the current user. Run it through uninstall.cmd.
# https://github.com/flyinggab/dcs-srs-play-audio (MIT license)
# -User <name> removes it for another user (as administrator).
param([string[]]$DcsProfile, [string]$User)
$ErrorActionPreference = 'Stop'
$name = 'dcs-srs-play-audio'
$taskName = 'DCS SRS play audio'
$localAppData = $env:LOCALAPPDATA
if ($User) {
    $sid = ([Security.Principal.NTAccount]$User).Translate([Security.Principal.SecurityIdentifier]).Value
    $profileList = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    $userHome = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath $profileList).ProfileImagePath)
    $localAppData = Join-Path $userHome 'AppData\Local'
}
$appFolder = Join-Path $localAppData $name

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
