Set-StrictMode -Version Latest

$script:KnownPaths = @(
    'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe',
    'C:\Program Files (x86)\MakeMKV\makemkvcon.exe',
    'C:\Program Files\MakeMKV\makemkvcon64.exe',
    'C:\Program Files\MakeMKV\makemkvcon.exe'
)

function Find-MakeMkvCon {
    [CmdletBinding()]
    param(
        [string]$HintDir = ''
    )

    # Check local TOOLS installation first (portable, takes priority over system install)
    if (-not [string]::IsNullOrEmpty($HintDir)) {
        foreach ($candidate in @('makemkvcon64.exe', 'makemkvcon.exe')) {
            $p = Join-Path $HintDir $candidate
            if ((Test-Path -Path $p) -and (Get-Item $p).Length -ge 10240) {
                return $p
            }
        }
    }

    foreach ($path in $script:KnownPaths) {
        if (Test-Path -Path $path) {
            return $path
        }
    }

    $fromPath = Get-Command 'makemkvcon' -ErrorAction SilentlyContinue
    if ($null -ne $fromPath) {
        return $fromPath.Source
    }

    $fromPath = Get-Command 'makemkvcon64' -ErrorAction SilentlyContinue
    if ($null -ne $fromPath) {
        return $fromPath.Source
    }

    return $null
}

function Get-DiscIndexForDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MakeMkvConPath,

        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    # Normalize to "D:" form (strip trailing backslash)
    $normalized = ($DriveLetter.TrimEnd('\').TrimEnd(':')) + ':'

    # disc:9999 asks MakeMKV to list all drives (no valid disc at that index)
    $output = & $MakeMkvConPath --robot info disc:9999 2>&1

    foreach ($line in @($output)) {
        $s = [string]$line
        # DRV:index,visible,enabled,flags,"drive name","disc label","D:" or "D:\"
        if ($s -match '^DRV:(\d+),\d+,\d+,\d+,"[^"]*","[^"]*","([^"]+)"') {
            $idx = [int]$matches[1]
            $drvPath = [string]$matches[2]
            $drvNorm = $drvPath.TrimEnd('\').ToUpperInvariant()
            $target  = $normalized.ToUpperInvariant()
            if ($drvNorm -eq $target) {
                Write-Verbose "Resolved drive $DriveLetter to MakeMKV disc index $idx"
                return $idx
            }
        }
    }

    Write-Warning "Could not resolve drive $DriveLetter to a MakeMKV disc index; defaulting to 0"
    return 0
}

function ConvertTo-Seconds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Duration
    )

    $parts = $Duration -split ':'
    if ($parts.Count -lt 3) {
        return 0
    }

    try {
        return ([int]$parts[-3] * 3600) + ([int]$parts[-2] * 60) + [int]$parts[-1]
    }
    catch {
        return 0
    }
}

function Get-DiscTitles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MakeMkvConPath,

        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    $discIndex = Get-DiscIndexForDrive -MakeMkvConPath $MakeMkvConPath -DriveLetter $DriveLetter
    $discArg = "disc:$discIndex"

    $output = & $MakeMkvConPath --robot info $discArg 2>&1
    $titleMap = @{}
    $streamMap = @{}

    foreach ($line in @($output)) {
        $s = [string]$line

        if ($s -match '^TINFO:(\d+),9,\d+,"(.+)"') {
            $tid = [int]$matches[1]
            $dur = $matches[2]
            if (-not $titleMap.ContainsKey($tid)) {
                $titleMap[$tid] = [pscustomobject]@{ Id = $tid; DurationSeconds = 0; DurationString = ''; Name = '' }
            }
            $titleMap[$tid].DurationSeconds = ConvertTo-Seconds -Duration $dur
            $titleMap[$tid].DurationString = $dur
        }

        if ($s -match '^TINFO:(\d+),2,\d+,"(.+)"') {
            $tid = [int]$matches[1]
            if (-not $titleMap.ContainsKey($tid)) {
                $titleMap[$tid] = [pscustomobject]@{ Id = $tid; DurationSeconds = 0; DurationString = ''; Name = '' }
            }
            $titleMap[$tid].Name = $matches[2]
        }

        if ($s -match '^SINFO:(\d+),(\d+),20,\d+,"(.+)"') {
            $tid = [int]$matches[1]
            $sid = [int]$matches[2]
            $type = $matches[3]
            $key = "$tid`:$sid"
            if (-not $streamMap.ContainsKey($key)) {
                $streamMap[$key] = [pscustomobject]@{ TitleId = $tid; StreamId = $sid; Type = $type; LangCode = ''; LangName = '' }
            }
            $streamMap[$key].Type = $type
        }

        if ($s -match '^SINFO:(\d+),(\d+),2,\d+,"(.+)"') {
            $tid = [int]$matches[1]
            $sid = [int]$matches[2]
            $lang = $matches[3]
            $key = "$tid`:$sid"
            if (-not $streamMap.ContainsKey($key)) {
                $streamMap[$key] = [pscustomobject]@{ TitleId = $tid; StreamId = $sid; Type = ''; LangCode = ''; LangName = '' }
            }
            $streamMap[$key].LangCode = $lang.ToLowerInvariant()
        }
    }

    foreach ($t in $titleMap.Values) {
        $t | Add-Member -NotePropertyName 'AudioTracks' -NotePropertyValue @(
            $streamMap.Values | Where-Object { $_.TitleId -eq $t.Id -and $_.Type -eq 'Audio' }
        )
    }

    return @($titleMap.Values)
}

