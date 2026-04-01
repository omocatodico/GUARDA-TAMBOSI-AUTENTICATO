Set-StrictMode -Version Latest

function Get-TmdbMatcherConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerRoot
    )

    $localPsdPath = Join-Path $ServerRoot 'CONFIG\local.psd1'
    if (-not (Test-Path $localPsdPath)) {
        throw "local.psd1 not found at: $localPsdPath"
    }

    $local = Import-PowerShellDataFile -Path $localPsdPath

    return [pscustomobject]@{
        ServerRoot = $ServerRoot
        Tmdb       = [pscustomobject]@{
            ApiKey             = $local.Tmdb.ApiKey
            ReadAccessToken    = $local.Tmdb.ReadAccessToken
            LanguagePrimary    = $local.Tmdb.LanguagePrimary
            LanguageFallback   = $local.Tmdb.LanguageFallback
        }
        Tools      = [pscustomobject]@{
            FfmpegBin  = Join-Path $ServerRoot $local.Tools.FfmpegBin
            FfmpegExe  = Join-Path $ServerRoot $local.Tools.FfmpegExe
            FfprobeExe = Join-Path $ServerRoot $local.Tools.FfprobeExe
        }
        Paths      = [pscustomobject]@{
            Ingest    = Join-Path $ServerRoot $local.Paths.Ingest
            Rip       = Join-Path $ServerRoot $local.Paths.Rip
            Work      = Join-Path $ServerRoot $local.Paths.Work
            Streaming = Join-Path $ServerRoot $local.Paths.Streaming
            Logs      = Join-Path $ServerRoot $local.Paths.Logs
            Temp      = Join-Path $ServerRoot $local.Paths.Temp
        }
        QueuePath  = Join-Path $ServerRoot 'WORK\queues\rip-jobs.json'
        LogPath    = Join-Path $ServerRoot 'LOGS\tmdb-matcher.log'
    }
}

function Initialize-TmdbMatcherStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    foreach ($dir in @(
        (Split-Path -Parent $Config.LogPath),
        (Split-Path -Parent $Config.QueuePath)
    )) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

Export-ModuleMember -Function Get-TmdbMatcherConfig, Initialize-TmdbMatcherStorage
