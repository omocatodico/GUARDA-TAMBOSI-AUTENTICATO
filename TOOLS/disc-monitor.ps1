<#
.SYNOPSIS
    Monitora un lettore ottico e registra lo stato per diagnosticare
    l'errore "Inserire disco nell'unita H:" dopo un rip MakeMKV.

.DESCRIPTION
    Script completamente autonomo: nessun Import-Module, nessuna dipendenza
    dal resto dell'applicazione. Gira da solo in qualsiasi PowerShell 5.1+.

    Ogni N secondi interroga:
      - Win32_LogicalDisk  (volume montato, Size, etichetta)
      - Win32_CDROMDrive   (MediaLoaded, Status, Availability)
      - IOCTL_STORAGE_CHECK_VERIFY  ->  il drive risponde al driver?
      - Test-Path / Get-ChildItem   ->  accessibilita filesystem
      - Processi sospetti (makemkvcon, explorer, ecc.)
      - Ultimi eventi System-log relativi a cdrom/disk/volume
      - mountvol output per punti di mount
    Si iscrive anche agli eventi WMI asincroni su Win32_LogicalDisk.

.PARAMETER DriveLetter
    Lettera del drive (es. H). Default: H

.PARAMETER PollSeconds
    Intervallo di polling in secondi. Default: 4

.PARAMETER LogFile
    Percorso del file di log. Default: MOVIESERVER\LOGS\disc-monitor-<date>.log

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\MOVIESERVER\TOOLS\disc-monitor.ps1 -DriveLetter H
    powershell -ExecutionPolicy Bypass -File C:\MOVIESERVER\TOOLS\disc-monitor.ps1 -DriveLetter H -LogFile C:\diag\drive.log
