[CmdletBinding()]
param(
    [string]$ServerRoot = '',
    [int]$TickSeconds = 20,
    [switch]$SingleCycle,
    [switch]$NoCaddy,
    [switch]$UsePwsh,
    [switch]$UseWindowsPowerShell
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrEmpty($ServerRoot)) {
    $ServerRoot = Split-Path -Parent $root
}

# --- Bootstrap: scarica tool mancanti prima di qualsiasi altra cosa ---
$bootstrapModule = Join-Path $root 'tools\Bootstrap.psm1'
if (Test-Path $bootstrapModule) {
    Import-Module $bootstrapModule -Force
    Invoke-ToolBootstrap -ServerRoot $ServerRoot
} else {
    Write-Warning "Bootstrap module non trovato: $bootstrapModule"
}

$ripWatcher = Join-Path $root 'apps\rip-watcher\rip-watcher.ps1'
$ripWorker = Join-Path $root 'apps\rip-watcher\rip-worker.ps1'
$tmdbMatcher = Join-Path $root 'apps\tmdb-matcher\tmdb-matcher.ps1'
$hlsEncoder = Join-Path $root 'apps\hls-encoder\hls-encoder.ps1'
$catalogPublisher = Join-Path $root 'apps\catalog-publisher\catalog-publisher.ps1'
$adminApi = Join-Path $root 'admin-api.ps1'

$required = @($ripWatcher, $ripWorker, $tmdbMatcher, $hlsEncoder, $catalogPublisher)
foreach ($path in $required) {
    if (-not (Test-Path $path)) {
        throw "Script mancante: $path"
    }
}

$engine = $null
if ($UsePwsh) {
    $engine = 'pwsh'
}
elseif ($UseWindowsPowerShell) {
    $engine = 'powershell'
}
else {
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        $engine = 'pwsh'
    }
    else {
        $engine = 'powershell'
    }
}

if (-not (Get-Command $engine -ErrorAction SilentlyContinue)) {
    throw "Runtime non disponibile: $engine"
}

function Write-OrchestratorLine {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString('s')
    Write-Output ("[{0}] [{1}] {2}" -f $ts, $Level.ToUpperInvariant(), $Message)
}

function Resolve-CaddyExePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerRoot
    )

    $binDir = Join-Path $ServerRoot 'TOOLS\caddy\bin'
    $preferred = Join-Path $binDir 'caddy.exe'
    # Prefer caddy.exe if it is a real binary (not a Git LFS placeholder)
    if (Test-Path $preferred) {
        $item = Get-Item $preferred
        if ($item.Length -ge 10240) {
            return $preferred
        }
    }

    if (-not (Test-Path $binDir)) {
        return $null
    }

    $candidates = @(Get-ChildItem -Path $binDir -File -Filter 'caddy*.exe' -ErrorAction SilentlyContinue |  
        Where-Object { $_.Length -ge 10240 })
    if ($candidates.Count -eq 0) {
        return $null
    }

    $best = $candidates | Sort-Object @{ Expression = { if ($_.Name -ieq 'caddy_windows_amd64.exe') { 0 } else { 1 } } }, Name | Select-Object -First 1
    return $best.FullName
}

function New-RuntimeCaddyfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ServerRoot,
        [Parameter(Mandatory)] [string]$TemplatePath
    )
    $streamingDir = Join-Path $ServerRoot 'STREAMING'
    $template = Get-Content -Path $TemplatePath -Raw
    # Replace any hardcoded path with the runtime ServerRoot streaming dir
    $resolved = $template -replace '(?i)[A-Z]:\\[^\r\n]*\\STREAMING', $streamingDir
    $tmpFile = Join-Path $env:TEMP 'movieserver-runtime.caddyfile'
    [System.IO.File]::WriteAllText($tmpFile, $resolved, [System.Text.Encoding]::UTF8)
    return $tmpFile
}

function Invoke-Step {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$StepArgs = @()
    )

    Write-OrchestratorLine -Level Info -Message ("Start step: {0}" -f $Name)

    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    if ($StepArgs.Count -gt 0) {
        $psArgs += $StepArgs
    }

    & $engine @psArgs
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-OrchestratorLine -Level Error -Message ("Step failed ({0}) with exit code {1}" -f $Name, $exitCode)
    }
    else {
        Write-OrchestratorLine -Level Info -Message ("Step done: {0}" -f $Name)
    }
}

