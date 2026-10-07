# dcs-srs-play-audio helper: picks up the requests written by the DCS hook and starts SRS External Audio for each.
# https://github.com/flyinggab/dcs-srs-play-audio (MIT license)
# Runs hidden as the user that runs DCS, from the scheduled task "DCS SRS play audio" created by install.cmd.
# Requests are re-validated here; nothing but External Audio is ever started.
# Config: %LOCALAPPDATA%\dcs-srs-play-audio\config.json (externalAudio, profiles). -Seconds stops it after a while (tests).
param([string]$Config = (Join-Path $env:LOCALAPPDATA 'dcs-srs-play-audio\config.json'), [int]$Seconds = 0)
$ErrorActionPreference = 'Stop'

$mutex = New-Object Threading.Mutex($false, 'Local\dcs-srs-play-audio')
if (-not $mutex.WaitOne(0)) { exit 0 }   # another copy runs

$settings = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$exe = [string]$settings.externalAudio
$folders = @($settings.profiles | ForEach-Object { Join-Path ([string]$_) 'dcs-srs-play-audio' })

function Write-Log([string]$folder, [string]$text) {
    $log = Join-Path $folder 'helper.log'
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 1MB) {
        Move-Item -LiteralPath $log -Destination ($log + '.old') -Force
    }
    Add-Content -LiteralPath $log -Value ('{0:yyyy-MM-dd HH:mm:ss.fff}Z {1}' -f (Get-Date).ToUniversalTime(), $text) -Encoding UTF8
}

# Returns @{ args = ... } for External Audio, or @{ error = ... }.
function Test-Request($request, [string]$folder) {
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $file = [string]$request.file
    if (-not $file -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($file)) -ne [IO.Path]::GetFullPath($folder)) {
        return @{ error = "the clip is not directly in $folder" }
    }
    $name = [IO.Path]::GetFileName($file)
    if ($name -notmatch '^[A-Za-z0-9_.-]+\.(ogg|mp3)$' -or $name -match '\.\.') { return @{ error = "not a plain .ogg or .mp3: $name" } }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @{ error = "no such clip: $name" } }
    $freqs, $mods = [string]$request.freqs, [string]$request.mods
    if ($freqs -notmatch '^\d+(\.\d+)?(,\d+(\.\d+)?){0,3}$') { return @{ error = "bad frequencies: $freqs" } }
    foreach ($mhz in $freqs.Split(',')) {
        $value = [double]::Parse($mhz, $invariant)
        if ($value -lt 1 -or $value -gt 1000) { return @{ error = "bad frequency: $mhz" } }
    }
    if ($mods -notmatch '^(AM|FM)(,(AM|FM)){0,3}$' -or $mods.Split(',').Count -ne $freqs.Split(',').Count) {
        return @{ error = "frequencies and modulations do not pair: $freqs / $mods" }
    }
    $side = [string]$request.coalition
    if ($side -notmatch '^[012]$') { return @{ error = "bad coalition: $side" } }
    $speaker = [string]$request.name
    if ($speaker -notmatch '^[A-Za-z0-9_-]{1,32}$') { return @{ error = "bad name: $speaker" } }
    $volume = 0.0
    if (-not [double]::TryParse([string]$request.volume, [Globalization.NumberStyles]::Float, $invariant, [ref]$volume) -or
        $volume -lt 0 -or $volume -gt 1) {
        return @{ error = "bad volume: $($request.volume)" }
    }
    $port = [string]$request.port
    if ($port -notmatch '^\d{1,5}$' -or [int]$port -lt 1 -or [int]$port -gt 65535) { return @{ error = "bad port: $port" } }
    # Start-Process joins these with spaces, so the path (which can contain spaces) is quoted.
    return @{ args = @("--file=`"$file`"", "--freqs=$freqs", "--modulations=$mods", "--coalition=$side", "--port=$port",
                       "--name=$speaker", ('--volume={0}' -f $volume.ToString('0.00', $invariant)), '--minimise') }
}

# Same rule as the hook: srsPort from Config\dcs-srs-play-audio.cfg, default 5002.
function Get-SrsPort([string]$folder) {
    $cfg = Join-Path (Split-Path $folder) 'Config\dcs-srs-play-audio.cfg'
    if (Test-Path -LiteralPath $cfg) {
        $m = Select-String -LiteralPath $cfg -Pattern '^\s*srsPort\s*=\s*(\d{1,5})\s*$' | Select-Object -First 1
        if ($m) { return [int]$m.Matches[0].Groups[1].Value }
    }
    return 5002
}

# helper.alive tells the hook we're running and SRS is up. When it goes stale, missions fall back to trigger sounds.
function Write-Heartbeat {
    $listening = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
        ForEach-Object { $_.Port })
    foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath $folder)) { continue }   # DCS has not run the hook in this profile yet
        $alive = Join-Path $folder 'helper.alive'
        if ($listening -contains (Get-SrsPort $folder)) {
            [IO.File]::WriteAllText($alive, (Get-Date).ToUniversalTime().ToString('o'))
        } elseif (Test-Path -LiteralPath $alive) {
            Remove-Item -LiteralPath $alive -Force
        }
    }
}

$ends = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [datetime]::MaxValue }
$beat = [datetime]::MinValue
while ((Get-Date) -lt $ends) {
    if (((Get-Date) - $beat).TotalSeconds -ge 2) {
        $beat = Get-Date
        try { Write-Heartbeat } catch { }
    }
    foreach ($folder in $folders) {
        try {
            $queue = Join-Path $folder 'queue'
            if (-not (Test-Path -LiteralPath $queue)) { continue }   # DCS has not run the hook in this profile yet
            $requests = @(Get-ChildItem -LiteralPath $queue -Filter '*.req' | Where-Object { $_.BaseName -match '^\d{1,15}$' })
            foreach ($item in @($requests | Sort-Object { [long]$_.BaseName })) {
                $number = $item.BaseName
                $text = $null
                try { $text = [IO.File]::ReadAllText($item.FullName) } catch { continue }   # still being renamed: next time
                Remove-Item -LiteralPath $item.FullName -Force
                try { $request = $text | ConvertFrom-Json } catch { Write-Log $folder "request $number refused: not JSON"; continue }
                $checked = Test-Request $request $folder
                if ($checked.error) { Write-Log $folder "request $number refused: $($checked.error)"; continue }
                if (-not (Test-Path -LiteralPath $exe)) { Write-Log $folder "request ${number}: External Audio not found ($exe)"; continue }
                $output = Join-Path $folder "request-$number.txt"
                Start-Process -FilePath $exe -ArgumentList $checked.args -WindowStyle Hidden -WorkingDirectory $folder `
                    -RedirectStandardOutput $output -RedirectStandardError (Join-Path $folder "request-$number.err") | Out-Null
                Write-Log $folder ("request {0}: {1} on {2} {3}, coalition {4}, as {5}, SRS port {6}" -f $number,
                    [IO.Path]::GetFileName([string]$request.file), $request.freqs, $request.mods, $request.coalition,
                    $request.name, $request.port)
            }
        } catch {
            try { Write-Log $folder "error: $($_.Exception.Message)" } catch { }
            Start-Sleep -Seconds 5
        }
    }
    Start-Sleep -Milliseconds 250
}
