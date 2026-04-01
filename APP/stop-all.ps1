[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$NoCaddy,
    [switch]$NoPowerShell
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-StopLine {
    param(
        [string]$Level,
        [string]$Message
    )

    $ts = (Get-Date).ToString('s')
    Write-Output ("[{0}] [{1}] {2}" -f $ts, $Level.ToUpperInvariant(), $Message)
}

function Get-PowerShellTargets {
    $scriptPatterns = @(
        'run-all.ps1',
        'admin-api.ps1',
        'apps\\rip-watcher\\rip-watcher.ps1',
        'apps\\rip-watcher\\rip-worker.ps1',
        'apps\\tmdb-matcher\\tmdb-matcher.ps1',
        'apps\\hls-encoder\\hls-encoder.ps1',
        'apps\\catalog-publisher\\catalog-publisher.ps1'
    )

    $processes = Get-CimInstance -ClassName Win32_Process |
        Where-Object { $_.Name -in @('powershell.exe', 'pwsh.exe') }

    $targets = @()
    foreach ($proc in $processes) {
        $cmd = [string]$proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) {
            continue
        }

        foreach ($pattern in $scriptPatterns) {
            if ($cmd -match [regex]::Escape($pattern)) {
                $targets += $proc
                break
            }
        }
    }

    return $targets | Sort-Object -Property ProcessId -Unique
}

function Get-CaddyTargets {
    [CmdletBinding()]
    param()

    $targets = @()

    $byProcess = @(
        Get-Process -Name 'caddy' -ErrorAction SilentlyContinue
        Get-Process -Name 'caddy_windows_amd64' -ErrorAction SilentlyContinue
    )
    if ($byProcess.Count -gt 0) {
        $targets += $byProcess
    }

    $byCim = Get-CimInstance -ClassName Win32_Process |
        Where-Object {
            $_.Name -match '^caddy(\.exe)?$|^caddy_windows_amd64(\.exe)?$' -or
            [string]$_.ExecutablePath -match '\\TOOLS\\caddy\\bin\\' -or
            [string]$_.CommandLine -match '\\TOOLS\\caddy\\bin\\'
        }

    foreach ($proc in @($byCim)) {
        $targets += [pscustomobject]@{
            Id = [int]$proc.ProcessId
            ProcessName = [string]$proc.Name
        }
    }

    return @($targets | Sort-Object -Property Id -Unique)
}

function Stop-ProcessTreeSafely {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$ProcessId,

        [Parameter(Mandatory)]
        [string]$ProcessName
    )

    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    $stillRunning = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $stillRunning) {
        & taskkill.exe /PID $ProcessId /T /F | Out-Null
        Start-Sleep -Milliseconds 300
        $stillRunning = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    }

    return ($null -eq $stillRunning)
}

$stoppedPowerShell = 0
$stoppedCaddy = 0

if (-not $NoPowerShell) {
    Write-StopLine -Level Info -Message 'Ricerca processi PowerShell pipeline in corso...'
    $targets = @(Get-PowerShellTargets)

    if ($targets.Count -eq 0) {
        Write-StopLine -Level Info -Message 'Nessun processo PowerShell pipeline trovato.'
    }
    else {
        foreach ($target in $targets) {
            $desc = "PID={0} Name={1}" -f $target.ProcessId, $target.Name
            if ($PSCmdlet.ShouldProcess($desc, 'Stop-Process -Force')) {
                Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue
                Write-StopLine -Level Warning -Message ("Terminato processo {0}" -f $desc)
                $stoppedPowerShell++
            }
        }
    }
}
else {
    Write-StopLine -Level Info -Message 'Skip stop processi PowerShell richiesto (-NoPowerShell).'
}

if (-not $NoCaddy) {
    Write-StopLine -Level Info -Message 'Ricerca processi Caddy in corso...'
    $caddyTargets = @(Get-CaddyTargets)

    if ($caddyTargets.Count -eq 0) {
        Write-StopLine -Level Info -Message 'Nessun processo Caddy trovato.'
    }
    else {
        foreach ($target in $caddyTargets) {
            $desc = "PID={0} Name={1}" -f $target.Id, $target.ProcessName
            if ($PSCmdlet.ShouldProcess($desc, 'Stop-Process -Force')) {
                $stopped = Stop-ProcessTreeSafely -ProcessId $target.Id -ProcessName $target.ProcessName
                if ($stopped) {
                    Write-StopLine -Level Warning -Message ("Terminato processo {0}" -f $desc)
                    $stoppedCaddy++
                }
                else {
                    Write-StopLine -Level Error -Message ("Impossibile terminare processo {0}" -f $desc)
                }
            }
        }
    }
}
else {
    Write-StopLine -Level Info -Message 'Skip stop Caddy richiesto (-NoCaddy).'
}

Write-StopLine -Level Info -Message ("Completato. Processi fermati: PowerShell={0}, Caddy={1}" -f $stoppedPowerShell, $stoppedCaddy)
