Set-StrictMode -Version Latest

$script:VideoExts = @('.mkv', '.mp4', '.mov', '.m4v', '.avi', '.wmv')

function Resolve-SourceVideo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Job
    )

    if ($Job.sourceType -eq 'ingest-file' -and (Test-Path $Job.sourcePath)) {
        return [string]$Job.sourcePath
    }

    if ($null -ne $Job.ripOutputDir -and (Test-Path $Job.ripOutputDir)) {
        $cand = Get-ChildItem -Path $Job.ripOutputDir -File -Recurse |
            Where-Object { $script:VideoExts -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object Length -Descending |
            Select-Object -First 1
        if ($null -ne $cand) {
            return $cand.FullName
        }
    }

    return $null
}

function Get-SourceVideoSize {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$FfprobeExe,
        [Parameter(Mandatory)] [string]$SourceFile
    )

    $args = @('-v', 'error', '-select_streams', 'v:0', '-print_format', 'json',
              '-show_entries', 'stream=width,height', $SourceFile)
    $json = & $FfprobeExe @args 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ Width = 0; Height = 0 }
    }
    $probe = $json | ConvertFrom-Json
    $s = @($probe.streams) | Select-Object -First 1
    if ($null -eq $s -or $null -eq $s.height) {
        return [pscustomobject]@{ Width = 0; Height = 0 }
    }
    return [pscustomobject]@{ Width = [int]$s.width; Height = [int]$s.height }
}

# Probe available hardware encoders by running a 1-frame null test encode.
# Returns: 'nvenc' | 'qsv' | 'cpu'
function Get-HwEncoder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$FfmpegExe
    )

    $testArgs = @('-f', 'lavfi', '-i', 'color=black:s=128x128:d=0.04',
                  '-frames:v', '1', '-an', '-f', 'null', '-')

    # NVIDIA NVENC
    & $FfmpegExe @('-loglevel', 'error') @testArgs @('-c:v', 'h264_nvenc') 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return 'nvenc' }

    # Intel QuickSync
    & $FfmpegExe @('-loglevel', 'error') @testArgs @('-c:v', 'h264_qsv') 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return 'qsv' }

    return 'cpu'
}

function Get-AudioTrackMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FfprobeExe,

        [Parameter(Mandatory)]
        [string]$SourceFile,

        [Parameter(Mandatory)]
        [string[]]$Preference
    )

    # Three-pass audio probe: default -> 100M probesize -> max probesize
    # Some MKV files from MakeMKV (especially DVD rips) have audio track headers
    # far into the file and require an extended scan to be detected.
    $baseArgs = @('-print_format', 'json', '-show_streams')
    $streams = $null
    $probe = $null
    $probeAttempts = @(
        @(),
        @('-probesize', '100M', '-analyzeduration', '100M'),
        @('-probesize', '2147483647', '-analyzeduration', '2147483647')
    )
    foreach ($probeExtra in $probeAttempts) {
        $ffProbeArgs = @('-v', 'error') + $probeExtra + $baseArgs + @($SourceFile)
        $json = & $FfprobeExe @ffProbeArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "ffprobe failed for: $SourceFile"
        }
        $probe = ($json | Where-Object { $_ -is [string] }) -join '' | ConvertFrom-Json
        $streams = @($probe.streams | Where-Object { $_.codec_type -eq 'audio' })
        if ($streams.Count -gt 0) { break }
    }

    if ($streams.Count -eq 0) {
        # Log ALL streams found so we can diagnose what's actually in the file
        $allStreams = $probe.streams | ForEach-Object {
            "$($_.index):$($_.codec_type)/$($_.codec_name)"
        }
        $allStreamsSummary = ($allStreams) -join ', '
        Write-Warning "No audio streams found in: $SourceFile - all streams: [$allStreamsSummary]"
        return [pscustomobject]@{ StreamIndex = $null; Language = 'none' }
    }

    foreach ($pref in $Preference) {
        if ($pref -eq 'best') {
            $first = $streams | Select-Object -First 1
            return [pscustomobject]@{ StreamIndex = [int]$first.index; Language = 'best' }
        }

        # Capture loop variable before entering the Where-Object scriptblock.
        # PS 5.1 with Set-StrictMode -Version Latest cannot always resolve the
        # foreach loop variable $pref from inside a pipeline scriptblock scope.
        $prefLocal = $pref
        $match = $streams | Where-Object {
            $lang = ''
            if ($null -ne $_.tags -and $null -ne $_.tags.language) {
                $lang = [string]$_.tags.language
            }
            ($lang.ToLowerInvariant().StartsWith($prefLocal.ToLowerInvariant()))
        } | Select-Object -First 1

        if ($null -ne $match) {
            return [pscustomobject]@{ StreamIndex = [int]$match.index; Language = $pref }
        }
    }

    # No preferred language matched - fall back to first available track (any codec, will be transcoded to AAC)
    $fallback = $streams | Select-Object -First 1
    return [pscustomobject]@{ StreamIndex = [int]$fallback.index; Language = 'fallback' }
}

