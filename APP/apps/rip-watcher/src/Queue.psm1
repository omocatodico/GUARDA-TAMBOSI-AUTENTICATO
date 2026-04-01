Set-StrictMode -Version Latest

function Get-RipQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    if (-not (Test-Path -Path $Config.QueuePath)) {
        return ,@()
    }

    $raw = Get-Content -Path $Config.QueuePath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return ,@()
    }

    $items = $raw | ConvertFrom-Json
    if ($null -eq $items) {
        return ,@()
    }

    return ,@($items)
}

function Save-RipQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,

        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$Queue
    )

    $Queue | ConvertTo-Json -Depth 8 | Set-Content -Path $Config.QueuePath -Encoding UTF8
}

function Test-RipQueueFingerprint {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$Queue,

        [Parameter(Mandatory)]
        [string]$Fingerprint,

        [string]$SourcePath = ''
    )

    foreach ($item in $Queue) {
        # Exact fingerprint match (same file, same mtime/size)
        if ($item.fingerprint -eq $Fingerprint) {
            return $true
        }
        # Same path already encoded — block re-queuing even if mtime/size differ
        if ($item.status -eq 'encoded' `
                -and -not [string]::IsNullOrEmpty($SourcePath) `
                -and -not [string]::IsNullOrEmpty([string]$item.sourcePath) `
                -and ([string]$item.sourcePath).ToLowerInvariant() -eq $SourcePath.ToLowerInvariant()) {
            return $true
        }
    }

    return $false
}

function New-RipQueueJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Candidate
    )

    return [pscustomobject]@{
        id = [guid]::NewGuid().ToString()
        createdAt = (Get-Date).ToString('s')
        status = 'queued'
        sourceType = $Candidate.SourceType
        sourcePath = $Candidate.SourcePath
        displayName = $Candidate.DisplayName
        fingerprint = $Candidate.Fingerprint
        nextAction = $Candidate.NextAction
        details = $Candidate.Details
    }
}

function Add-RipQueueJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,

        [Parameter(Mandatory)]
        [pscustomobject]$Job
    )

    $queue = Get-RipQueue -Config $Config
    if (Test-RipQueueFingerprint -Queue $queue -Fingerprint $Job.fingerprint) {
        return $false
    }

    $updatedQueue = @($queue) + $Job
    Save-RipQueue -Config $Config -Queue $updatedQueue
    return $true
}

Export-ModuleMember -Function Get-RipQueue, Save-RipQueue, Test-RipQueueFingerprint, New-RipQueueJob, Add-RipQueueJob
