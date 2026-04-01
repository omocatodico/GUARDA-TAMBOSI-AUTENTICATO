Set-StrictMode -Version Latest

function Write-CatalogPublisherLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,

        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Data = @{}
    )

    $entry = [ordered]@{
        ts    = (Get-Date).ToString('s')
        app   = 'catalog-publisher'
        level = $Level.ToLower()
        msg   = $Message
        data  = $Data
    }

    $line = $entry | ConvertTo-Json -Compress -Depth 8
    $line | Out-File -FilePath $Config.LogPath -Append -Encoding UTF8
    Write-Output $line
}

Export-ModuleMember -Function Write-CatalogPublisherLog