function Select-MainTitle {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$Titles
    )

    if ($Titles.Count -eq 0) {
        return $null
    }

    return $Titles | Sort-Object DurationSeconds -Descending | Select-Object -First 1
}

function Invoke-DiscRip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MakeMkvConPath,

        [Parameter(Mandatory)]
        [string]$DriveLetter,

        [Parameter(Mandatory)]
        [int]$TitleId,

        [Parameter(Mandatory)]
        [string]$OutputDir,

        [scriptblock]$OnProgress
    )

    if (-not (Test-Path -Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory | Out-Null
    }

    $discIndex = Get-DiscIndexForDrive -MakeMkvConPath $MakeMkvConPath -DriveLetter $DriveLetter

    # Capture all makemkvcon output synchronously — no pipe, no background threads.
    # The MKV data is written directly to $OutputDir by makemkvcon; stdout/stderr only
    # contains small text progress/status lines (PRGV:, MSG:, etc.).
    $rawOutput = @(& $MakeMkvConPath --robot --decrypt mkv "disc:$discIndex" $TitleId $OutputDir 2>&1)
    $exitCode = $LASTEXITCODE

    $allLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $rawOutput) {
        $s = if ($item -is [System.Management.Automation.ErrorRecord]) {
            [string]$item.Exception.Message
        } else {
            [string]$item
        }
        if (-not [string]::IsNullOrWhiteSpace($s)) {
            $allLines.Add($s)
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($allLines)
    }
}

