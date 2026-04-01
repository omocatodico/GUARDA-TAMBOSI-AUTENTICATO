[CmdletBinding()]
param(
    [string]$ServerRoot = '',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ServerRoot)) {
    $ServerRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptRoot))
}
Import-Module (Join-Path $scriptRoot 'src\Config.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Logger.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Queue.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Profiles.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\FfTools.psm1') -Force -DisableNameChecking

function Set-JobProp {
    param([pscustomobject]$Job, [string]$Name, $Value)
    $Job | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

$config = Get-HlsEncoderConfig -ServerRoot $ServerRoot
Initialize-HlsEncoderStorage -Config $config

Write-HlsEncoderLog -Config $config -Level Info -Message 'hls-encoder started' -Data @{ dryRun = [bool]$DryRun }

if (-not (Test-Path $config.Tools.FfmpegExe)) {
    throw "ffmpeg.exe not found at: $($config.Tools.FfmpegExe)"
}
if (-not (Test-Path $config.Tools.FfprobeExe)) {
    throw "ffprobe.exe not found at: $($config.Tools.FfprobeExe)"
}

$queue = Get-HlsQueue -Config $config

# Delete ripOutputDir for any already-encoded optical-disc jobs (catches leftovers from past runs)
foreach ($doneJob in @($queue | Where-Object { $_.status -eq 'encoded' -and $_.sourceType -eq 'optical-disc' })) {
    $ripDirProp = $doneJob.PSObject.Properties['ripOutputDir']
    if ($null -ne $ripDirProp) {
        $ripDir = [string]$ripDirProp.Value
        if (-not [string]::IsNullOrWhiteSpace($ripDir) -and (Test-Path -LiteralPath $ripDir)) {
            try {
                Remove-Item -LiteralPath $ripDir -Recurse -Force
                Write-HlsEncoderLog -Config $config -Level Info -Message 'rip output folder deleted (startup cleanup)' -Data @{ id = $doneJob.id; displayName = $doneJob.displayName; ripOutputDir = $ripDir }
            } catch {
                Write-HlsEncoderLog -Config $config -Level Warning -Message 'failed to delete rip output folder (startup cleanup)' -Data @{ id = $doneJob.id; displayName = $doneJob.displayName; ripOutputDir = $ripDir; error = $_.Exception.Message }
            }
        }
    }
}

# Remove orphaned ingest-file jobs whose source no longer exists
$pruned = @($queue | Where-Object {
    $isOrphaned = $_.sourceType -eq 'ingest-file' `
        -and ($null -ne $_.sourcePath) `
        -and (-not (Test-Path -LiteralPath $_.sourcePath)) `
        -and ($_.status -ne 'encoded')
    if ($isOrphaned) {
        Write-HlsEncoderLog -Config $config -Level Warning -Message 'removing orphaned ingest job (source file missing)' -Data @{ id = $_.id; displayName = $_.displayName; sourcePath = $_.sourcePath }
    }
    -not $isOrphaned
})
if ($pruned.Count -lt $queue.Count -and -not $DryRun) {
    Save-HlsQueue -Config $config -Queue $pruned
    $queue = $pruned
}

$pending = @($queue | Where-Object { $_.status -eq 'matched' })
if ($pending.Count -eq 0) {
    Write-HlsEncoderLog -Config $config -Level Info -Message 'no matched jobs found' -Data @{}
    exit 0
}

foreach ($job in $pending) {
    $logData = @{ id = $job.id; displayName = $job.displayName; sourceType = $job.sourceType }

    try {
        if (-not $DryRun) {
            $queueMark = Get-HlsQueue -Config $config
            foreach ($q in $queueMark) {
                if ($q.id -eq $job.id) {
                    Set-JobProp $q 'status' 'encoding'
                    Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
                }
            }
            Save-HlsQueue -Config $config -Queue $queueMark
        }
        Write-HlsEncoderLog -Config $config -Level Info -Message 'job status updated' -Data ($logData + @{ status = 'encoding' })

        $sourceFile = Resolve-SourceVideo -Job $job
        if ($null -eq $sourceFile) {
            throw 'no valid source video file found'
        }

        if (-not (Test-Path $sourceFile)) {
            throw "source file not found: $sourceFile"
        }

        $baseDir = if ($null -ne $job.metadataDir -and (Test-Path $job.metadataDir)) {
            $job.metadataDir
        }
        else {
            Join-Path $config.Paths.Streaming ("misc\" + ($job.displayName -replace '[\\/:*?"<>|]', '_'))
        }

        $hlsDir = Join-Path $baseDir 'hls'
        if (-not (Test-Path $hlsDir)) {
            New-Item -ItemType Directory -Path $hlsDir -Force | Out-Null
        }

        $audioMap = $null
        if ($DryRun) {
            try {
                $audioMap = Get-AudioTrackMap -FfprobeExe $config.Tools.FfprobeExe -SourceFile $sourceFile -Preference $config.AudioPref
            }
            catch {
                $audioMap = [pscustomobject]@{ StreamIndex = $null; Language = 'probe-unavailable' }
                Write-HlsEncoderLog -Config $config -Level Warning -Message '[DryRun] ffprobe unavailable for source, using no-audio map' -Data ($logData + @{ sourceFile = $sourceFile; error = $_.Exception.Message })
            }
        }
        else {
            $audioMap = Get-AudioTrackMap -FfprobeExe $config.Tools.FfprobeExe -SourceFile $sourceFile -Preference $config.AudioPref
        }

        Write-HlsEncoderLog -Config $config -Level Info -Message 'audio track selected' -Data ($logData + @{ streamIndex = $audioMap.StreamIndex; language = $audioMap.Language })

        if ($audioMap.Language -eq 'none') {
            Write-HlsEncoderLog -Config $config -Level Warning -Message 'NO AUDIO STREAMS FOUND in source — encoding video-only; source file may be corrupt or audio-less' -Data ($logData + @{ sourceFile = $sourceFile })
        }

        # Probe source resolution
        $srcSize = Get-SourceVideoSize -FfprobeExe $config.Tools.FfprobeExe -SourceFile $sourceFile
        Write-HlsEncoderLog -Config $config -Level Info -Message 'source video size' -Data ($logData + @{ width = $srcSize.Width; height = $srcSize.Height })

        # Detect best available hardware encoder (cached once per job)
        $hwEncoder = Get-HwEncoder -FfmpegExe $config.Tools.FfmpegExe
        Write-HlsEncoderLog -Config $config -Level Info -Message 'hardware encoder detected' -Data ($logData + @{ hwEncoder = $hwEncoder })
        if (-not $DryRun) {
            $queueMark2 = Get-HlsQueue -Config $config
            foreach ($q in $queueMark2) {
                if ($q.id -eq $job.id) {
                    Set-JobProp $q 'hwEncoder' $hwEncoder
                    Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
                }
            }
            Save-HlsQueue -Config $config -Queue $queueMark2
        }

        # Auto-detect letterbox bars (once per job, before encoding all profiles)
        $cropFilter = ''
        try {
            $cropFilter = Get-CropParams -FfmpegExe $config.Tools.FfmpegExe -FfprobeExe $config.Tools.FfprobeExe -SourceFile $sourceFile
            if (-not [string]::IsNullOrEmpty($cropFilter)) {
                Write-HlsEncoderLog -Config $config -Level Info -Message 'letterbox detected, crop filter applied' -Data ($logData + @{ cropFilter = $cropFilter })
            }
            else {
                Write-HlsEncoderLog -Config $config -Level Info -Message 'no letterbox detected' -Data $logData
            }
        }
        catch {
            Write-HlsEncoderLog -Config $config -Level Warning -Message 'cropdetect failed, encoding without crop' -Data ($logData + @{ error = $_.Exception.Message })
        }

        # Compute effective source dimensions after crop
        $effectiveW = $srcSize.Width; $effectiveH = $srcSize.Height
        if ($cropFilter -match 'crop=(\d+):(\d+):\d+:\d+') {
            $effectiveW = [int]$Matches[1]; $effectiveH = [int]$Matches[2]
        }

        # Build dynamic profile list based on effective (post-crop) resolution
        $dynamicProfiles = Get-DynamicProfiles -SourceWidth $effectiveW -SourceHeight $effectiveH
        $profileSummary = ($dynamicProfiles | ForEach-Object { "$($_.Id)=$($_.Width)x$($_.Height)" }) -join ', '
        Write-HlsEncoderLog -Config $config -Level Info -Message 'dynamic profiles computed' -Data ($logData + @{ effectiveSize = "${effectiveW}x${effectiveH}"; profiles = $profileSummary })

        $variants = @()
        foreach ($profile in $dynamicProfiles) {
            $profileId = $profile.Id
            $build = Build-HlsFfmpegArgs -SourceFile $sourceFile -OutputDir $hlsDir -ProfileId $profileId -Profile $profile -AudioMap $audioMap -HwEncoder $hwEncoder -CropFilter $cropFilter
            $ffCmdArgs = @($build.Args)

            if ($DryRun) {
                Write-HlsEncoderLog -Config $config -Level Info -Message '[DryRun] ffmpeg command prepared' -Data ($logData + @{ profile = $profileId; resolution = "$($profile.Width)x$($profile.Height)"; command = ($ffCmdArgs -join ' ') })
            }
            else {
                Write-HlsEncoderLog -Config $config -Level Info -Message 'encoding profile' -Data ($logData + @{ profile = $profileId; resolution = "$($profile.Width)x$($profile.Height)" })
                $savedEAP = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                & $config.Tools.FfmpegExe @ffCmdArgs 2>&1 | Out-Null
                $ffExitCode = $LASTEXITCODE
                if ($ffExitCode -ne 0 -and $hwEncoder -ne 'cpu') {
                    Write-HlsEncoderLog -Config $config -Level Warning -Message 'hw encoder failed, retrying with cpu' -Data ($logData + @{ profile = $profileId; hwEncoder = $hwEncoder; exitCode = $ffExitCode })
                    $cpuBuild = Build-HlsFfmpegArgs -SourceFile $sourceFile -OutputDir $hlsDir -ProfileId $profileId -Profile $profile -AudioMap $audioMap -HwEncoder 'cpu' -CropFilter $cropFilter
                    & $config.Tools.FfmpegExe @($cpuBuild.Args) 2>&1 | Out-Null
                    $ffExitCode = $LASTEXITCODE
                }
                $ErrorActionPreference = $savedEAP
                if ($ffExitCode -ne 0) {
                    throw "ffmpeg failed on profile $profileId with exit code $ffExitCode"
                }
            }

            $variants += [pscustomobject]@{
                PlaylistName = "$profileId.m3u8"
                Width = $profile.Width
                Height = $profile.Height
                Bandwidth = $profile.Bandwidth
            }
        }

        if ($variants.Count -eq 0) {
            throw 'no output variants produced'
        }

        if ($DryRun) {
            Write-HlsEncoderLog -Config $config -Level Info -Message '[DryRun] would write master playlist' -Data ($logData + @{ outputDir = $hlsDir; variants = $variants.Count })
        }
        else {
            $master = Write-HlsMasterPlaylist -OutputDir $hlsDir -Variants $variants
            Write-HlsEncoderLog -Config $config -Level Info -Message 'master playlist created' -Data ($logData + @{ master = $master })
        }

        $queue2 = Get-HlsQueue -Config $config
        foreach ($q in $queue2) {
            if ($q.id -eq $job.id) {
                Set-JobProp $q 'status' 'encoded'
                Set-JobProp $q 'hlsDir' $hlsDir
                Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
            }
        }

        if (-not $DryRun) {
            Save-HlsQueue -Config $config -Queue $queue2
        }

        Write-HlsEncoderLog -Config $config -Level Info -Message 'job encoded' -Data ($logData + @{ outputDir = $hlsDir })

        # Delete the source after successful encoding
        if (-not $DryRun) {
            if ($job.sourceType -eq 'ingest-file' -and $null -ne $job.sourcePath -and (Test-Path -LiteralPath $job.sourcePath)) {
                try {
                    Remove-Item -LiteralPath $job.sourcePath -Force
                    Write-HlsEncoderLog -Config $config -Level Info -Message 'ingest source deleted' -Data ($logData + @{ sourcePath = $job.sourcePath })
                } catch {
                    Write-HlsEncoderLog -Config $config -Level Warning -Message 'failed to delete ingest source' -Data ($logData + @{ sourcePath = $job.sourcePath; error = $_.Exception.Message })
                }
            }
            if ($job.sourceType -eq 'optical-disc') {
                $ripDir = $null
                $ripDirProp = $job.PSObject.Properties['ripOutputDir']
                if ($null -ne $ripDirProp) { $ripDir = [string]$ripDirProp.Value }
                if (-not [string]::IsNullOrWhiteSpace($ripDir) -and (Test-Path -LiteralPath $ripDir)) {
                    try {
                        Remove-Item -LiteralPath $ripDir -Recurse -Force
                        Write-HlsEncoderLog -Config $config -Level Info -Message 'rip output folder deleted' -Data ($logData + @{ ripOutputDir = $ripDir })
                    } catch {
                        Write-HlsEncoderLog -Config $config -Level Warning -Message 'failed to delete rip output folder' -Data ($logData + @{ ripOutputDir = $ripDir; error = $_.Exception.Message })
                    }
                }
            }
        }
    }
    catch {
        Write-HlsEncoderLog -Config $config -Level Error -Message 'encode failed' -Data ($logData + @{ error = $_.Exception.Message })

        $queue2 = Get-HlsQueue -Config $config
        foreach ($q in $queue2) {
            if ($q.id -eq $job.id) {
                Set-JobProp $q 'status' 'error'
                Set-JobProp $q 'error' $_.Exception.Message
                Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
            }
        }

        if (-not $DryRun) {
            Save-HlsQueue -Config $config -Queue $queue2
        }
    }
}

Write-HlsEncoderLog -Config $config -Level Info -Message 'hls-encoder finished' -Data @{}
