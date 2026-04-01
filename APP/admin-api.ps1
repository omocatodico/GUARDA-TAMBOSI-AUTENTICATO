<#
.SYNOPSIS
  Minimal HTTP API server (port 9095) for admin panel operations.
  Caddy reverse-proxies /api/* to http://localhost:9095/api/*.
#>
[CmdletBinding()]
param(
    [string]$ServerRoot = '',
    [int]$Port = 9095
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($ServerRoot)) {
    $ServerRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$configPath  = Join-Path $ServerRoot 'CONFIG\local.psd1'
$config      = Import-PowerShellDataFile -Path $configPath
$adminPin    = $config.Admin.Pin

# LDAP configuration (optional — if configured, catalog requires LDAP login)
$ldapEnabled = $false
if ($config.ContainsKey('Ldap') -and $config.Ldap -and -not [string]::IsNullOrWhiteSpace([string]$config.Ldap.Server)) {
    $ldapEnabled = $true
    Write-Host '[admin-api] LDAP abilitato — catalogo protetto da autenticazione'
} else {
    Write-Host '[admin-api] LDAP non configurato — catalogo pubblico'
}
# LDAP session signing key (derived from PIN so tokens survive restarts)
$ldapSecret = $adminPin + '::ldap-session-hmac'

$streamingDir = Join-Path $ServerRoot 'STREAMING'
$catalogFile  = Join-Path $streamingDir 'catalog.json'
$queuesDir    = Join-Path $ServerRoot 'WORK\queues'
$jobsFile     = Join-Path $queuesDir 'rip-jobs.json'
$ripPath      = Join-Path $ServerRoot $config.Paths.Rip

# In-memory token store — cleared when process restarts
$tokens = [System.Collections.Generic.HashSet[string]]::new()

# ── helpers ───────────────────────────────────────────────────────────────────

function Send-Response {
    param($ctx, $data, [int]$status = 200)
    $json  = $data | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.StatusCode       = $status
    $ctx.Response.ContentType      = 'application/json; charset=utf-8'
    $ctx.Response.ContentLength64  = $bytes.Length
    $ctx.Response.Headers.Add('Access-Control-Allow-Origin',  '*')
    $ctx.Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type,Authorization')
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

function Read-Body {
    param($ctx)
    $reader = [System.IO.StreamReader]::new(
        $ctx.Request.InputStream,
        [System.Text.Encoding]::UTF8
    )
    $body = $reader.ReadToEnd()
    $reader.Close()
    return $body
}

function Test-Token {
    param($ctx)
    $auth = $ctx.Request.Headers['Authorization']
    if ($auth -and $auth -match '^Bearer\s+(.+)$') {
        return $tokens.Contains($Matches[1].Trim())
    }
    return $false
}

# ── LDAP helpers ──────────────────────────────────────────────────────────────

function Test-LdapCredential {
    # Attempts LDAP bind + group membership search. Returns hashtable or $null.
    param([string]$Username, [string]$Password)
    if (-not $ldapEnabled) { return $null }

    $server   = [string]$config.Ldap.Server
    $port     = [int]$config.Ldap.Port
    $domain   = [string]$config.Ldap.Domain
    $baseDN   = [string]$config.Ldap.BaseDN
    $filter   = [string]$config.Ldap.SearchFilter -replace ':user', $Username

    $bindDN   = "$Username@$domain"
    $ldapPath = "LDAP://${server}:${port}/$baseDN"
    $entry    = $null

    try {
        $entry = New-Object System.DirectoryServices.DirectoryEntry($ldapPath, $bindDN, $Password)
        # Force bind - accessing NativeObject triggers the actual LDAP connection
        $null = $entry.NativeObject

        $searcher = New-Object System.DirectoryServices.DirectorySearcher($entry)
        $searcher.Filter = $filter
        $searcher.PropertiesToLoad.AddRange(@('cn', 'givenName', 'sn', 'sAMAccountName'))
        $result = $searcher.FindOne()

        if ($null -eq $result) {
            Write-Host "[admin-api] LDAP: utente '$Username' autenticato ma NON nei gruppi autorizzati"
            return $null
        }

        $displayName = ''
        if ($result.Properties['cn'] -and $result.Properties['cn'].Count -gt 0) {
            $displayName = [string]$result.Properties['cn'][0]
        }

        Write-Host "[admin-api] LDAP: login OK per '$Username' ($displayName)"
        return @{ username = $Username; displayName = $displayName }
    }
    catch {
        Write-Host "[admin-api] LDAP: bind fallito per '$Username' - $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($null -ne $entry) { try { $entry.Dispose() } catch {} }
    }
}

function New-LdapSessionToken {
    # Creates an HMAC-signed stateless session token.
    param([string]$Username, [string]$DisplayName)
    $epoch  = [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)
    $nowSec = [long]([DateTime]::UtcNow - $epoch).TotalSeconds
    $days   = 30
    if ($config.Ldap -and $config.Ldap.ContainsKey('SessionDays')) {
        $days = [int]$config.Ldap.SessionDays
    }
    $expSec = $nowSec + ($days * 86400)
    $payload = @{ u = $Username; n = $DisplayName; e = $expSec } | ConvertTo-Json -Compress
    $payloadB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))

    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($ldapSecret))
    $sig  = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payloadB64)))
    $hmac.Dispose()

    return ('{0}.{1}' -f $payloadB64, $sig)
}

function Test-LdapSessionToken {
    # Verifies an HMAC-signed token. Returns hashtable or $null.
    param([string]$Token)
    if (-not $Token -or $Token -notmatch '^([^.]+)\.([^.]+)$') { return $null }
    $payloadB64 = $Matches[1]
    $sig        = $Matches[2]

    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($ldapSecret))
    $expectedSig = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payloadB64)))
    $hmac.Dispose()

    if ($sig -ne $expectedSig) { return $null }

    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payloadB64))
        $data = $json | ConvertFrom-Json
        $epoch  = [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)
        $nowSec = [long]([DateTime]::UtcNow - $epoch).TotalSeconds
        if ([long]$data.e -lt $nowSec) { return $null }  # expired
        return @{ username = [string]$data.u; displayName = [string]$data.n }
    } catch {
        return $null
    }
}

function Get-LdapTokenFromRequest {
    # Extracts LDAP token from Authorization header or ldap_session cookie.
    param($ctx)
    # Try Authorization: LdapBearer <token>
    $auth = $ctx.Request.Headers['Authorization']
    if ($auth -and $auth -match '^LdapBearer\s+(.+)$') {
        return $Matches[1].Trim()
    }
    # Try cookie
    $cookie = $ctx.Request.Cookies['ldap_session']
    if ($null -ne $cookie -and -not [string]::IsNullOrWhiteSpace($cookie.Value)) {
        return $cookie.Value
    }
    return $null
}

function Get-ActiveEncodingInfo {
    # profiles in encode order: main first (native resolution), then descending sub-profiles
    $profiles = @('main', '4k', '1080p', '720p', '480p', '360p', '240p')

    if (-not (Test-Path $jobsFile)) { return $null }
    $raw = Get-Content $jobsFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $jobs = $raw | ConvertFrom-Json
    $encodingJob = @($jobs | Where-Object { $_.status -eq 'encoding' }) | Select-Object -First 1
    if ($null -eq $encodingJob) { return $null }

    $profilesDone   = @()
    $currentProfile = $null
    $segmentsDone   = 0
    $totalSegments  = 0
    $progressPct    = $null

    $hlsDir = $null
    if ($null -ne $encodingJob.metadataDir -and (Test-Path $encodingJob.metadataDir)) {
        $hlsDir = Join-Path $encodingJob.metadataDir 'hls'
    }

    if ($null -ne $hlsDir -and (Test-Path $hlsDir)) {
        foreach ($p in $profiles) {
            if (Test-Path (Join-Path $hlsDir "$p.m3u8")) {
                $profilesDone += $p
            } elseif ($null -eq $currentProfile) {
                $currentProfile = $p
                $segmentsDone   = @(Get-ChildItem $hlsDir -Filter "${p}_*.ts" -ErrorAction SilentlyContinue).Count
                # Derive total from a completed profile's m3u8 segment list
                if ($profilesDone.Count -gt 0) {
                    $m3u8Path = Join-Path $hlsDir "$($profilesDone[-1]).m3u8"
                    if (Test-Path $m3u8Path) {
                        $m3u8Lines  = Get-Content $m3u8Path -ErrorAction SilentlyContinue
                        $totalSegments = @($m3u8Lines | Where-Object { $_ -match '\.ts$' }).Count
                    }
                }
                if ($totalSegments -gt 0) {
                    $progressPct = [math]::Round(($segmentsDone / $totalSegments) * 100)
                }
            }
        }
    }

    $resLabels = @{
        'main'  = 'native'
        '4k'    = '3840x2160'
        '1080p' = '1920x1080'
        '720p'  = '1280x720'
        '480p'  = '854x480'
        '360p'  = '640x360'
        '240p'  = '480x240'
    }
    return [ordered]@{
        movie         = [string]$encodingJob.displayName
        profile       = if ($currentProfile) { $currentProfile } else { 'finalizing' }
        profileRes    = if ($currentProfile) { $resLabels[$currentProfile] } else { $null }
        profilesDone  = $profilesDone
        segmentsDone  = $segmentsDone
        totalSegments = $totalSegments
        progressPct   = $progressPct
        codec         = switch ([string]$encodingJob.hwEncoder) {
            'nvenc' { 'NVIDIA NVENC (GPU)' }
            'qsv'   { 'Intel QuickSync (GPU)' }
            default { 'libx264 (CPU)' }
        }
    }
}

function Get-ManagedProcesses {
    $list = [System.Collections.Generic.List[object]]::new()
    $encodingInfo = Get-ActiveEncodingInfo

    foreach ($name in @('makemkvcon', 'makemkvcon64', 'caddy')) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $cpuSecs = try { [math]::Round($p.TotalProcessorTime.TotalSeconds, 1) } catch { $null }
            $list.Add([ordered]@{
                pid     = $p.Id
                name    = $p.ProcessName
                cpu     = $cpuSecs
                memMb   = [math]::Round($p.WorkingSet64 / 1MB, 1)
                started = try { $p.StartTime.ToString('s') } catch { '' }
            })
        }
    }

    foreach ($p in @(Get-Process -Name 'ffmpeg' -ErrorAction SilentlyContinue)) {
        $entry = [ordered]@{
            pid     = $p.Id
            name    = 'ffmpeg'
            memMb   = [math]::Round($p.WorkingSet64 / 1MB, 1)
            started = try { $p.StartTime.ToString('s') } catch { '' }
        }
        if ($null -ne $encodingInfo) {
            $entry['movie']         = $encodingInfo.movie
            $entry['profile']       = $encodingInfo.profile
            $entry['profileRes']    = $encodingInfo.profileRes
            $entry['profilesDone']  = $encodingInfo.profilesDone
            $entry['segmentsDone']  = $encodingInfo.segmentsDone
            $entry['totalSegments'] = $encodingInfo.totalSegments
            $entry['progressPct']   = $encodingInfo.progressPct
            $entry['codec']         = $encodingInfo.codec
        }
        $list.Add($entry)
    }

    # PowerShell/pwsh processes running MOVIESERVER pipeline scripts
    foreach ($psName in @('powershell', 'pwsh')) {
        foreach ($p in @(Get-Process -Name $psName -ErrorAction SilentlyContinue)) {
            $cmdLine = ''
            try {
                $wmi = Get-WmiObject Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
                if ($wmi) { $cmdLine = [string]$wmi.CommandLine }
            } catch {}
            if ($cmdLine -ilike "*MOVIESERVER*") {
                # Extract the script filename from the -File argument
                $scriptName = ''
                if ($cmdLine -match '-File\s+"?([^"]+\.ps1)"?') {
                    $scriptName = Split-Path $Matches[1] -Leaf
                }
                $displayName = if ($scriptName) { "$psName ($scriptName)" } else { "$psName (pipeline)" }
                $cpuSecs = try { [math]::Round($p.TotalProcessorTime.TotalSeconds, 1) } catch { $null }
                $list.Add([ordered]@{
                    pid     = $p.Id
                    name    = $displayName
                    script  = $scriptName
                    cpu     = $cpuSecs
                    memMb   = [math]::Round($p.WorkingSet64 / 1MB, 1)
                    started = try { $p.StartTime.ToString('s') } catch { '' }
                })
            }
        }
    }

    return $list.ToArray()
}

function Get-JobMetadataDir {
    param([string]$JobId, [string]$JobsPath)
    if (-not (Test-Path $JobsPath)) { return $null }
    $raw = Get-Content $JobsPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $jobs = $raw | ConvertFrom-Json
    $job  = @($jobs) | Where-Object { [string]$_.id -eq $JobId } | Select-Object -First 1
    if ($null -eq $job -or [string]::IsNullOrEmpty([string]$job.metadataDir)) { return $null }
    return [string]$job.metadataDir
}

# ── main loop ─────────────────────────────────────────────────────────────────

$listener = [System.Net.HttpListener]::new()
# Use localhost prefix — Caddy's header_up overrides Host to localhost:9095
# so HTTP.sys accepts the request correctly without needing admin/urlacl.
$listener.Prefixes.Add("http://localhost:$Port/")

# Retry loop — a previous instance killed by Stop-Process -Force may leave
# an HTTP.sys registration that takes ~1-2 s to be released by the OS.
$maxAttempts = 8
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        $listener.Start()
        break
    } catch [System.Net.HttpListenerException] {
        if ($attempt -eq $maxAttempts) {
            Write-Host "[admin-api] ERRORE: porta $Port occupata dopo $maxAttempts tentativi. Abbandono."
            exit 1
        }
        Write-Host "[admin-api] Porta $Port occupata, attendo... (tentativo $attempt/$maxAttempts)"
        Start-Sleep -Seconds 2
        # Recreate the listener — once Start() throws the object may be in a bad state
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$Port/")
    }
}
Write-Host "[admin-api] In ascolto su :$Port"

try {
    while ($listener.IsListening) {
        $ctx    = $listener.GetContext()
        $req    = $ctx.Request
        $path   = $req.Url.AbsolutePath.TrimEnd('/')
        $method = $req.HttpMethod

        # ── CORS preflight ────────────────────────────────────────────────────
        if ($method -eq 'OPTIONS') {
            $ctx.Response.Headers.Add('Access-Control-Allow-Origin',  '*')
            $ctx.Response.Headers.Add('Access-Control-Allow-Methods', 'GET,POST,PATCH,DELETE,OPTIONS')
            $ctx.Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type,Authorization')
            $ctx.Response.StatusCode = 204
            $ctx.Response.Close()
            continue
        }

        # ── POST /api/auth ────────────────────────────────────────────────────
        if ($path -eq '/api/auth' -and $method -eq 'POST') {
            try {
                $json = Read-Body $ctx | ConvertFrom-Json
                if ($json.pin -eq $adminPin) {
                    $token = [System.Guid]::NewGuid().ToString('N')
                    [void]$tokens.Add($token)
                    Send-Response $ctx @{ token = $token }
                } else {
                    Send-Response $ctx @{ error = 'PIN non valido' } 401
                }
            } catch {
                Send-Response $ctx @{ error = 'Richiesta non valida' } 400
            }
            continue
        }

        # ── POST /api/ldap-auth ───────────────────────────────────────────────
        if ($path -eq '/api/ldap-auth' -and $method -eq 'POST') {
            if (-not $ldapEnabled) {
                Send-Response $ctx @{ error = 'LDAP non configurato' } 501
                continue
            }
            try {
                $json = Read-Body $ctx | ConvertFrom-Json
                $usr  = [string]$json.username
                $pwd  = [string]$json.password
                if ([string]::IsNullOrWhiteSpace($usr) -or [string]::IsNullOrWhiteSpace($pwd)) {
                    Send-Response $ctx @{ error = 'Username e password obbligatori' } 400
                    continue
                }
                $ldapResult = Test-LdapCredential -Username $usr -Password $pwd
                if ($null -eq $ldapResult) {
                    Send-Response $ctx @{ error = 'Credenziali non valide o utente non autorizzato' } 401
                } else {
                    $sessionToken = New-LdapSessionToken -Username $ldapResult.username -DisplayName $ldapResult.displayName
                    # Set cookie via response header
                    $days = 30
                    if ($config.Ldap -and $config.Ldap.ContainsKey('SessionDays')) { $days = [int]$config.Ldap.SessionDays }
                    $maxAge = $days * 86400
                    $ctx.Response.Headers.Add('Set-Cookie', "ldap_session=$sessionToken; Path=/; Max-Age=$maxAge; SameSite=Lax")
                    Send-Response $ctx @{
                        token       = $sessionToken
                        displayName = $ldapResult.displayName
                        username    = $ldapResult.username
                    }
                }
            } catch {
                Write-Host "[admin-api] LDAP auth error: $($_.Exception.Message)"
                Send-Response $ctx @{ error = 'Errore autenticazione LDAP' } 500
            }
            continue
        }

        # ── GET /api/session ──────────────────────────────────────────────────
        if ($path -eq '/api/session' -and $method -eq 'GET') {
            $ldapToken = Get-LdapTokenFromRequest $ctx
            $session = Test-LdapSessionToken -Token $ldapToken
            if ($null -ne $session) {
                Send-Response $ctx @{
                    valid       = $true
                    username    = $session.username
                    displayName = $session.displayName
                    ldapEnabled = $ldapEnabled
                }
            } else {
                Send-Response $ctx @{ valid = $false; ldapEnabled = $ldapEnabled } 401
            }
            continue
        }

        # ── POST /api/logout ──────────────────────────────────────────────────
        if ($path -eq '/api/logout' -and $method -eq 'POST') {
            # Clear the cookie
            $ctx.Response.Headers.Add('Set-Cookie', 'ldap_session=; Path=/; Max-Age=0; SameSite=Lax')
            Send-Response $ctx @{ ok = $true }
            continue
        }

        # ── GET /api/ldap-status ──────────────────────────────────────────────
        if ($path -eq '/api/ldap-status' -and $method -eq 'GET') {
            Send-Response $ctx @{ ldapEnabled = $ldapEnabled }
            continue
        }

        # ── require valid token for all other endpoints ───────────────────────
        if (-not (Test-Token $ctx)) {
            Send-Response $ctx @{ error = 'Non autorizzato' } 401
            continue
        }

        # ── per-request dispatch (catch-all keeps the listener alive) ───────────
        try {

        # ── GET /api/processes ────────────────────────────────────────────────
        if ($path -eq '/api/processes' -and $method -eq 'GET') {
            Send-Response $ctx @{ processes = @(Get-ManagedProcesses) }
        }

        # ── POST /api/processes/kill { pid: N } ───────────────────────────────
        elseif ($path -eq '/api/processes/kill' -and $method -eq 'POST') {
            try {
                $json      = Read-Body $ctx | ConvertFrom-Json
                $targetPid = [int]$json.pid
                $managed   = @(Get-ManagedProcesses | Where-Object { $_.pid -eq $targetPid })
                if ($managed.Count -eq 0) {
                    Send-Response $ctx @{ error = 'PID non trovato tra i processi gestiti' } 404
                } else {
                    Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
                    Send-Response $ctx @{ killed = $targetPid }
                }
            } catch {
                Send-Response $ctx @{ error = $_.Exception.Message } 500
            }
        }

        # ── GET /api/queue ────────────────────────────────────────────────────
        elseif ($path -eq '/api/queue' -and $method -eq 'GET') {
            if (Test-Path $jobsFile) {
                $raw  = Get-Content $jobsFile -Raw -Encoding UTF8
                $jobs = $raw | ConvertFrom-Json
                $active = @($jobs | Where-Object { $_.status -ne 'encoded' })
                # Enrich live progress info
                foreach ($j in @($active)) {
                    if ($j.status -eq 'ripping') {
                        $safeName = [string]$j.displayName -replace '[\\/:*?"<>|]', '_'
                        $ripDir   = Join-Path $ripPath $safeName
                        if (Test-Path $ripDir) {
                            $szRaw = (Get-ChildItem $ripDir -Recurse -File -ErrorAction SilentlyContinue |
                                      Measure-Object -Property Length -Sum).Sum
                            $szBytes = if ($null -eq $szRaw) { [long]0 } else { [long]$szRaw }
                            $j | Add-Member -NotePropertyName 'ripFileSizeBytes' -NotePropertyValue $szBytes -Force
                        }
                    }
                    elseif ($j.status -eq 'encoding') {
                        $mdProp = $j.PSObject.Properties['metadataDir']
                        if ($null -ne $mdProp -and -not [string]::IsNullOrWhiteSpace([string]$mdProp.Value)) {
                            $hlsDir = Join-Path ([string]$mdProp.Value) 'hls'
                            if (Test-Path $hlsDir) {
                                $knownResolutions = @('main', '4k', '1080p', '720p', '480p', '360p', '240p')
                                $resLabels = @{
                                    'main'  = 'native'
                                    '4k'    = '3840x2160'
                                    '1080p' = '1920x1080'
                                    '720p'  = '1280x720'
                                    '480p'  = '854x480'
                                    '360p'  = '640x360'
                                    '240p'  = '480x240'
                                }
                                $profStats = [System.Collections.Generic.List[object]]::new()
                                foreach ($p in $knownResolutions) {
                                    $isDone  = Test-Path (Join-Path $hlsDir "$p.m3u8")
                                    $tsFiles = @(Get-ChildItem $hlsDir -Filter "${p}_*.ts" -ErrorAction SilentlyContinue)
                                    $tsCount = $tsFiles.Count
                                    if ($isDone -or $tsCount -gt 0) {
                                        $profStats.Add([ordered]@{ id = $p; res = $resLabels[$p]; done = $isDone; segments = $tsCount })
                                    }
                                }
                                if ($profStats.Count -gt 0) {
                                    $j | Add-Member -NotePropertyName 'encodeProfiles' -NotePropertyValue $profStats.ToArray() -Force
                                }
                            }
                        }
                    }
                }
                Send-Response $ctx @{ count = $active.Count; items = $active }
            } else {
                Send-Response $ctx @{ count = 0; items = @() }
            }
        }

        # ── DELETE /api/queue/{id} ────────────────────────────────────────────
        elseif ($path -match '^/api/queue/([^/]+)$' -and $method -eq 'DELETE') {
            $itemId = [Uri]::UnescapeDataString($Matches[1])
            if ($itemId -notmatch '^[a-zA-Z0-9_-]+$') {
                Send-Response $ctx @{ error = 'ID non valido' } 400
            } else {
                if (Test-Path $jobsFile) {
                    $raw  = Get-Content $jobsFile -Raw -Encoding UTF8
                    $jobs = $raw | ConvertFrom-Json
                    $newJobs = @($jobs | Where-Object { $_.id -ne $itemId })
                    $newJobs | ConvertTo-Json -Depth 10 | Set-Content $jobsFile -Encoding UTF8
                }
                Send-Response $ctx @{ deleted = $itemId }
            }
        }

        # ── GET /api/catalog ──────────────────────────────────────────────────
        elseif ($path -eq '/api/catalog' -and $method -eq 'GET') {
            if (Test-Path $catalogFile) {
                $cat = Get-Content $catalogFile -Raw -Encoding UTF8 | ConvertFrom-Json
                Send-Response $ctx $cat
            } else {
                Send-Response $ctx @{ count = 0; items = @() }
            }
        }

        # ── DELETE /api/catalog/{id} ──────────────────────────────────────────
        elseif ($path -match '^/api/catalog/([^/]+)$' -and $method -eq 'DELETE') {
            $itemId = [Uri]::UnescapeDataString($Matches[1])

            # Strict allowlist — job IDs are lowercase hex
            if ($itemId -notmatch '^[a-zA-Z0-9_-]+$') {
                Send-Response $ctx @{ error = 'ID non valido' } 400
            } else {
                $folderRemoved = $false

                if (Test-Path $catalogFile) {
                    $cat  = Get-Content $catalogFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    $item = @($cat.items | Where-Object { $_.id -eq $itemId }) | Select-Object -First 1

                    # Derive and delete the movie folder from hlsMaster path
                    if ($item -and $item.hlsMaster) {
                        $parts = ($item.hlsMaster -replace '\\', '/') -split '/'
                        # Expected: "movies/<FOLDER>/hls/master.m3u8"
                        if ($parts.Count -ge 2 -and $parts[0] -eq 'movies' -and $parts[1] -notmatch '\.\.') {
                            $movieDir = Join-Path $streamingDir "movies\$($parts[1])"
                            if (Test-Path $movieDir) {
                                Remove-Item $movieDir -Recurse -Force
                                $folderRemoved = $true
                            }
                        }
                    }

                    # Rewrite catalog.json without the deleted item
                    $newItems = @($cat.items | Where-Object { $_.id -ne $itemId })
                    [ordered]@{
                        generatedAt = (Get-Date -Format 's')
                        count       = $newItems.Count
                        items       = $newItems
                    } | ConvertTo-Json -Depth 10 | Set-Content $catalogFile -Encoding UTF8
                }

                # Remove from rip-jobs.json if present
                if (Test-Path $jobsFile) {
                    $raw  = Get-Content $jobsFile -Raw -Encoding UTF8
                    $jobs = $raw | ConvertFrom-Json
                    if ($jobs -is [array]) {
                        $newJobs = @($jobs | Where-Object { $_.id -ne $itemId })
                        $newJobs | ConvertTo-Json -Depth 10 | Set-Content $jobsFile -Encoding UTF8
                    } elseif ($jobs -and [string]$jobs.id -eq $itemId) {
                        '[]' | Set-Content $jobsFile -Encoding UTF8
                    }
                }

                Send-Response $ctx @{ deleted = $itemId; folderRemoved = $folderRemoved }
            }
        }

        # ── PATCH /api/catalog/{id}  { title, year, overview, director, runtime } ────
        elseif ($path -match '^/api/catalog/([^/]+)$' -and $method -eq 'PATCH') {
            $itemId = [Uri]::UnescapeDataString($Matches[1])
            if ($itemId -notmatch '^[a-zA-Z0-9_-]+$') {
                Send-Response $ctx @{ error = 'ID non valido' } 400
            } else {
                try {
                    $body      = Read-Body $ctx | ConvertFrom-Json
                    $bodyProps = $body.PSObject.Properties
                    $metaDir   = Get-JobMetadataDir -JobId $itemId -JobsPath $jobsFile
                    if ($null -eq $metaDir -or -not (Test-Path $metaDir)) {
                        Send-Response $ctx @{ error = 'Film non trovato' } 404
                    } else {
                        $metaPath = Join-Path $metaDir 'metadata.json'
                        $metadata = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json

                        if ($null -ne $bodyProps['title'])    { $metadata | Add-Member -NotePropertyName 'title'    -NotePropertyValue ([string]$body.title)   -Force }
                        if ($null -ne $bodyProps['year'])     { $metadata | Add-Member -NotePropertyName 'year'     -NotePropertyValue ([int]$body.year)        -Force }
                        if ($null -ne $bodyProps['overview']) { $metadata | Add-Member -NotePropertyName 'overview' -NotePropertyValue ([string]$body.overview) -Force }
                        if ($null -ne $bodyProps['runtime'])  { $metadata | Add-Member -NotePropertyName 'runtime'  -NotePropertyValue ([int]$body.runtime)     -Force }
                        if ($null -ne $bodyProps['director']) {
                            $dirsProp = $metadata.PSObject.Properties['directors']
                            $dirs = @(if ($null -ne $dirsProp -and $null -ne $dirsProp.Value) { @($dirsProp.Value) } else { @() })
                            if ($dirs.Count -gt 0) { $dirs[0] = [string]$body.director } else { $dirs = @([string]$body.director) }
                            $metadata | Add-Member -NotePropertyName 'directors' -NotePropertyValue $dirs -Force
                        }

                        $metadata | ConvertTo-Json -Depth 10 | Set-Content $metaPath -Encoding UTF8

                        # Also patch catalog.json for immediate UI refresh (next publish cycle will regenerate)
                        if (Test-Path $catalogFile) {
                            $cat = Get-Content $catalogFile -Raw -Encoding UTF8 | ConvertFrom-Json
                            foreach ($ci in @($cat.items)) {
                                if ([string]$ci.id -eq $itemId) {
                                    if ($null -ne $bodyProps['title'])    { $ci | Add-Member -NotePropertyName 'title'    -NotePropertyValue ([string]$body.title)   -Force }
                                    if ($null -ne $bodyProps['year'])     { $ci | Add-Member -NotePropertyName 'year'     -NotePropertyValue ([int]$body.year)        -Force }
                                    if ($null -ne $bodyProps['overview']) { $ci | Add-Member -NotePropertyName 'overview' -NotePropertyValue ([string]$body.overview) -Force }
                                    if ($null -ne $bodyProps['runtime'])  { $ci | Add-Member -NotePropertyName 'runtime'  -NotePropertyValue ([int]$body.runtime)     -Force }
                                    if ($null -ne $bodyProps['director']) { $ci | Add-Member -NotePropertyName 'director' -NotePropertyValue ([string]$body.director) -Force }
                                }
                            }
                            $cat | ConvertTo-Json -Depth 10 | Set-Content $catalogFile -Encoding UTF8
                        }

                        Send-Response $ctx @{ updated = $itemId }
                    }
                } catch {
                    Send-Response $ctx @{ error = $_.Exception.Message } 500
                }
            }
        }

        # ── POST /api/catalog/{id}/poster  { base64: '...', mimeType: 'image/jpeg' } ──
        elseif ($path -match '^/api/catalog/([^/]+)/poster$' -and $method -eq 'POST') {
            $itemId = [Uri]::UnescapeDataString($Matches[1])
            if ($itemId -notmatch '^[a-zA-Z0-9_-]+$') {
                Send-Response $ctx @{ error = 'ID non valido' } 400
            } else {
                try {
                    $body = Read-Body $ctx | ConvertFrom-Json
                    $b64  = [string]$body.base64
                    if ([string]::IsNullOrWhiteSpace($b64) -or $b64.Length -gt 3000000) {
                        Send-Response $ctx @{ error = 'Immagine mancante o troppo grande (max ~2 MB)' } 400
                    } else {
                        $metaDir = Get-JobMetadataDir -JobId $itemId -JobsPath $jobsFile
                        if ($null -eq $metaDir -or -not (Test-Path $metaDir)) {
                            Send-Response $ctx @{ error = 'Film non trovato' } 404
                        } else {
                            $imgBytes  = [System.Convert]::FromBase64String($b64)
                            $posterDst = Join-Path $metaDir 'poster_custom.jpg'
                            [System.IO.File]::WriteAllBytes($posterDst, $imgBytes)

                            # Tag metadata.json so Publisher preserves the custom poster on next run
                            $metaPath = Join-Path $metaDir 'metadata.json'
                            $metadata = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            $metadata | Add-Member -NotePropertyName 'customPosterPath' -NotePropertyValue 'poster_custom.jpg' -Force
                            $metadata | ConvertTo-Json -Depth 10 | Set-Content $metaPath -Encoding UTF8

                            # Compute web-accessible URL
                            $relPath      = $posterDst.Substring($streamingDir.Length).TrimStart('\').Replace('\', '/')
                            $posterWebUrl = '/' + $relPath

                            # Patch catalog.json immediately
                            if (Test-Path $catalogFile) {
                                $cat = Get-Content $catalogFile -Raw -Encoding UTF8 | ConvertFrom-Json
                                foreach ($ci in @($cat.items)) {
                                    if ([string]$ci.id -eq $itemId) {
                                        $ci | Add-Member -NotePropertyName 'posterUrl' -NotePropertyValue $posterWebUrl -Force
                                    }
                                }
                                $cat | ConvertTo-Json -Depth 10 | Set-Content $catalogFile -Encoding UTF8
                            }

                            Send-Response $ctx @{ updated = $itemId; posterUrl = $posterWebUrl }
                        }
                    }
                } catch {
                    Send-Response $ctx @{ error = $_.Exception.Message } 500
                }
            }
        }

        # ── POST /api/catalog/{id}/rematch  { title, year } ─────────────────────
        elseif ($path -match '^/api/catalog/([^/]+)/rematch$' -and $method -eq 'POST') {
            $itemId = [Uri]::UnescapeDataString($Matches[1])
            if ($itemId -notmatch '^[a-zA-Z0-9_-]+$') {
                Send-Response $ctx @{ error = 'ID non valido' } 400
            } else {
                try {
                    $body        = Read-Body $ctx | ConvertFrom-Json
                    $searchTitle = [string]$body.title
                    $searchYear  = if ($null -ne $body.PSObject.Properties['year'] -and $body.year) { [int]$body.year } else { 0 }

                    if ([string]::IsNullOrWhiteSpace($searchTitle)) {
                        Send-Response $ctx @{ error = 'Titolo obbligatorio' } 400
                    } else {
                        $metaDir = Get-JobMetadataDir -JobId $itemId -JobsPath $jobsFile
                        if ($null -eq $metaDir -or -not (Test-Path $metaDir)) {
                            Send-Response $ctx @{ error = 'Film non trovato nel catalogo' } 404
                        } else {
                            $rat  = [string]$config.Tmdb.ReadAccessToken
                            $lang = [string]$config.Tmdb.LanguagePrimary
                            $hdrs = @{ Authorization = "Bearer $rat" }

                            # Search TMDB (primary language, with year)
                            $qs = "query=$([uri]::EscapeDataString($searchTitle))&language=$lang"
                            if ($searchYear -gt 0) { $qs += "&year=$searchYear" }
                            $sr = Invoke-RestMethod -Uri "https://api.themoviedb.org/3/search/movie?$qs" -Headers $hdrs -ErrorAction Stop

                            # Retry without year if no results
                            if ($sr.total_results -eq 0 -and $searchYear -gt 0) {
                                $sr = Invoke-RestMethod -Uri "https://api.themoviedb.org/3/search/movie?query=$([uri]::EscapeDataString($searchTitle))&language=$lang" -Headers $hdrs -ErrorAction Stop
                            }

                            # Fallback language
                            if ($sr.total_results -eq 0 -and $config.Tmdb.LanguageFallback -and $config.Tmdb.LanguageFallback -ne $lang) {
                                $langFb = [string]$config.Tmdb.LanguageFallback
                                $qsFb   = "query=$([uri]::EscapeDataString($searchTitle))&language=$langFb"
                                if ($searchYear -gt 0) { $qsFb += "&year=$searchYear" }
                                $sr = Invoke-RestMethod -Uri "https://api.themoviedb.org/3/search/movie?$qsFb" -Headers $hdrs -ErrorAction Stop
                            }

                            if ($sr.total_results -eq 0) {
                                Send-Response $ctx @{ error = "Nessun risultato TMDB per: $searchTitle" } 404
                            } else {
                                $hit = $sr.results[0]

                                # Full details + credits
                                $det = Invoke-RestMethod -Uri "https://api.themoviedb.org/3/movie/$($hit.id)?language=$lang&append_to_response=credits" -Headers $hdrs -ErrorAction Stop

                                $newTitle   = [string]$det.title
                                $newYear    = if ($det.release_date -match '^(\d{4})') { [int]$Matches[1] } else { 0 }
                                $newOver    = [string]$det.overview
                                $newRuntime = if ($det.runtime) { [int]$det.runtime } else { 0 }
                                $directors  = @($det.credits.crew | Where-Object { $_.job -eq 'Director' } | ForEach-Object { [string]$_.name })

                                # Download poster come customPosterPath (il Publisher tratta poster_custom.jpg
                                # come file locale; posterPath resta il path TMDB originale come fallback)
                                $posterWebUrl = $null
                                if (-not [string]::IsNullOrEmpty([string]$det.poster_path)) {
                                    try {
                                        $pDst = Join-Path $metaDir 'poster_custom.jpg'
                                        $absStreamingDir = [System.IO.Path]::GetFullPath($streamingDir)
                                        $absMetaDir      = [System.IO.Path]::GetFullPath($metaDir)
                                        $wc2 = [System.Net.WebClient]::new()
                                        $wc2.DownloadFile("https://image.tmdb.org/t/p/w500$($det.poster_path)", $pDst)
                                        $wc2.Dispose()
                                        if ($absMetaDir.StartsWith($absStreamingDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                                            $relPath = $absMetaDir.Substring($absStreamingDir.Length).TrimStart('\') + '\poster_custom.jpg'
                                            $posterWebUrl = '/' + $relPath.Replace('\', '/')
                                        }
                                    } catch {}
                                }

                                # Update metadata.json
                                $metaPath = Join-Path $metaDir 'metadata.json'
                                $md = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                                $md | Add-Member -NotePropertyName 'title'    -NotePropertyValue $newTitle   -Force
                                if ($newYear -gt 0)    { $md | Add-Member -NotePropertyName 'year'     -NotePropertyValue $newYear    -Force }
                                $md | Add-Member -NotePropertyName 'overview' -NotePropertyValue $newOver    -Force
                                if ($newRuntime -gt 0) { $md | Add-Member -NotePropertyName 'runtime'  -NotePropertyValue $newRuntime -Force }
                                if ($directors.Count -gt 0) { $md | Add-Member -NotePropertyName 'directors' -NotePropertyValue $directors -Force }
                                if ($posterWebUrl) {
                                    # Salva come customPosterPath so the Publisher picks it up as a local file
                                    $md | Add-Member -NotePropertyName 'customPosterPath' -NotePropertyValue 'poster_custom.jpg' -Force
                                }
                                $md | ConvertTo-Json -Depth 10 | Set-Content $metaPath -Encoding UTF8

                                # Update catalog.json
                                if (Test-Path $catalogFile) {
                                    $cat = Get-Content $catalogFile -Raw -Encoding UTF8 | ConvertFrom-Json
                                    foreach ($ci in @($cat.items)) {
                                        if ([string]$ci.id -eq $itemId) {
                                            $ci | Add-Member -NotePropertyName 'title'    -NotePropertyValue $newTitle   -Force
                                            if ($newYear -gt 0)    { $ci | Add-Member -NotePropertyName 'year'     -NotePropertyValue $newYear    -Force }
                                            $ci | Add-Member -NotePropertyName 'overview' -NotePropertyValue $newOver    -Force
                                            if ($newRuntime -gt 0) { $ci | Add-Member -NotePropertyName 'runtime'  -NotePropertyValue $newRuntime -Force }
                                            if ($directors.Count -gt 0) { $ci | Add-Member -NotePropertyName 'director' -NotePropertyValue $directors[0] -Force }
                                            if ($posterWebUrl)     { $ci | Add-Member -NotePropertyName 'posterUrl' -NotePropertyValue $posterWebUrl -Force }
                                        }
                                    }
                                    $cat | ConvertTo-Json -Depth 10 | Set-Content $catalogFile -Encoding UTF8
                                }

                                $out = [ordered]@{ updated = $itemId; title = $newTitle; year = $newYear; runtime = $newRuntime; directors = $directors }
                                if ($posterWebUrl) { $out['posterUrl'] = $posterWebUrl }
                                Send-Response $ctx $out
                            }
                        }
                    }
                } catch {
                    Send-Response $ctx @{ error = $_.Exception.Message } 500
                }
            }
        }

        else {
            Send-Response $ctx @{ error = 'Endpoint non trovato' } 404
        }

        } catch {
            # Per-request catch: log the error but keep the listener alive.
            # Common cause: HttpListenerException when client disconnects mid-response.
            Write-Host ("[admin-api] request error [$method $path]: " + $_.Exception.Message)
            try { Send-Response $ctx @{ error = 'Internal server error' } 500 } catch {}
        }
    }
} finally {
    $listener.Stop()
    Write-Host '[admin-api] Stopped.'
}
