<#
.SYNOPSIS
    Gestione del servizio Windows "GUARDA TAMBOSI".

.DESCRIPTION
    Installa, disinstalla, avvia, ferma o mostra lo stato del servizio Windows.
    Si auto-eleva ad amministratore quando necessario.

.PARAMETER Action
    install   - Compila l'exe, installa il servizio e lo avvia.
    uninstall - Ferma e rimuove il servizio.
    start     - Avvia il servizio (deve essere gia' installato).
    stop      - Ferma il servizio.
    status    - Mostra lo stato corrente.
    compile   - Ri-compila solo l'exe del servizio (senza installare).

.EXAMPLE
    # Dalla cartella APP (non richiede admin -- si auto-eleva):
    powershell -ExecutionPolicy Bypass -File service.ps1 install
    powershell -ExecutionPolicy Bypass -File service.ps1 uninstall
    powershell -ExecutionPolicy Bypass -File service.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'start', 'stop', 'status', 'compile')]
    [string]$Action = 'status',

    # install senza avviare subito
    [switch]$NoStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName = 'GuardaTambosi'
$DisplayName = 'GUARDA TAMBOSI'
$Description = 'Pipeline di rip, encoding e streaming GUARDA TAMBOSI (Caddy, admin-api, hls-encoder, rip-watcher, tmdb-matcher, catalog-publisher).'

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$serviceExe = Join-Path $scriptDir 'movieserver-service.exe'
$serviceCs  = Join-Path $scriptDir 'tools\MovieServerService.cs'

# ── Colori ──────────────────────────────────────────────────────────────────
function Write-Line {
    param([string]$Msg, [string]$Color = 'White')
    Write-Host $Msg -ForegroundColor $Color
}

function Write-Ok    { param([string]$m) Write-Line "  [OK]  $m" 'Green'  }
function Write-Info  { param([string]$m) Write-Line "  [..]  $m" 'Cyan'   }
function Write-Warn  { param([string]$m) Write-Line "  [!]   $m" 'Yellow' }
function Write-Err   { param([string]$m) Write-Line "  [ERR] $m" 'Red'    }

# ── Verifica admin ──────────────────────────────────────────────────────────
function Test-Admin {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Auto-elevazione per azioni che richiedono privilegi
if ($Action -in @('install', 'uninstall', 'start', 'stop') -and -not (Test-Admin)) {
    Write-Line ''
    Write-Line '  Elevazione amministratore necessaria...' Yellow
    $psExe   = (Get-Process -Id $PID).Path
    $myScript = $MyInvocation.MyCommand.Path
    $argStr  = "-NoProfile -ExecutionPolicy Bypass -File `"$myScript`" $Action"
    if ($NoStart) { $argStr += ' -NoStart' }
    $proc = Start-Process $psExe -ArgumentList $argStr -Verb RunAs -PassThru -Wait
    exit $proc.ExitCode
}

# ── Compilazione exe ────────────────────────────────────────────────────────
function Build-ServiceExe {
    if (-not (Test-Path $serviceCs)) {
        throw "Sorgente non trovato: $serviceCs"
    }
    Write-Info "Compilazione movieserver-service.exe..."

    # Trova System.ServiceProcess.dll
    try {
        $svcDll = ([System.Reflection.Assembly]::LoadWithPartialName('System.ServiceProcess')).Location
    } catch { $svcDll = $null }

    if ([string]::IsNullOrEmpty($svcDll) -or -not (Test-Path $svcDll)) {
        $fwDir  = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
        $svcDll = Join-Path $fwDir 'System.ServiceProcess.dll'
    }

    if (-not (Test-Path $svcDll)) {
        throw "System.ServiceProcess.dll non trovato. Installa .NET Framework 4.x."
    }

    $code = Get-Content $serviceCs -Raw
    Add-Type -TypeDefinition $code `
             -ReferencedAssemblies @($svcDll) `
             -OutputAssembly $serviceExe `
             -OutputType ConsoleApplication

    Write-Ok "Compilato: $serviceExe"
}

# ── Azioni ──────────────────────────────────────────────────────────────────
Write-Line ''
Write-Line "  GUARDA TAMBOSI -- Gestione Servizio Windows" Cyan
Write-Line ''

switch ($Action) {

    'compile' {
        Build-ServiceExe
    }

    'install' {
        # Compila se mancante o se sorgente e' piu' recente
        $needBuild = (-not (Test-Path $serviceExe))
        if (-not $needBuild -and (Test-Path $serviceCs)) {
            $srcTime = (Get-Item $serviceCs).LastWriteTimeUtc
            $exeTime = (Get-Item $serviceExe).LastWriteTimeUtc
            if ($srcTime -gt $exeTime) { $needBuild = $true }
        }
        if ($needBuild) { Build-ServiceExe }

        # Controlla se gia' installato
        $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Write-Warn "Il servizio '$ServiceName' e' gia' installato (status: $($existing.Status))."
            Write-Warn "Usa 'uninstall' prima di re-installare."
            exit 1
        }

        Write-Info "Installazione servizio '$DisplayName'..."
        New-Service -Name $ServiceName `
                    -DisplayName $DisplayName `
                    -Description $Description `
                    -BinaryPathName "`"$serviceExe`"" `
                    -StartupType Automatic | Out-Null
        Write-Ok "Servizio installato (avvio automatico all'accensione)."

        if (-not $NoStart) {
            Write-Info "Avvio servizio..."
            Start-Service -Name $ServiceName
            Start-Sleep -Seconds 1
            Write-Ok "Servizio avviato."
        }

        Get-Service -Name $ServiceName | Format-List Name, DisplayName, Status, StartType
    }

    'uninstall' {
        $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($null -eq $existing) {
            Write-Warn "Il servizio '$ServiceName' non e' installato."
            exit 0
        }

        if ($existing.Status -ne 'Stopped') {
            Write-Info "Arresto del servizio..."
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }

        Write-Info "Rimozione servizio..."
        $result = & sc.exe delete $ServiceName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Err "sc.exe delete ha restituito: $result"
            exit 1
        }
        Write-Ok "Servizio '$DisplayName' rimosso."
    }

    'start' {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Err "Servizio non installato. Usa 'install' prima."
            exit 1
        }
        if ($svc.Status -eq 'Running') {
            Write-Warn "Servizio gia' in esecuzione."
        } else {
            Start-Service -Name $ServiceName
            Start-Sleep -Seconds 1
            Write-Ok "Servizio avviato."
        }
        Get-Service -Name $ServiceName | Format-List Name, DisplayName, Status
    }

    'stop' {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Err "Servizio non installato."
            exit 1
        }
        if ($svc.Status -eq 'Stopped') {
            Write-Warn "Servizio gia' fermo."
        } else {
            Stop-Service -Name $ServiceName -Force
            Start-Sleep -Seconds 1
            Write-Ok "Servizio fermato."
        }
        Get-Service -Name $ServiceName | Format-List Name, DisplayName, Status
    }

    'status' {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Warn "Il servizio '$ServiceName' NON e' installato."
            Write-Line ''
            Write-Line "  Per installarlo:" White
            Write-Line "    powershell -ExecutionPolicy Bypass -File service.ps1 install" Gray
        } else {
            $color = switch ($svc.Status) {
                'Running' { 'Green' }
                'Stopped' { 'Yellow' }
                default   { 'Red' }
            }
            Write-Host "  Stato: " -NoNewline
            Write-Host $svc.Status -ForegroundColor $color
            $svc | Format-List Name, DisplayName, Status, StartType
        }
    }
}
Write-Line ''
