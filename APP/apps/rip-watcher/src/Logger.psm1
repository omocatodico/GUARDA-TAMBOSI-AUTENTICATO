Set-StrictMode -Version Latest

function Write-RipWatcherLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,

        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [hashtable]$Data = @{}
    )

    $record = [ordered]@{
        ts = (Get-Date).ToString('s')
        app = 'rip-watcher'
        level = $Level.ToLowerInvariant()
        msg = $Message
        data = $Data
    }

    $json = ($record | ConvertTo-Json -Compress -Depth 6)
    Add-Content -Path $Config.LogPath -Value $json
    Write-Output $json
}

Export-ModuleMember -Function Write-RipWatcherLog
