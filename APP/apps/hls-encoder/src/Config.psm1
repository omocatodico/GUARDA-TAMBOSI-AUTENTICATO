Set-StrictMode -Version Latest

function Get-HlsEncoderConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerRoot
    )

    $localPsdPath = Join-Path $ServerRoot 'CONFIG\local.psd1'
    $manifestPath = Join-Path $ServerRoot 'CONFIG\manifest.json'

    if (-not (Test-Path $localPsdPath)) {
        throw "local.psd1 not found at: $localPsdPath"
    }
    if (-not (Test-Path $manifestPath)) {
        throw "manifest.json not found at: $manifestPath"
    }

    $local = Import-PowerShellDataFile -Path $localPsdPath
    $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json

    $workPath      = Join-Path $ServerRoot $local.Paths.Work
    $streamingPath = Join-Path $ServerRoot $local.Paths.Streaming
    $logsPath      = Join-Path $ServerRoot $local.Paths.Logs

    return [pscustomobject]@{
        ServerRoot = $ServerRoot
        Paths      = [pscustomobject]@{
            Ingest    = Join-Path $ServerRoot $local.Paths.Ingest
            Rip       = Join-Path $ServerRoot $local.Paths.Rip
            Work      = $workPath
            Streaming = $streamingPath
            Logs      = $logsPath
            Temp      = Join-Path $ServerRoot $local.Paths.Temp
        }
        Tools      = [pscustomobject]@{
            FfmpegBin  = Join-Path $ServerRoot $local.Tools.FfmpegBin
            FfmpegExe  = Join-Path $ServerRoot $local.Tools.FfmpegExe
            FfprobeExe = Join-Path $ServerRoot $local.Tools.FfprobeExe
        }
        QueuePath  = Join-Path $workPath 'queues\rip-jobs.json'
        LogPath    = Join-Path $logsPath 'hls-encoder.log'
        Profiles   = @($manifest.profiles)
        AudioPref  = @($manifest.audioPreference)
    }
}

function Initialize-HlsEncoderStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    foreach ($dir in @(
        (Split-Path -Parent $Config.LogPath),
        (Split-Path -Parent $Config.QueuePath),
        $Config.Paths.Streaming
    )) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

Export-ModuleMember -Function Get-HlsEncoderConfig, Initialize-HlsEncoderStorage
