# Installs dcs-srs-play-audio for the current user (the one running the DCS server). Run it through install.cmd.
# https://github.com/flyinggab/dcs-srs-play-audio (MIT license)
# Options: -DcsProfile <folder>[,<folder>], -ExternalAudio <exe>, -SrsPort <port>, -NoTask (skip the scheduled task).
param([string[]]$DcsProfile, [string]$ExternalAudio, [int]$SrsPort = 0, [switch]$NoTask)
$ErrorActionPreference = 'Stop'
$name = 'dcs-srs-play-audio'
$taskName = 'DCS SRS play audio'
$here = $PSScriptRoot

function Say([string]$text) { Write-Host $text }
function Stop-Install([string]$text) { Write-Host ''; Write-Host "NOT INSTALLED: $text" -ForegroundColor Red; exit 1 }

Say 'dcs-srs-play-audio installer'
Say ''
Get-ChildItem -LiteralPath (Split-Path $here) -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# DCS server profiles
if (-not $DcsProfile) {
    $savedGames = Join-Path $env:USERPROFILE 'Saved Games'
    $shellFolders = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $known = (Get-ItemProperty -LiteralPath $shellFolders -ErrorAction SilentlyContinue).'{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}'
    if ($known) { $savedGames = [Environment]::ExpandEnvironmentVariables($known) }
    $DcsProfile = @(Get-ChildItem -LiteralPath $savedGames -Directory -Filter 'DCS*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Config\serverSettings.lua') } |
        ForEach-Object { $_.FullName })
    if (-not $DcsProfile) {
        Stop-Install ("no DCS server profile found in $savedGames. Start the DCS server once as this user, or use " +
                      '-DcsProfile <folder>.')
    }
}
foreach ($p in $DcsProfile) { if (-not (Test-Path -LiteralPath $p)) { Stop-Install "no such folder: $p" } }
Say ('DCS profiles: ' + ($DcsProfile -join ', '))

# External Audio and .NET
if (-not $ExternalAudio) {
    $candidates = @()
    $srs = (Get-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\DCS-SR-Standalone' -ErrorAction SilentlyContinue).SRPathStandalone
    if ($srs) { $candidates += Join-Path $srs 'ExternalAudio\DCS-SR-ExternalAudio.exe' }
    $candidates += Join-Path $env:ProgramFiles 'DCS-SimpleRadio-Standalone\ExternalAudio\DCS-SR-ExternalAudio.exe'
    $candidates += 'C:\ProgramData\srs-server\ExternalAudio\DCS-SR-ExternalAudio.exe'
    $ExternalAudio = @($candidates | Where-Object { Test-Path -LiteralPath $_ })[0]
    if (-not $ExternalAudio) {
        Stop-Install ('DCS-SR-ExternalAudio.exe not found. It ships with SRS, in the ExternalAudio folder. Use ' +
                      '-ExternalAudio <path to the exe>.')
    }
}
if (-not (Test-Path -LiteralPath $ExternalAudio)) { Stop-Install "no such file: $ExternalAudio" }
Say "External Audio: $ExternalAudio"

function Test-ExternalAudio {
    $out = Join-Path $env:TEMP "$name-help.txt"
    $p = Start-Process -FilePath $ExternalAudio -ArgumentList '--help' -NoNewWindow -PassThru -RedirectStandardOutput $out `
        -RedirectStandardError "$out.err"
    if (-not $p.WaitForExit(60000)) { $p.Kill(); return 'it did not answer within 60 s' }
    $help = ((Get-Content -LiteralPath $out, "$out.err" -ErrorAction SilentlyContinue) -join "`n")
    Remove-Item -LiteralPath $out, "$out.err" -ErrorAction SilentlyContinue
    if ($help -match '(?i)install.*\.NET|\.NET.*(required|not found)|hostfxr') { return 'dotnet' }
    if ($help -notmatch '--freqs') { return 'it did not list its options' }
    return $null
}
$problem = Test-ExternalAudio
if ($problem -eq 'dotnet') {
    Say ''
    Say 'External Audio needs the .NET Desktop Runtime 10 (x64), which is not installed.'
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget -and (Read-Host 'Install it with winget now? Windows will ask for admin rights. [y/N]') -match '^[yY]') {
        & $winget.Source install --id Microsoft.DotNet.DesktopRuntime.10 --exact --accept-source-agreements --accept-package-agreements
        $problem = Test-ExternalAudio
    }
    if ($problem -eq 'dotnet') {
        Stop-Install ('install the .NET Desktop Runtime 10 (x64) from https://dotnet.microsoft.com/download/dotnet/10.0 ' +
                      'and run install.cmd again.')
    }
}
if ($problem) { Stop-Install "External Audio does not start: $problem" }
Say 'External Audio OK'

# Hook, plus the SRS port per profile when it isn't 5002
foreach ($p in $DcsProfile) {
    $hooks = Join-Path $p 'Scripts\Hooks'
    New-Item -ItemType Directory -Force -Path $hooks | Out-Null
    Copy-Item -LiteralPath (Join-Path $here "$name.lua") -Destination (Join-Path $hooks "$name.lua") -Force
    $port = $SrsPort
    if (-not $port -and $DcsProfile.Count -gt 1) {
        $answer = Read-Host "SRS port of the server $(Split-Path $p -Leaf) [5002]"
        if ($answer -match '^\d{1,5}$') { $port = [int]$answer }
    }
    $cfg = Join-Path $p "Config\$name.cfg"
    if ($port -and $port -ne 5002) {
        if ($port -lt 1 -or $port -gt 65535) { Stop-Install "not a port: $port" }
        New-Item -ItemType Directory -Force -Path (Split-Path $cfg) | Out-Null
        Set-Content -LiteralPath $cfg -Value "srsPort = $port" -Encoding ASCII
        Say "Hook: $hooks (SRS port $port)"
    } else {
        Remove-Item -LiteralPath $cfg -ErrorAction SilentlyContinue
        Say "Hook: $hooks (SRS port 5002)"
        $port = 5002
    }
    if (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
        Say "  warning: nothing is listening on port $port. Is the SRS server running?"
    }
}

# Helper and scheduled task
$appFolder = Join-Path $env:LOCALAPPDATA $name
New-Item -ItemType Directory -Force -Path $appFolder | Out-Null
$helper = Join-Path $appFolder "$name.ps1"
Copy-Item -LiteralPath (Join-Path $here "$name.ps1") -Destination $helper -Force
$config = [ordered]@{ externalAudio = $ExternalAudio; profiles = @($DcsProfile) }
[IO.File]::WriteAllText((Join-Path $appFolder 'config.json'), ($config | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
Say "Helper: $helper"
if (-not $NoTask) {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helper`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Force | Out-Null
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 2
    Say "Scheduled task '$taskName': $((Get-ScheduledTask -TaskName $taskName).State)"
}

Say ''
Say 'Done. Restart DCS so it loads the hook.'