#>
[CmdletBinding()]
param(
    [string]$DriveLetter = 'H',
    [int]   $PollSeconds = 4,
    [string]$LogFile     = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---- Log file (default: MOVIESERVER\LOGS, fallback: Desktop) --------------
if ([string]::IsNullOrEmpty($LogFile)) {
    $serverRoot = Split-Path -Parent $PSScriptRoot
    $logsDir    = Join-Path $serverRoot 'LOGS'
    if (-not (Test-Path $logsDir)) {
        try   { New-Item -Path $logsDir -ItemType Directory | Out-Null }
        catch { $logsDir = Join-Path $env:USERPROFILE 'Desktop' }
    }
    $stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $LogFile = Join-Path $logsDir ('disc-monitor-' + $stamp + '.log')
}

# ---- Write-Log ------------------------------------------------------------
function Write-Log {
    param(
        [string]    $Level,
        [string]    $Msg,
        [hashtable] $Data
    )
    if ($null -eq $Data) { $Data = @{} }
    $entry = [ordered]@{ ts = (Get-Date).ToString('s'); level = $Level; msg = $Msg }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    $json = $entry | ConvertTo-Json -Compress -Depth 5
    Add-Content -LiteralPath $LogFile -Value $json -Encoding UTF8
    $color = 'White'
    if ($Level -eq 'WARN')  { $color = 'Yellow' }
    if ($Level -eq 'ERROR') { $color = 'Red' }
    if ($Level -eq 'EVENT') { $color = 'Cyan' }
    Write-Host ('[' + $Level + '] ' + $Msg) -ForegroundColor $color
    if ($Data.Count -gt 0) {
        Write-Host ('  ' + ($Data | ConvertTo-Json -Compress)) -ForegroundColor DarkGray
    }
}

# ---- IOCTL_STORAGE_CHECK_VERIFY -------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace DiscMonitor {
    public static class DriveProbe {
        const uint GENERIC_READ               = 0x80000000;
        const uint FILE_SHARE_READ            = 0x00000001;
        const uint FILE_SHARE_WRITE           = 0x00000002;
        const uint OPEN_EXISTING              = 3;
        const uint IOCTL_STORAGE_CHECK_VERIFY = 0x2D4800;
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
        static extern SafeFileHandle CreateFile(
            string n, uint a, uint s, IntPtr p, uint c, uint f, IntPtr t);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool DeviceIoControl(
            SafeFileHandle h, uint code,
            IntPtr ib, uint is_, IntPtr ob, uint os,
            out uint bytes, IntPtr ov);
        [DllImport("kernel32.dll")]
        static extern uint GetLastError();
        public static string CheckVerify(string dl) {
            string letter = dl.TrimEnd('\\').TrimEnd(':').ToUpper();
            string path   = @"\\.\" + letter + ":";
            using (var h = CreateFile(path, GENERIC_READ,
                       FILE_SHARE_READ | FILE_SHARE_WRITE,
                       IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
                if (h.IsInvalid) return "OPEN_FAILED:err=" + GetLastError();
                uint b;
                bool ok = DeviceIoControl(h, IOCTL_STORAGE_CHECK_VERIFY,
                              IntPtr.Zero, 0, IntPtr.Zero, 0, out b, IntPtr.Zero);
                if (ok) return "READY";
                return "NOT_READY:err=" + GetLastError();
            }
        }
    }
}
'@ -ErrorAction SilentlyContinue

function Invoke-CheckVerify {
    param([string]$Letter)
    try   { return [DiscMonitor.DriveProbe]::CheckVerify($Letter) }
    catch { return 'IOCTL_EXCEPTION:' + $_.Exception.Message }
}

# ---- WMI async event watcher (non bloccante) ------------------------------
$watcher = $null
try {
    $q = "SELECT * FROM __InstanceOperationEvent WITHIN 2 " +
         "WHERE TargetInstance ISA 'Win32_LogicalDisk' " +
         "AND TargetInstance.DriveType = 5"
    $watcher = New-Object System.Management.ManagementEventWatcher $q
    $watcher.Start()
} catch { $watcher = $null }

# ---- Helper: Win32_LogicalDisk + Win32_CDROMDrive -------------------------
function Get-DriveWmiState {
    param([string]$Letter)
    $out = @{ logicalDisk = $null; cdromDrive = $null }
    $dev = $Letter.TrimEnd('\').TrimEnd(':').ToUpper() + ':'
    try {
        $ld = Get-CimInstance -ClassName Win32_LogicalDisk `
                              -Filter ("DeviceID='" + $dev + "'") -ErrorAction Stop
        if ($null -ne $ld) {
            $sz = 0L; if ($null -ne $ld.Size)      { $sz = [long]$ld.Size }
            $fr = 0L; if ($null -ne $ld.FreeSpace) { $fr = [long]$ld.FreeSpace }
            $out.logicalDisk = @{
                DeviceID     = [string]$ld.DeviceID
                VolumeName   = [string]$ld.VolumeName
                Size         = $sz
                FreeSpace    = $fr
                FileSystem   = [string]$ld.FileSystem
                ProviderName = [string]$ld.ProviderName
                DriveType    = [int]$ld.DriveType
            }
        }
    } catch { $out.logicalDisk = @{ error = $_.Exception.Message } }
    try {
        foreach ($cd in @(Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction Stop)) {
            if (([string]$cd.Drive).TrimEnd('\').ToUpper() -ne $dev) { continue }
            $si = 0; if ($null -ne $cd.StatusInfo) { $si = [int]$cd.StatusInfo }
            $out.cdromDrive = @{
                Drive        = [string]$cd.Drive
                MediaLoaded  = [bool]$cd.MediaLoaded
                Status       = [string]$cd.Status
                Availability = [int]$cd.Availability
                StatusInfo   = $si
                Name         = [string]$cd.Name
                Description  = [string]$cd.Description
            }
            break
        }
    } catch { $out.cdromDrive = @{ error = $_.Exception.Message } }
    return $out
}

# ---- Helper: processi che potrebbero tenere il drive occupato -------------
function Get-SuspectProcesses {
    param([string]$Letter)
    $suspects   = @()
    $devTarget  = $Letter.TrimEnd('\').TrimEnd(':').ToUpper() + ':'
    $knownNames = @('makemkvcon','makemkvcon64','explorer','imgburn',
                    'vlc','mpc-hc','mpc-be','wmplayer','dvdstyler','handbrake')
    foreach ($proc in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($knownNames -contains $proc.Name.ToLowerInvariant()) {
            $st = 'unknown'; try { $st = $proc.StartTime.ToString('s') } catch {}
            $suspects += @{ pid = $proc.Id; name = $proc.Name; startTime = $st }
        }
    }
    try {
        $esc = [regex]::Escape($devTarget)
        foreach ($wp in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                           Where-Object { $_.CommandLine -match $esc })) {
            $already = $suspects | Where-Object { $_.pid -eq [int]$wp.ProcessId }
            if ($null -eq $already) {
                $suspects += @{ pid = [int]$wp.ProcessId; name = $wp.Name; cmdline = $wp.CommandLine }
            }
        }
    } catch {}
    return $suspects
}

# ---- Helper: eventi System-log legati al drive ----------------------------
function Get-RecentDriveEvents {
    param([string]$Letter, [int]$MaxEvents = 5)
    $events = @()
    try {
        $lu     = $Letter.TrimEnd('\').TrimEnd(':').ToUpper()
        $filter = @{ LogName = 'System'; StartTime = (Get-Date).AddMinutes(-2) }
        $pat    = 'cdrom|disk|volmgr|partmgr|ntfs|shellhwdetect|storahci|iaStorV|uaspstor'
        foreach ($e in @(Get-WinEvent -FilterHashtable $filter -MaxEvents 50 -ErrorAction SilentlyContinue)) {
            $msg = ''; if ($null -ne $e.Message) { $msg = $e.Message }
            if ($msg -notmatch $lu -and $e.ProviderName -notmatch $pat) { continue }
            $short = ($msg -replace '\r?\n', ' ')
            if ($short.Length -gt 200) { $short = $short.Substring(0, 200) }
            $events += @{
                time     = $e.TimeCreated.ToString('s')
                level    = $e.LevelDisplayName
                provider = $e.ProviderName
                id       = [int]$e.Id
                msg      = $short
            }
            if ($events.Count -ge $MaxEvents) { break }
        }
    } catch { $events += @{ error = $_.Exception.Message } }
    return $events
}

# ---- Helper: mountvol -----------------------------------------------------
function Get-MountPoints {
    param([string]$Letter)
    try {
        $target = $Letter.TrimEnd('\').TrimEnd(':').ToUpper() + ':\'
        $lines  = @(& mountvol 2>&1)
        $rel    = @($lines | Where-Object { $_ -match [regex]::Escape($target) })
        return ($rel -join ' | ')
    } catch { return 'error:' + $_.Exception.Message }
}

# ---- Helper: accessibilita filesystem -------------------------------------
function Test-DriveAccess {
    param([string]$Letter)
    $root = $Letter.TrimEnd('\').TrimEnd(':').ToUpper() + ':\'
    $res  = @{ pathExists = $false; canListRoot = $false; rootItems = 0; error = '' }
    try   { $res.pathExists = Test-Path -LiteralPath $root }
    catch { $res.error = 'test-path:' + $_.Exception.Message }
    if ($res.pathExists) {
        try {
            $res.canListRoot = $true
            $res.rootItems   = @(Get-ChildItem -LiteralPath $root -ErrorAction Stop).Count
        } catch { $res.error = 'list-root:' + $_.Exception.Message }
    }
    return $res
}

# ===========================================================================
# MAIN LOOP
# ===========================================================================
$prevState = @{ ioctlResult = ''; mediaLoaded = $null; ldSize = -1L; pathExists = $null }
$pollCount = 0

Write-Log INFO 'disc-monitor started' @{
    driveLetter = $DriveLetter
    pollSeconds = $PollSeconds
    logFile     = $LogFile
    watcher     = ($null -ne $watcher)
}
Write-Host ''
Write-Host ('Monitoraggio drive ' + $DriveLetter.ToUpper() + ': - Premi Ctrl+C per fermare') -ForegroundColor Green
Write-Host ('Log: ' + $LogFile) -ForegroundColor DarkGray
Write-Host ''

try {
    while ($true) {
        $pollCount++

        $ioctl    = Invoke-CheckVerify -Letter $DriveLetter
        $wmiState = Get-DriveWmiState  -Letter $DriveLetter
        $ld       = $wmiState.logicalDisk
        $cd       = $wmiState.cdromDrive
        $fsAccess = Test-DriveAccess   -Letter $DriveLetter

        $ldSizeNow = 0L; if ($null -ne $ld) { $ldSizeNow = [long]$ld.Size }
        $mlNow     = $null; if ($null -ne $cd) { $mlNow = $cd.MediaLoaded }

        $changed = ($ioctl -ne $prevState.ioctlResult) -or
                   ($mlNow -ne $prevState.mediaLoaded)  -or
                   ($ldSizeNow -ne $prevState.ldSize)    -or
                   ($fsAccess.pathExists -ne $prevState.pathExists)

        $forceLog = ($pollCount % 10 -eq 0)

        if ($changed -or $forceLog) {
            if ($changed) {
                $suspects  = Get-SuspectProcesses -Letter $DriveLetter
                $sysEvents = Get-RecentDriveEvents -Letter $DriveLetter
            } else {
                $suspects  = @()
                $sysEvents = @()
            }
            $mounts = Get-MountPoints -Letter $DriveLetter

            $mlStr = '?'; if ($null -ne $cd) { $mlStr = [string]$cd.MediaLoaded }
            $logMsg = 'drive-state poll=' + $pollCount + ' ioctl=' + $ioctl +
                      ' mediaLoaded=' + $mlStr + ' ldSize=' + $ldSizeNow +
                      ' pathExists=' + $fsAccess.pathExists
            $level = 'WARN'; if ($ioctl -eq 'READY') { $level = 'INFO' }

            Write-Log $level $logMsg @{
                poll        = $pollCount
                ioctl       = $ioctl
                fsAccess    = $fsAccess
                logicalDisk = $ld
                cdromDrive  = $cd
                mounts      = $mounts
                suspects    = $suspects
                sysEvents   = $sysEvents
                changed     = $changed
            }

            $prevState.ioctlResult = $ioctl
            $prevState.mediaLoaded = $mlNow
            $prevState.ldSize      = $ldSizeNow
            $prevState.pathExists  = $fsAccess.pathExists
        } else {
            Write-Host '.' -NoNewline -ForegroundColor DarkGray
        }

        # Controlla eventi WMI asincroni (timeout immediato = non bloccante)
        if ($null -ne $watcher) {
            try {
                $evt = $watcher.WaitForNextEvent()
                if ($null -ne $evt) {
                    $ec  = [string]$evt['__CLASS']
                    $ti  = $evt['TargetInstance']
                    $did = ''; $vn = ''; $tsz = 0L; $tdt = 0
                    if ($null -ne $ti) {
                        if ($null -ne $ti['DeviceID'])   { $did = [string]$ti['DeviceID'] }
                        if ($null -ne $ti['VolumeName']) { $vn  = [string]$ti['VolumeName'] }
                        if ($null -ne $ti['Size'])       { $tsz = [long]$ti['Size'] }
                        if ($null -ne $ti['DriveType'])  { $tdt = [int]$ti['DriveType'] }
                    }
                    Write-Log EVENT ('wmi-volume-event: ' + $ec) @{
                        wmiEventClass = $ec; deviceID = $did
                        volumeName = $vn; size = $tsz; driveType = $tdt
                    }
                }
            } catch {}
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($null -ne $watcher) {
        try { $watcher.Stop(); $watcher.Dispose() } catch {}
    }
    Write-Log INFO 'disc-monitor stopped' @{ totalPolls = $pollCount }
    Write-Host ''
    Write-Host 'Monitoraggio terminato. Log in:' -ForegroundColor Green
    Write-Host $LogFile -ForegroundColor Cyan
}
