Set-StrictMode -Version Latest

# Reference bitrate table keyed by horizontal width.
# Used as anchors to interpolate bitrate values for any resolution.
$script:BitrateRef = @(
    [pscustomobject]@{ Width = 3840; VideoBitrate = 12000; MaxRate = 14000; BufSize = 24000; AudioBitrate = 192; Bandwidth = 14000000 }
    [pscustomobject]@{ Width = 1920; VideoBitrate = 6000;  MaxRate = 6500;  BufSize = 12000; AudioBitrate = 160; Bandwidth = 6500000  }
    [pscustomobject]@{ Width = 1280; VideoBitrate = 3000;  MaxRate = 3500;  BufSize = 7000;  AudioBitrate = 128; Bandwidth = 3500000  }
    [pscustomobject]@{ Width = 854;  VideoBitrate = 1200;  MaxRate = 1500;  BufSize = 3000;  AudioBitrate = 96;  Bandwidth = 1500000  }
    [pscustomobject]@{ Width = 640;  VideoBitrate = 800;   MaxRate = 1000;  BufSize = 2000;  AudioBitrate = 96;  Bandwidth = 1000000  }
)

# Standard horizontal-width steps for sub-profiles (descending).
$script:WidthSteps = @(3840, 1920, 1280, 854, 640, 480)

function Get-InterpolatedBitrates {
    [CmdletBinding()]
    param([int]$Width)

    $ref = $script:BitrateRef | Sort-Object Width

    # Below or at smallest reference -> clamp to smallest
    if ($Width -le $ref[0].Width) {
        $r = $ref[0]
        return [pscustomobject]@{
            VideoBitrate = "$($r.VideoBitrate)k"; MaxRate = "$($r.MaxRate)k"
            BufSize = "$($r.BufSize)k"; AudioBitrate = "$($r.AudioBitrate)k"
            Bandwidth = $r.Bandwidth
        }
    }

    # Above or at largest reference -> clamp to largest
    $last = $ref[$ref.Count - 1]
    if ($Width -ge $last.Width) {
        return [pscustomobject]@{
            VideoBitrate = "$($last.VideoBitrate)k"; MaxRate = "$($last.MaxRate)k"
            BufSize = "$($last.BufSize)k"; AudioBitrate = "$($last.AudioBitrate)k"
            Bandwidth = $last.Bandwidth
        }
    }

    # Linear interpolation between the two nearest reference points
    $lower = $null; $upper = $null
    for ($i = 0; $i -lt $ref.Count - 1; $i++) {
        if ($Width -ge $ref[$i].Width -and $Width -le $ref[$i + 1].Width) {
            $lower = $ref[$i]; $upper = $ref[$i + 1]; break
        }
    }

    $t = ($Width - $lower.Width) / [double]($upper.Width - $lower.Width)
    $interp = { param($lo, $hi) [int]($lo + ($hi - $lo) * $t) }

    return [pscustomobject]@{
        VideoBitrate = "$(& $interp $lower.VideoBitrate $upper.VideoBitrate)k"
        MaxRate      = "$(& $interp $lower.MaxRate      $upper.MaxRate)k"
        BufSize      = "$(& $interp $lower.BufSize      $upper.BufSize)k"
        AudioBitrate = "$(& $interp $lower.AudioBitrate $upper.AudioBitrate)k"
        Bandwidth    = [int](& $interp $lower.Bandwidth  $upper.Bandwidth)
    }
}

function RoundEven ([int]$v) { if ($v % 2 -eq 0) { $v } else { $v + 1 } }

<#
.SYNOPSIS
  Build dynamic profile list based on source resolution (post-crop).
  Returns an ordered array of profile objects from highest to lowest resolution.

.DESCRIPTION
  - Main profile uses the source native W x H (no up/downscale).
  - For each standard width step strictly below W, a sub-profile is computed
    preserving the source aspect ratio. Height is rounded to the nearest even
    number (H.264 requirement).
  - Bitrates/bandwidth are interpolated from a reference table.

.EXAMPLE
  Source 720x576  -> profiles: main@720x576, sub@640x512, sub@480x384
  Source 3840x2160 -> profiles: main@3840x2160, sub@1920x1080, sub@1280x720, sub@854x480, sub@640x360
#>
function Get-DynamicProfiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$SourceWidth,
        [Parameter(Mandatory)] [int]$SourceHeight
    )

    if ($SourceWidth -le 0 -or $SourceHeight -le 0) {
        throw "Invalid source dimensions: ${SourceWidth}x${SourceHeight}"
    }

    $profiles = @()

    # 1. Main profile at native resolution
    $mainW = RoundEven $SourceWidth
    $mainH = RoundEven $SourceHeight
    $mainBr = Get-InterpolatedBitrates -Width $mainW
    $profiles += [pscustomobject]@{
        Id           = 'main'
        Width        = $mainW
        Height       = $mainH
        VideoBitrate = $mainBr.VideoBitrate
        MaxRate      = $mainBr.MaxRate
        BufSize      = $mainBr.BufSize
        AudioBitrate = $mainBr.AudioBitrate
        Bandwidth    = $mainBr.Bandwidth
    }

    # 2. Sub-profiles for each standard step whose width is strictly below source
    foreach ($stepW in $script:WidthSteps) {
        if ($stepW -ge $SourceWidth) { continue }
        $stepH = RoundEven ([int][Math]::Round($SourceHeight * $stepW / [double]$SourceWidth))
        if ($stepH -lt 120) { continue }  # too small to be useful
        $br = Get-InterpolatedBitrates -Width $stepW
        $label = switch ($stepW) {
            3840  { '4k' }
            1920  { '1080p' }
            1280  { '720p' }
            854   { '480p' }
            640   { '360p' }
            480   { '240p' }
            default { "${stepW}p" }
        }
        $profiles += [pscustomobject]@{
            Id           = $label
            Width        = $stepW
            Height       = $stepH
            VideoBitrate = $br.VideoBitrate
            MaxRate      = $br.MaxRate
            BufSize      = $br.BufSize
            AudioBitrate = $br.AudioBitrate
            Bandwidth    = $br.Bandwidth
        }
    }

    return ,$profiles
}

# Legacy function kept for backward compatibility (returns the fixed table).
function Get-HlsProfileTable {
    [CmdletBinding()]
    param()

    return @{
        '4k' = [pscustomobject]@{ Width = 3840; Height = 2160; VideoBitrate = '12000k'; MaxRate = '14000k'; BufSize = '24000k'; AudioBitrate = '192k'; Bandwidth = 14000000 }
        '1080p' = [pscustomobject]@{ Width = 1920; Height = 1080; VideoBitrate = '6000k'; MaxRate = '6500k'; BufSize = '12000k'; AudioBitrate = '160k'; Bandwidth = 6500000 }
        '720p' = [pscustomobject]@{ Width = 1280; Height = 720; VideoBitrate = '3000k'; MaxRate = '3500k'; BufSize = '7000k'; AudioBitrate = '128k'; Bandwidth = 3500000 }
        '480p' = [pscustomobject]@{ Width = 854; Height = 480; VideoBitrate = '1200k'; MaxRate = '1500k'; BufSize = '3000k'; AudioBitrate = '96k'; Bandwidth = 1500000 }
    }
}

Export-ModuleMember -Function Get-HlsProfileTable, Get-DynamicProfiles