$caddyProc = $null
$adminApiProc = $null
try {
    if (-not $NoCaddy) {
        $caddyExe = Resolve-CaddyExePath -ServerRoot $ServerRoot
        $caddyTemplate = Join-Path $ServerRoot 'CONFIG\Caddyfile'

        if ([string]::IsNullOrWhiteSpace($caddyExe) -or -not (Test-Path $caddyExe)) {
            throw "Caddy non trovato: $caddyExe"
        }
        if (-not (Test-Path $caddyTemplate)) {
            throw "Caddyfile non trovato: $caddyTemplate"
        }

        # Percorsi certificato TLS gestito da LEGO
        $legoDir   = Join-Path $ServerRoot 'CONFIG\lego'
        $legoCerts = Join-Path $legoDir 'certificates'
        $certFile  = Join-Path $legoCerts 'guarda.tambosi.asetti.co.crt'
        $keyFile   = Join-Path $legoCerts 'guarda.tambosi.asetti.co.key'
        $legoExe   = Join-Path $ServerRoot 'TOOLS\lego\lego.exe'

        # Legge il token Cloudflare da local.psd1 per rinnovo LEGO
        $localPsd = Join-Path $ServerRoot 'CONFIG\local.psd1'
        $cfToken = ''
        if (Test-Path $localPsd) {
            try {
                $localCfg = Import-PowerShellDataFile -Path $localPsd -ErrorAction SilentlyContinue
                if ($localCfg -and $localCfg.ContainsKey('Cloudflare')) {
                    $cfToken = [string]$localCfg.Cloudflare.ApiToken
                }
            } catch { }
        }

        # Ottieni o rinnova il certificato se necessario
        if (Test-Path $legoExe) {
            $needCert = $false
            if (-not (Test-Path $certFile)) {
                $needCert = $true
                Write-OrchestratorLine -Level Info -Message 'Certificato TLS non trovato, ottengo da Let Encrypt...'
            } else {
                try {
                    $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certFile)
                    $daysLeft = ($x509.NotAfter - (Get-Date)).Days
                    Write-OrchestratorLine -Level Info -Message ("Certificato TLS valido ancora {0} giorni" -f $daysLeft)
                    if ($daysLeft -lt 30) {
                        $needCert = $true
                        Write-OrchestratorLine -Level Info -Message 'Certificato in scadenza, rinnovo...'
                    }
                } catch { $needCert = $true }
            }
            if ($needCert) {
                $env:CLOUDFLARE_DNS_API_TOKEN = $cfToken
                $legoBaseArgs = @('--path', $legoDir, '--accept-tos', '--dns', 'cloudflare',
                                  '--domains', 'guarda.tambosi.asetti.co', '--email', 'tls@tambosi.asetti.co')
                $legoAction = if (Test-Path $certFile) { @('renew', '--days', '30') } else { @('run') }
                Write-OrchestratorLine -Level Info -Message ('LEGO: ' + ($legoBaseArgs + $legoAction -join ' '))
                & $legoExe @legoBaseArgs @legoAction 2>&1 | ForEach-Object {
                    Write-OrchestratorLine -Level Info -Message ([string]$_)
                }
                if ($LASTEXITCODE -ne 0) {
                    Write-OrchestratorLine -Level Warning -Message "LEGO exit code $LASTEXITCODE - verificare il certificato manualmente"
                }
            }
        }

        # Passa i percorsi cert/key a Caddy tramite variabili d'ambiente
        $env:LEGO_CERT_FILE = $certFile
        $env:LEGO_KEY_FILE  = $keyFile

        # Genera un Caddyfile runtime con i percorsi corretti per questo ServerRoot
        $caddyFile = New-RuntimeCaddyfile -ServerRoot $ServerRoot -TemplatePath $caddyTemplate
        Write-OrchestratorLine -Level Info -Message "Caddyfile runtime: $caddyFile"

        Write-OrchestratorLine -Level Info -Message 'Validazione Caddyfile...'
        & $caddyExe validate --config $caddyFile | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Validazione Caddy fallita con exit code $LASTEXITCODE"
        }

        Write-OrchestratorLine -Level Info -Message 'Avvio Caddy in background...'
        $caddyProc = Start-Process -FilePath $caddyExe -ArgumentList @('run', '--config', $caddyFile) -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 1
        if ($caddyProc.HasExited) {
            throw 'Caddy si e chiuso subito dopo l avvio'
        }

        Write-OrchestratorLine -Level Info -Message ("Caddy avviato PID={0}" -f $caddyProc.Id)
    }

    # Kill any orphaned admin-api processes (from previous run killed with -Force).
    # Strategy 1: match by command line (works when WMI returns it)
    # Strategy 2: find whatever process owns port 9095 via netstat (catches hidden-window procs)
    $orphanPids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -ilike '*admin-api*' -and $_.CommandLine -ilike '*MOVIESERVER*' })) {
        [void]$orphanPids.Add([int]$p.ProcessId)
    }
    # Fallback: any process listening on port 9095 that is powershell/pwsh
    $netLines = @(netstat -ano 2>$null | Select-String '0\.0\.0\.0:9095\s+0\.0\.0\.0:\*\s+LISTENING')
    foreach ($line in $netLines) {
        if ($line -match '\s+(\d+)\s*$') {
            $pidFromNet = [int]$Matches[1]
            if ($pidFromNet -gt 4) {   # PID 4 = System/HTTP.sys — skip, kill owning user process instead
                [void]$orphanPids.Add($pidFromNet)
            }
        }
    }
    # Also check TCP6
    $netLines6 = @(netstat -ano 2>$null | Select-String ':9095\s+\[::\]:\*\s+LISTENING')
    foreach ($line in $netLines6) {
        if ($line -match '\s+(\d+)\s*$') {
            $pidFromNet = [int]$Matches[1]
            if ($pidFromNet -gt 4) { [void]$orphanPids.Add($pidFromNet) }
        }
    }
    # HTTP.sys (PID 4) — find the user-space process that registered the URL
    # by checking which powershell/pwsh processes have an ESTABLISHED connection to 9095
    $netEst = @(netstat -ano 2>$null | Select-String ':9095\s+ESTABLISHED')
    foreach ($line in $netEst) {
        if ($line -match '\s+(\d+)\s*$') {
            $pidFromNet = [int]$Matches[1]
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$pidFromNet" -ErrorAction SilentlyContinue
            if ($proc -and $proc.Name -match 'powershell|pwsh') {
                [void]$orphanPids.Add($pidFromNet)
            }
        }
    }

    foreach ($orphanPid in $orphanPids) {
        $orphanProc = Get-Process -Id $orphanPid -ErrorAction SilentlyContinue
        if ($null -ne $orphanProc) {
            Write-OrchestratorLine -Level Info -Message ("Termino admin-api orfano PID={0}" -f $orphanPid)
            try { $orphanProc.Kill() } catch {}
        }
    }
    if ($orphanPids.Count -gt 0) { Start-Sleep -Seconds 2 }

    # Start admin API in background
    if (Test-Path $adminApi) {
        Write-OrchestratorLine -Level Info -Message 'Avvio Admin API in background...'
        $adminApiProc = Start-Process -FilePath $engine `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $adminApi, '-ServerRoot', $ServerRoot) `
            -PassThru -WindowStyle Hidden
        Start-Sleep -Seconds 1
        if ($adminApiProc.HasExited) {
            Write-OrchestratorLine -Level Warning -Message 'Admin API si e chiusa subito dopo l avvio'
            $adminApiProc = $null
        } else {
            Write-OrchestratorLine -Level Info -Message ("Admin API avviata PID={0}" -f $adminApiProc.Id)
        }
    } else {
        Write-OrchestratorLine -Level Warning -Message "Admin API non trovata: $adminApi"
    }

    do {
        Write-OrchestratorLine -Level Info -Message 'Ciclo pipeline avviato'

        Invoke-Step -Name 'rip-watcher' -ScriptPath $ripWatcher -StepArgs @('-ServerRoot', $ServerRoot, '-RunOnce')
        Invoke-Step -Name 'rip-worker' -ScriptPath $ripWorker -StepArgs @('-ServerRoot', $ServerRoot)
        Invoke-Step -Name 'tmdb-matcher' -ScriptPath $tmdbMatcher -StepArgs @('-ServerRoot', $ServerRoot)
        Invoke-Step -Name 'hls-encoder' -ScriptPath $hlsEncoder -StepArgs @('-ServerRoot', $ServerRoot)
        Invoke-Step -Name 'catalog-publisher' -ScriptPath $catalogPublisher -StepArgs @('-ServerRoot', $ServerRoot)

        Write-OrchestratorLine -Level Info -Message 'Ciclo pipeline completato'

        if (-not $SingleCycle) {
            Start-Sleep -Seconds $TickSeconds
        }
    }
    while (-not $SingleCycle)
}
finally {
    if ($null -ne $caddyProc) {
        if (-not $caddyProc.HasExited) {
            Write-OrchestratorLine -Level Warning -Message ("Arresto Caddy PID={0}" -f $caddyProc.Id)
            Stop-Process -Id $caddyProc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $adminApiProc) {
        if (-not $adminApiProc.HasExited) {
            Write-OrchestratorLine -Level Warning -Message ("Arresto Admin API PID={0}" -f $adminApiProc.Id)
            Stop-Process -Id $adminApiProc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
