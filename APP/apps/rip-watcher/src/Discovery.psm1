Set-StrictMode -Version Latest

$script:SupportedExtensions = @('.avi', '.mp4', '.mkv', '.mov', '.m4v', '.wmv')

function Get-IngestCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,

        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$Queue
    )

    if (-not (Test-Path -Path $Config.Paths.Ingest)) {
        return @()
    }

    $candidates = @()
    $files = Get-ChildItem -Path $Config.Paths.Ingest -File -Recurse | Where-Object { $script:SupportedExtensions -contains $_.Extension.ToLowerInvariant() }
    foreach ($file in $files) {
        $fingerprint = 'ingest::{0}::{1}::{2}' -f $file.FullName.ToLowerInvariant(), $file.Length, $file.LastWriteTimeUtc.Ticks
        if (Test-RipQueueFingerprint -Queue $Queue -Fingerprint $fingerprint -SourcePath $file.FullName) {
            continue
        }

        $candidates += [pscustomobject]@{
            SourceType = 'ingest-file'
            SourcePath = $file.FullName
            DisplayName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            Fingerprint = $fingerprint
            NextAction = 'inspect-source'
            Details = [pscustomobject]@{
                extension = $file.Extension.ToLowerInvariant()
                size = $file.Length
                lastWriteUtc = $file.LastWriteTimeUtc.ToString('s')
            }
        }
    }

    return $candidates
}

function Get-OpticalDriveCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,

        [AllowEmptyCollection()]
        [Parameter(Mandatory)]
        [object[]]$Queue
    )

    $candidates = @()
    $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType = 5"
    foreach ($drive in @($drives)) {
        # Skip empty optical drives (no disc inserted — Size is null or 0)
        if ($null -eq $drive.Size -or [long]$drive.Size -le 0) {
            continue
        }

        $drivePath = '{0}\' -f $drive.DeviceID
        if (-not (Test-Path -Path $drivePath)) {
            continue
        }

        $label = if ([string]::IsNullOrWhiteSpace($drive.VolumeName)) { $drive.DeviceID } else { $drive.VolumeName }
        # Include VolumeSerialNumber so two different discs with the same generic
        # label (e.g. "DVDVolume") are treated as distinct entries in the queue.
        $serial = if ([string]::IsNullOrWhiteSpace($drive.VolumeSerialNumber)) { 'noserial' } else { $drive.VolumeSerialNumber.ToLowerInvariant() }
        $fingerprint = 'optical::{0}::{1}::{2}' -f $drive.DeviceID.ToLowerInvariant(), $label.ToLowerInvariant(), $serial
        if (Test-RipQueueFingerprint -Queue $Queue -Fingerprint $fingerprint) {
            continue
        }

        # Settle check: Windows Explorer can queue a shell-eject (from a previous Shell.Application
        # InvokeVerb call, e.g. from MakeMKV) that fires as soon as a new disc is inserted.
        # Wait 3s and re-query to confirm the disc is still physically present before queuing.
        Start-Sleep -Seconds 3
        $settled = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($drive.DeviceID)' AND DriveType=5"
        if ($null -eq $settled -or $null -eq $settled.Size -or [long]$settled.Size -le 0) {
            continue
        }

        $candidates += [pscustomobject]@{
            SourceType = 'optical-disc'
            SourcePath = $drivePath
            DisplayName = $label
            Fingerprint = $fingerprint
            NextAction = 'rip-disc'
            Details = [pscustomobject]@{
                driveLetter = $drive.DeviceID
                volumeName = $label
                providerName = $drive.ProviderName
                volumeSerial = $drive.VolumeSerialNumber
            }
        }
    }

    return $candidates
}

Export-ModuleMember -Function Get-IngestCandidates, Get-OpticalDriveCandidates