# Run cropdetect on 3 sample points (10%, 30%, 50% of duration) and return the
# most-voted crop= filter string, or '' if no meaningful letterbox is found.
function Get-CropParams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$FfmpegExe,
        [Parameter(Mandatory)] [string]$FfprobeExe,
        [Parameter(Mandatory)] [string]$SourceFile
    )

    # 1. Get video duration
    $dJson = & $FfprobeExe @('-v', 'error', '-print_format', 'json',
                              '-show_entries', 'format=duration', $SourceFile) 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    $dur = try { [double](($dJson | ConvertFrom-Json).format.duration) } catch { 0 }
    if ($dur -le 60) { return '' }   # too short to sample safely

    # 2. Sample at 10%, 30%, 50% — seek before -i for speed
    $cropVotes = @{}
    foreach ($pct in @(0.10, 0.30, 0.50)) {
        $startSec = [int]($dur * $pct)
        $cdArgs = @('-loglevel', 'info',
                    '-ss', $startSec,
                    '-i', $SourceFile,
                    '-vf', 'cropdetect=24:2:0',
                    '-frames:v', '30',
                    '-f', 'null', '-')
        $output = & $FfmpegExe @cdArgs 2>&1
        foreach ($line in @($output)) {
            if ($line -match 'crop=(\d+:\d+:\d+:\d+)') {
                $k = $Matches[1]
                $cropVotes[$k] = ([int]($cropVotes[$k] -as [int])) + 1
            }
        }
    }

    if ($cropVotes.Count -eq 0) { return '' }

    # 3. Pick the most-voted crop value
    $best = $cropVotes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $parts = $best.Key -split ':'
    $w = [int]$parts[0]; $h = [int]$parts[1]; $x = [int]$parts[2]; $y = [int]$parts[3]

    # 4. Get source dimensions to check if crop is meaningful
    $sJson = & $FfprobeExe @('-v', 'error', '-select_streams', 'v:0',
                              '-print_format', 'json',
                              '-show_entries', 'stream=width,height', $SourceFile) 2>$null
    $srcStream = try { ($sJson | ConvertFrom-Json).streams | Select-Object -First 1 } catch { $null }
    if ($null -eq $srcStream) { return '' }
    $sw = [int]$srcStream.width; $sh = [int]$srcStream.height

    # 5. Skip if crop removes <= 16px total on each axis (sensor noise, not real bars)
    if (($sw - $w) -le 16 -and ($sh - $h) -le 16) { return '' }

    return "crop=${w}:${h}:${x}:${y}"
}

