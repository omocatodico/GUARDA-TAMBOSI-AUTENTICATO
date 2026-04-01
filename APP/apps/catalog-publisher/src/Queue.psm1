Set-StrictMode -Version Latest

function Get-CatalogQueue {
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

Export-ModuleMember -Function Get-CatalogQueue
