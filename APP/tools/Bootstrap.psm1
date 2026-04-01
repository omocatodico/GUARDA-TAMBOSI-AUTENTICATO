# Bootstrap.psm1 — Verifica e scarica automaticamente i tool binari necessari.
# Chiamato da run-all.ps1 prima di qualsiasi altra operazione.
Set-StrictMode -Version Latest

# File inferiori a questo sono considerati placeholder Git LFS (tipicamente ~134 byte)
$script:MinBinarySize = 10240  # 10 KB

# Versioni/URL pinned per i tool
$script:FfmpegZipUrl  = 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
$script:CaddyVersion  = 'v2.9.1'
$script:CaddyZipUrl   = 'https://github.com/caddyserver/caddy/releases/download/v2.9.1/caddy_2.9.1_windows_amd64.zip'

function Write-BootLog {
    param([string]$Level, [string]$Message)
    $ts = (Get-Date).ToString('s')
    Write-Output ("[{0}] [BOOTSTRAP/{1}] {2}" -f $ts, $Level.ToUpperInvariant(), $Message)
}

function Test-IsValidBinary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path $Path -PathType Leaf)) { return $false }
    return (Get-Item $Path).Length -ge $script:MinBinarySize
}

function Invoke-FileDownload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Description
    )
    Write-BootLog -Level Info -Message "Download: $Description"
    Write-BootLog -Level Info -Message "  URL: $Url"

    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $usedBits = $false
    try {
        Start-BitsTransfer -Source $Url -Destination $Destination -ErrorAction Stop
        $usedBits = $true
    } catch {
        Write-BootLog -Level Warn -Message "BITS non disponibile, uso WebClient: $($_.Exception.Message)"
    }

    if (-not $usedBits) {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'MovieServer-Bootstrap/1.0')
        $wc.DownloadFile($Url, $Destination)
    }

    if (-not (Test-Path $Destination)) {
        throw "Download fallito per: $Description"
    }
    $sizeMb = [Math]::Round((Get-Item $Destination).Length / 1MB, 1)
    Write-BootLog -Level Info -Message "Download completato: $Description (${sizeMb} MB)"
}

function Install-FfmpegTools {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BinDir,
        [string]$ZipUrl = $script:FfmpegZipUrl
    )

    $ffmpegOk  = Test-IsValidBinary (Join-Path $BinDir 'ffmpeg.exe')
    $ffprobeOk = Test-IsValidBinary (Join-Path $BinDir 'ffprobe.exe')

    if ($ffmpegOk -and $ffprobeOk) {
        Write-BootLog -Level Info -Message "ffmpeg/ffprobe gia' presenti - skip download"
        return
    }

    Write-BootLog -Level Info -Message "ffmpeg/ffprobe mancanti o placeholder - avvio installazione..."

    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    }

    $zipPath    = Join-Path $env:TEMP 'ffmpeg-download.zip'
    $extractDir = Join-Path $env:TEMP 'ffmpeg-extract'

    Invoke-FileDownload -Url $ZipUrl -Destination $zipPath -Description 'FFmpeg (Windows x64, GPL)'

    if (Test-Path $extractDir) {
        [System.IO.Directory]::Delete($extractDir, $true)
    }
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

    Write-BootLog -Level Info -Message "Estrazione FFmpeg..."
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    # Struttura BtbN: ffmpeg-master-YYYYMMDD-win64-gpl/bin/ffmpeg.exe
    $ffmpegFound = Get-ChildItem -Path $extractDir -Recurse -Filter 'ffmpeg.exe' |
        Select-Object -First 1 |
        ForEach-Object { $_.DirectoryName }

    if ([string]::IsNullOrEmpty($ffmpegFound)) {
        throw "ffmpeg.exe non trovato nell'archivio scaricato"
    }

    foreach ($exe in @('ffmpeg.exe', 'ffprobe.exe', 'ffplay.exe')) {
        $src = Join-Path $ffmpegFound $exe
        if (Test-Path $src) {
            [System.IO.File]::Copy($src, (Join-Path $BinDir $exe), $true)
            Write-BootLog -Level Info -Message "Installato: $exe"
        }
    }

    [System.IO.File]::Delete($zipPath)
    [System.IO.Directory]::Delete($extractDir, $true)

    Write-BootLog -Level Info -Message "FFmpeg installato in: $BinDir"
}

function Install-Caddy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BinDir,
        [string]$ZipUrl = $script:CaddyZipUrl
    )

    $caddyExe = Join-Path $BinDir 'caddy.exe'

    if (Test-IsValidBinary $caddyExe) {
        Write-BootLog -Level Info -Message "Caddy gia' presente - skip download"
        return
    }

    Write-BootLog -Level Info -Message "Caddy mancante o placeholder - avvio installazione..."

    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    }

    $zipPath = Join-Path $env:TEMP 'caddy-download.zip'

    Invoke-FileDownload -Url $ZipUrl -Destination $zipPath -Description "Caddy (Windows x64)"

    Write-BootLog -Level Info -Message "Estrazione Caddy..."
    Expand-Archive -Path $zipPath -DestinationPath $BinDir -Force

    [System.IO.File]::Delete($zipPath)

    if (-not (Test-IsValidBinary $caddyExe)) {
        throw "caddy.exe non trovato dopo estrazione in: $BinDir"
    }

    Write-BootLog -Level Info -Message "Caddy installato in: $BinDir"
}