function Build-HlsFfmpegArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceFile,

        [Parameter(Mandatory)]
        [string]$OutputDir,

        [Parameter(Mandatory)]
        [string]$ProfileId,

        [Parameter(Mandatory)]
        [pscustomobject]$Profile,

        [Parameter(Mandatory)]
        [pscustomobject]$AudioMap,

        [string]$HwEncoder = 'cpu',

        # Optional crop filter string produced by Get-CropParams (e.g. 'crop=1920:800:0:140').
        # When non-empty it is prepended to the scale/pad chain to strip letterbox bars.
        [string]$CropFilter = ''
    )

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $playlist = Join-Path $OutputDir ("$ProfileId.m3u8")
    $segmentPattern = Join-Path $OutputDir ("${ProfileId}_%05d.ts")

    $aArgs = @('-map', '0:v:0')
    if ($null -ne $AudioMap.StreamIndex) {
        $aArgs += @('-map', "0:$($AudioMap.StreamIndex)")
    }
    elseif ($AudioMap.Language -eq 'none') {
        # Source has no audio at all - encode video-only (surface it as an explicit warning in the log)
        # Nothing added: no -map for audio, and -c:a / -b:a / -ac will be omitted from the args too
    }
    else {
        # Audio detected but no preferred language matched - map first available stream (mandatory, no ?)
        $aArgs += @('-map', '0:a:0')
    }

    $videoCodecArgs = switch ($HwEncoder) {
        'nvenc' { @('-c:v', 'h264_nvenc', '-preset', 'p4',
                    '-b:v', $Profile.VideoBitrate, '-maxrate', $Profile.MaxRate, '-bufsize', $Profile.BufSize,
                    '-profile:v', 'high') }
        'qsv'   { @('-c:v', 'h264_qsv', '-preset', 'medium',
                    '-b:v', $Profile.VideoBitrate, '-maxrate', $Profile.MaxRate, '-bufsize', $Profile.BufSize) }
        default { @('-c:v', 'libx264', '-preset', 'veryfast',
                    '-b:v', $Profile.VideoBitrate, '-maxrate', $Profile.MaxRate, '-bufsize', $Profile.BufSize) }
    }

    $hasAudio = $AudioMap.Language -ne 'none'
    $audioEncodeArgs = if ($hasAudio) {
        @('-c:a', 'aac', '-b:a', $Profile.AudioBitrate, '-ac', '2')
    } else {
        @()
    }

    $vfParts = @()
    if (-not [string]::IsNullOrEmpty($CropFilter)) {
        $vfParts += $CropFilter
    }
    # Scale to target, preserving aspect ratio; round to even (h264 requirement)
    $vfParts += "scale=w=$($Profile.Width):h=$($Profile.Height):force_original_aspect_ratio=decrease:force_divisible_by=2"

    $ffArgs = @(
        '-y',
        '-i', $SourceFile
    ) + $aArgs + $videoCodecArgs + @(
        '-vf', ($vfParts -join ',')
    ) + $audioEncodeArgs + @(
        '-hls_time', '6',
        '-hls_playlist_type', 'vod',
        '-hls_segment_filename', $segmentPattern,
        $playlist
    )

    return [pscustomobject]@{
        Args = $ffArgs
        PlaylistPath = $playlist
    }
}

function Write-HlsMasterPlaylist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputDir,

        [Parameter(Mandatory)]
        [object[]]$Variants
    )

    $master = Join-Path $OutputDir 'master.m3u8'
    $lines = @('#EXTM3U', '#EXT-X-VERSION:3')

    foreach ($v in $Variants) {
        $lines += "#EXT-X-STREAM-INF:BANDWIDTH=$($v.Bandwidth),RESOLUTION=$($v.Width)x$($v.Height)"
        $lines += $v.PlaylistName
    }

    Set-Content -Path $master -Value $lines -Encoding UTF8
    return $master
}

Export-ModuleMember -Function Resolve-SourceVideo, Get-SourceVideoSize, Get-HwEncoder, Get-AudioTrackMap, Get-CropParams, Build-HlsFfmpegArgs, Write-HlsMasterPlaylist
