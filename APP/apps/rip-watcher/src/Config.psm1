Set-StrictMode -Version Latest

function Get-RipWatcherConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerRoot
    )

    $configRoot = Join-Path $ServerRoot 'CONFIG'
    $localConfigPath = Join-Path $configRoot 'local.psd1'
    $manifestPath = Join-Path $configRoot 'manifest.json'

    if (-not (Test-Path -Path $localConfigPath)) {
        throw "Missing local config file: $localConfigPath"
    }

    if (-not (Test-Path -Path $manifestPath)) {
        throw "Missing manifest file: $manifestPath"
    }

    $localConfig = Import-PowerShellDataFile -Path $localConfigPath
    $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json

    $ripWatcherConfig = if ($localConfig.ContainsKey('RipWatcher')) {
        [pscustomobject]$localConfig.RipWatcher
    }
    else {
        [pscustomobject]@{}
    }

    $discTitleMaxAttempts = if ($ripWatcherConfig.PSObject.Properties.Name -contains 'DiscTitleMaxAttempts') {
        [int]$ripWatcherConfig.DiscTitleMaxAttempts
    }
    else {
        3
    }

    $discRetryDelaySeconds = if ($ripWatcherConfig.PSObject.Properties.Name -contains 'DiscRetryDelaySeconds') {
        [int]$ripWatcherConfig.DiscRetryDelaySeconds
    }
    else {
        8
    }

    if ($discTitleMaxAttempts -lt 1) {
        $discTitleMaxAttempts = 1
    }
    if ($discRetryDelaySeconds -lt 0) {
        $discRetryDelaySeconds = 0
    }

    $rPaths = [pscustomobject]@{
        Ingest    = Join-Path $ServerRoot $localConfig.Paths.Ingest
        Rip       = Join-Path $ServerRoot $localConfig.Paths.Rip
        Work      = Join-Path $ServerRoot $localConfig.Paths.Work
        Streaming = Join-Path $ServerRoot $localConfig.Paths.Streaming
        Logs      = Join-Path $ServerRoot $localConfig.Paths.Logs
        Temp      = Join-Path $ServerRoot $localConfig.Paths.Temp
    }

    return [pscustomobject]@{
        ServerRoot = $ServerRoot
        ConfigRoot = $configRoot
        LocalConfigPath = $localConfigPath
        ManifestPath = $manifestPath
        Paths = $rPaths
        Tools = [pscustomobject]@{
            FfmpegBin  = Join-Path $ServerRoot $localConfig.Tools.FfmpegBin
            FfmpegExe  = Join-Path $ServerRoot $localConfig.Tools.FfmpegExe
            FfprobeExe = Join-Path $ServerRoot $localConfig.Tools.FfprobeExe
            MakeMkvDir = if ($localConfig.Tools.ContainsKey('MakeMkvDir')) { Join-Path $ServerRoot $localConfig.Tools.MakeMkvDir } else { '' }
        }
        Tmdb = [pscustomobject]$localConfig.Tmdb
        Admin = [pscustomobject]$localConfig.Admin
        Caddy = [pscustomobject]@{
            AccessLogPath = Join-Path $ServerRoot $localConfig.Caddy.AccessLogPath
            ErrorLogPath  = Join-Path $ServerRoot $localConfig.Caddy.ErrorLogPath
            BaseUrl       = $localConfig.Caddy.BaseUrl
        }
        RipWatcher = [pscustomobject]@{
            DiscTitleMaxAttempts = $discTitleMaxAttempts
            DiscRetryDelaySeconds = $discRetryDelaySeconds
        }
        Manifest = $manifest
        QueuePath = Join-Path $rPaths.Work 'queues\rip-jobs.json'
        LogPath   = Join-Path $rPaths.Logs 'rip-watcher.log'
    }
}

function Initialize-RipWatcherStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $queueDir = Split-Path -Parent $Config.QueuePath
    foreach ($path in @($Config.Paths.Ingest, $Config.Paths.Rip, $Config.Paths.Work, $Config.Paths.Streaming, $Config.Paths.Logs, $Config.Paths.Temp, $queueDir)) {
        if (-not (Test-Path -Path $path)) {
            New-Item -Path $path -ItemType Directory | Out-Null
        }
    }

    if (-not (Test-Path -Path $Config.QueuePath)) {
        '[]' | Set-Content -Path $Config.QueuePath -Encoding UTF8
    }

    if (-not (Test-Path -Path $Config.LogPath)) {
        New-Item -Path $Config.LogPath -ItemType File | Out-Null
    }
}

Export-ModuleMember -Function Get-RipWatcherConfig, Initialize-RipWatcherStorage