function Eject-OpticalDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    $letter = ($DriveLetter.TrimEnd('\') -replace ':.*', '').ToUpper()
    $devicePath = "\\.\${letter}:"

    # Eject sequence (USB-safe):
    #   1. IOCTL_STORAGE_ALLOW_MEDIUM_REMOVAL — unlock the drive so the eject
    #      is not rejected at driver level (required on some USB drives)
    #   2. IOCTL_STORAGE_EJECT_MEDIA          — synchronous physical eject
    #   3. SHChangeNotify(SHCNE_MEDIAREMOVED)  — tell Windows Shell the media
    #      was removed.  Without this, Explorer keeps a pending eject command
    #      in its internal queue that fires on the *next* disc, ejecting it
    #      immediately.  On USB optical drives this also prevents the volume
    #      manager from skipping the auto-mount of the subsequent disc.
    try {
        if (-not ('MovieServer.StorageEject' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace MovieServer {
    public static class StorageEject {
        const uint GENERIC_READ        = 0x80000000;
        const uint GENERIC_WRITE       = 0x40000000;
        const uint FILE_SHARE_READ     = 0x00000001;
        const uint FILE_SHARE_WRITE    = 0x00000002;
        const uint OPEN_EXISTING       = 3;
        // CTL_CODE(IOCTL_STORAGE_BASE=0x2d, 0x0201, METHOD_BUFFERED, FILE_READ_ACCESS)
        const uint IOCTL_STORAGE_ALLOW_MEDIUM_REMOVAL = 0x2D4804;
        // CTL_CODE(IOCTL_STORAGE_BASE=0x2d, 0x0202, METHOD_BUFFERED, FILE_READ_ACCESS)
        const uint IOCTL_STORAGE_EJECT                = 0x2D4808;
        // CTL_CODE(IOCTL_STORAGE_BASE=0x2d, 0x0003, METHOD_BUFFERED, FILE_READ_ACCESS|FILE_WRITE_ACCESS)
        // Resets the USB device driver state — software equivalent of unplugging/replugging
        const uint IOCTL_STORAGE_RESET_DEVICE         = 0x002DC00C;

        // SHCNE_MEDIAREMOVED = 0x00000800 — notify Shell that media was removed
        // SHCNF_PATHW        = 0x0005      — dwItem1 is a Unicode path pointer
        const int  SHCNE_MEDIAREMOVED  = 0x00000800;
        const uint SHCNF_PATHW         = 0x0005;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        static extern SafeFileHandle CreateFile(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(
            SafeFileHandle hDevice, uint dwIoControlCode,
            IntPtr lpInBuffer, uint nInBufferSize,
            IntPtr lpOutBuffer, uint nOutBufferSize,
            out uint lpBytesReturned, IntPtr lpOverlapped);

        [DllImport("shell32.dll")]
        static extern void SHChangeNotify(int wEventId, uint uFlags,
            IntPtr dwItem1, IntPtr dwItem2);

        public static bool Eject(string devicePath) {
            using (var h = CreateFile(devicePath,
                                      GENERIC_READ,
                                      FILE_SHARE_READ | FILE_SHARE_WRITE,
                                      IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
                if (h.IsInvalid) return false;
                uint bytes;
                // Step 1: unlock drive (ignore failure — drive may already be unlocked)
                DeviceIoControl(h, IOCTL_STORAGE_ALLOW_MEDIUM_REMOVAL,
                                IntPtr.Zero, 0, IntPtr.Zero, 0, out bytes, IntPtr.Zero);
                // Step 2: eject
                return DeviceIoControl(h, IOCTL_STORAGE_EJECT,
                                       IntPtr.Zero, 0, IntPtr.Zero, 0,
                                       out bytes, IntPtr.Zero);
            }
        }

        public static void NotifyShellMediaRemoved(string drivePath) {
            // drivePath must be "X:\" form (trailing backslash required by Shell)
            IntPtr pPath = Marshal.StringToHGlobalUni(drivePath);
            try   { SHChangeNotify(SHCNE_MEDIAREMOVED, SHCNF_PATHW, pPath, IntPtr.Zero); }
            finally { Marshal.FreeHGlobal(pPath); }
        }

        public static bool ResetDevice(string devicePath) {
            // Open with read+write so the driver accepts the reset IOCTL.
            // This call silently fails (returns false) if the driver does not
            // support the command or if access is denied — caller ignores the result.
            using (var h = CreateFile(devicePath,
                                      GENERIC_READ | GENERIC_WRITE,
                                      FILE_SHARE_READ | FILE_SHARE_WRITE,
                                      IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
                if (h.IsInvalid) return false;
                uint bytes;
                return DeviceIoControl(h, IOCTL_STORAGE_RESET_DEVICE,
                                       IntPtr.Zero, 0, IntPtr.Zero, 0,
                                       out bytes, IntPtr.Zero);
            }
        }
    }
}
'@
        }
        [MovieServer.StorageEject]::Eject($devicePath) | Out-Null
        # Step 3: notify Shell — critical for USB optical drives to allow
        # the volume manager to auto-mount the next inserted disc
        [MovieServer.StorageEject]::NotifyShellMediaRemoved("${letter}:\") | Out-Null
        # Step 4: wait for tray to open fully, then send IOCTL_STORAGE_RESET_DEVICE.
        # This resets the USB device driver state (equivalent to physical
        # disconnect/reconnect) so that the next disc inserted is recognized.
        # The call is best-effort: it fails silently if the driver doesn't support it.
        Start-Sleep -Seconds 2
        [MovieServer.StorageEject]::ResetDevice($devicePath) | Out-Null
    }
    catch {
        # Fallback: Shell.Application — still correct in error cases because
        # Shell.Application.Eject() internally fires SHChangeNotify for us
        try {
            $wshell = New-Object -ComObject Shell.Application
            $drive = $wshell.Namespace("${letter}:\")
            if ($null -ne $drive) {
                $drive.Self.InvokeVerb('Eject')
            }
        }
        catch { }
    }
}

Export-ModuleMember -Function Find-MakeMkvCon, Get-DiscTitles, Select-MainTitle, Invoke-DiscRip, Eject-OpticalDrive
