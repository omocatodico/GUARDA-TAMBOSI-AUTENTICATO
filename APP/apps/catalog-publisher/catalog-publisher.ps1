[CmdletBinding()]
param(
    [string]$ServerRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ServerRoot)) {
    $ServerRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptRoot))
}
Import-Module (Join-Path $scriptRoot 'src\Config.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Logger.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Queue.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Publisher.psm1') -Force -DisableNameChecking

$config = Get-CatalogPublisherConfig -ServerRoot $ServerRoot
Initialize-CatalogPublisherStorage -Config $config

Write-CatalogPublisherLog -Config $config -Level Info -Message 'catalog-publisher started' -Data @{}

$queue = Get-CatalogQueue -Config $config
$items = Get-CatalogItems -Queue $queue -StreamingRoot $config.Paths.Streaming

$catalog = [ordered]@{
    generatedAt = (Get-Date).ToString('s')
    count = @($items).Count
    items = @($items)
}

$catalog | ConvertTo-Json -Depth 10 | Set-Content -Path $config.CatalogPath -Encoding UTF8

Write-CatalogPublisherLog -Config $config -Level Info -Message 'catalog generated' -Data @{ count = @($items).Count; catalog = $config.CatalogPath }
Write-CatalogPublisherLog -Config $config -Level Info -Message 'catalog-publisher finished' -Data @{}
