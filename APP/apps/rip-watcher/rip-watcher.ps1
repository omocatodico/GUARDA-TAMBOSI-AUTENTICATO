[CmdletBinding()]
param(
    [string]$ServerRoot = '',
    [int]$PollSeconds = 5,
    [switch]$RunOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ServerRoot)) {
    $ServerRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptRoot))
}
Import-Module (Join-Path $scriptRoot 'src\Config.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Logger.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Queue.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptRoot 'src\Discovery.psm1') -Force

$config = Get-RipWatcherConfig -ServerRoot $ServerRoot
Initialize-RipWatcherStorage -Config $config
Write-RipWatcherLog -Config $config -Level Info -Message 'rip-watcher started' -Data @{ serverRoot = $ServerRoot; runOnce = [bool]$RunOnce; pollSeconds = $PollSeconds }

while ($true) {
    $queue = Get-RipQueue -Config $config
    $ingestCandidates = Get-IngestCandidates -Config $config -Queue $queue
    $driveCandidates = Get-OpticalDriveCandidates -Config $config -Queue $queue

    foreach ($candidate in @($ingestCandidates) + @($driveCandidates)) {
        $job = New-RipQueueJob -Candidate $candidate
        $null = Add-RipQueueJob -Config $config -Job $job
        Write-RipWatcherLog -Config $config -Level Info -Message 'queued source for rip pipeline' -Data @{ id = $job.id; sourceType = $job.sourceType; displayName = $job.displayName; sourcePath = $job.sourcePath }
    }

    if ($RunOnce) {
        break
    }

    Start-Sleep -Seconds $PollSeconds
}

Write-RipWatcherLog -Config $config -Level Info -Message 'rip-watcher stopped' -Data @{ runOnce = [bool]$RunOnce }