function Get-MakeMkvInstallerUrl {
    # Prova a ricavare la versione corrente dalla pagina di download ufficiale
    $fallback = 'https://www.makemkv.com/download/MakeMKV_v1.17.7_win.exe'
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'MovieServer-Bootstrap/1.0')
        $html = $wc.DownloadString('https://www.makemkv.com/download/')
        if ($html -match 'MakeMKV_v([\d\.]+)_win\.exe') {
            $version = $Matches[1]
            return "https://www.makemkv.com/download/MakeMKV_v${version}_win.exe"
        }
    } catch {
        Write-BootLog -Level Warn -Message "Impossibile determinare la versione MakeMKV corrente, uso versione pinned: $($_.Exception.Message)"
    }
    return $fallback
}

function Install-MakeMkv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstallDir,
        [string]$InstallerUrl = ''
    )

    # Cerca makemkvcon64.exe nella cartella locale
    $local64 = Join-Path $InstallDir 'makemkvcon64.exe'
    if (Test-IsValidBinary $local64) {
        Write-BootLog -Level Info -Message "MakeMKV gia' presente in TOOLS - skip download"
        return
    }

    # Se gia' installato sul sistema non ripeto l'installazione
    $systemPaths = @(
        'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe',
        'C:\Program Files (x86)\MakeMKV\makemkvcon.exe',
        'C:\Program Files\MakeMKV\makemkvcon64.exe',
        'C:\Program Files\MakeMKV\makemkvcon.exe'
    )
    foreach ($sp in $systemPaths) {
        if (Test-IsValidBinary $sp) {
            Write-BootLog -Level Info -Message "MakeMKV trovato nel sistema ($sp) - skip download"
            return
        }
    }

    Write-BootLog -Level Info -Message "MakeMKV non trovato - avvio installazione portabile..."

    $url           = if (-not [string]::IsNullOrWhiteSpace($InstallerUrl)) { $InstallerUrl } else { Get-MakeMkvInstallerUrl }
    $installerPath = Join-Path $env:TEMP 'makemkv-setup.exe'

    Invoke-FileDownload -Url $url -Destination $installerPath -Description 'MakeMKV (Windows installer)'

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    Write-BootLog -Level Info -Message "Installazione silenziosa MakeMKV in: $InstallDir"
    # NSIS silent install: /S = silent, /D= = cartella di destinazione (niente virgolette, path assoluto)
    $proc = Start-Process -FilePath $installerPath -ArgumentList "/S /D=$InstallDir" -Wait -PassThru -ErrorAction Stop
    [System.IO.File]::Delete($installerPath)

    # Cerca il binario anche in eventuali sottocartelle create dall'installer
    $found = Get-ChildItem -Path $InstallDir -Recurse -Filter 'makemkvcon64.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge 10240 } |
        Select-Object -First 1

    if ($null -eq $found) {
        Write-BootLog -Level Warn -Message "makemkvcon64.exe non trovato in $InstallDir dopo installazione (exit code $($proc.ExitCode)) - potrebbe essere necessaria elevazione o riavvio"
    } else {
        Write-BootLog -Level Info -Message "MakeMKV installato: $($found.FullName)"
    }
}

function Invoke-ToolBootstrap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerRoot
    )

    Write-BootLog -Level Info -Message "=== Verifica strumenti ==="

    # Legge URL personalizzati da CONFIG\local.psd1 (sezione Downloads)
    # Se vuoti usa i sorgenti pubblici (GitHub releases / makemkv.com)
    $ffmpegZip  = $script:FfmpegZipUrl
    $caddyZip   = $script:CaddyZipUrl
    $makemkvUrl = ''
    $configPath = Join-Path $ServerRoot 'CONFIG\local.psd1'
    if (Test-Path $configPath) {
        try {
            $cfg = Import-PowerShellDataFile $configPath
            if ($cfg.Downloads) {
                if (-not [string]::IsNullOrWhiteSpace($cfg.Downloads.FfmpegZipUrl))        { $ffmpegZip  = $cfg.Downloads.FfmpegZipUrl        }
                if (-not [string]::IsNullOrWhiteSpace($cfg.Downloads.CaddyZipUrl))         { $caddyZip   = $cfg.Downloads.CaddyZipUrl         }
                if (-not [string]::IsNullOrWhiteSpace($cfg.Downloads.MakeMkvInstallerUrl)) { $makemkvUrl = $cfg.Downloads.MakeMkvInstallerUrl }
            }
        } catch {
            Write-BootLog -Level Warn -Message "Impossibile leggere Downloads da local.psd1: $_"
        }
    }

    Install-FfmpegTools -BinDir (Join-Path $ServerRoot 'TOOLS\ffmpeg\bin') -ZipUrl $ffmpegZip
    Install-Caddy       -BinDir (Join-Path $ServerRoot 'TOOLS\caddy\bin')  -ZipUrl $caddyZip
    Install-MakeMkv     -InstallDir (Join-Path $ServerRoot 'TOOLS\makemkv') -InstallerUrl $makemkvUrl

    Write-BootLog -Level Info -Message "=== Strumenti OK ==="
}

Export-ModuleMember -Function Invoke-ToolBootstrap, Test-IsValidBinary
