Set-StrictMode -Version Latest

function Get-TmdbQueue {
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

function Save-TmdbQueue {
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

Export-ModuleMember -Function Get-TmdbQueue, Save-TmdbQueue
