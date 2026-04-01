Set-StrictMode -Version Latest

function Get-CatalogPublisherConfig {
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

    $streamingPath = Join-Path $ServerRoot $local.Paths.Streaming
    $workPath      = Join-Path $ServerRoot $local.Paths.Work
    $logsPath      = Join-Path $ServerRoot $local.Paths.Logs

    return [pscustomobject]@{
        ServerRoot    = $ServerRoot
        Paths         = [pscustomobject]@{
            Ingest    = Join-Path $ServerRoot $local.Paths.Ingest
            Rip       = Join-Path $ServerRoot $local.Paths.Rip
            Work      = $workPath
            Streaming = $streamingPath
            Logs      = $logsPath
            Temp      = Join-Path $ServerRoot $local.Paths.Temp
        }
        Admin         = [pscustomobject]$local.Admin
        QueuePath     = Join-Path $workPath      'queues\rip-jobs.json'
        LogPath       = Join-Path $logsPath      'catalog-publisher.log'
        CatalogPath   = Join-Path $streamingPath 'catalog.json'
        IndexHtmlPath = Join-Path $streamingPath 'index.html'
        AdminHtmlPath = Join-Path $streamingPath 'admin.html'
    }
}

function Initialize-CatalogPublisherStorage {
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

Export-ModuleMember -Function Get-CatalogPublisherConfig, Initialize-CatalogPublisherStorage
