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
Import-Module (Join-Path $scriptRoot 'src\Config.psm1')    -Force
Import-Module (Join-Path $scriptRoot 'src\Logger.psm1')    -Force
Import-Module (Join-Path $scriptRoot 'src\Queue.psm1')     -Force
Import-Module (Join-Path $scriptRoot 'src\NameParser.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\TmdbApi.psm1')   -Force -DisableNameChecking

# ── helpers ──────────────────────────────────────────────────────────────────

function Set-JobProp {
    param([pscustomobject]$Job, [string]$Name, $Value)
    $Job | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-SafeName {
    param([string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_').Trim()
}

function Get-CrewNames {
    param($Crew, [string]$Job)
    $safe = @($Crew) | Where-Object { $null -ne $_ -and $_.job -eq $Job }
    return @($safe | ForEach-Object { $_.name })
}

function Get-CastList {
    param($Cast, [int]$Top = 10)
    return @(@($Cast) | Where-Object { $null -ne $_ } | Select-Object -First $Top | ForEach-Object {
        @{ name = $_.name; character = $_.character }
    })
}

function Build-MovieMetadata {
    param($Details)

    $directors = Get-CrewNames -Crew $Details.credits.crew -Job 'Director'
    $cast       = Get-CastList  -Cast $Details.credits.cast

    $year = $null
    if ($Details.release_date -match '(\d{4})') { $year = [int]$Matches[1] }

    $genres = @(@($Details.genres) | Where-Object { $null -ne $_ } | ForEach-Object { $_.name })

    return [ordered]@{
        type          = 'movie'
        tmdbId        = $Details.id
        imdbId        = $Details.imdb_id
        title         = $Details.title
        originalTitle = $Details.original_title
        year          = $year
        overview      = $Details.overview
        posterPath    = $Details.poster_path
        backdropPath  = $Details.backdrop_path
        genres        = $genres
        runtime       = $Details.runtime
        directors     = $directors
        cast          = $cast
        matchedAt     = (Get-Date).ToString('s')
    }
}

function Build-TvEpisodeMetadata {
    param($Show, $Episode)

    $directors = Get-CrewNames -Crew $Episode.crew -Job 'Director'
    $cast       = Get-CastList  -Cast $Show.credits.cast

    $genres = @(@($Show.genres) | Where-Object { $null -ne $_ } | ForEach-Object { $_.name })

    return [ordered]@{
        type         = 'tv'
        showTmdbId   = $Show.id
        showTitle    = $Show.name
        season       = $Episode.season_number
        episode      = $Episode.episode_number
        episodeTitle = $Episode.name
        overview     = $Episode.overview
        airDate      = $Episode.air_date
        genres       = $genres
        posterPath   = $Show.poster_path
        directors    = $directors
        cast         = $cast
        matchedAt    = (Get-Date).ToString('s')
    }
}

function Save-MediaMetadata {
    param([string]$OutputDir, $Metadata)

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $Metadata | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $OutputDir 'metadata.json') -Encoding UTF8
}

# ── main ─────────────────────────────────────────────────────────────────────

$config = Get-TmdbMatcherConfig -ServerRoot $ServerRoot
Initialize-TmdbMatcherStorage -Config $config

Write-TmdbMatcherLog -Config $config -Level Info -Message 'tmdb-matcher started' -Data @{ dryRun = [bool]$DryRun }

if ($config.Tmdb.ReadAccessToken -eq 'SET_ME') {
    Write-TmdbMatcherLog -Config $config -Level Error -Message 'TMDB ReadAccessToken not configured in local.psd1' -Data @{}
    exit 1
}

$queue   = Get-TmdbQueue -Config $config

# Remove orphaned ingest-file jobs whose source no longer exists
$pruned = @($queue | Where-Object {
    $isOrphaned = $_.sourceType -eq 'ingest-file' `
        -and ($null -ne $_.sourcePath) `
        -and (-not (Test-Path -LiteralPath $_.sourcePath)) `
        -and ($_.status -ne 'encoded')
    if ($isOrphaned) {
        Write-TmdbMatcherLog -Config $config -Level Warning -Message 'removing orphaned ingest job (source file missing)' -Data @{ id = $_.id; displayName = $_.displayName; sourcePath = $_.sourcePath }
    }
    -not $isOrphaned
})
if ($pruned.Count -lt $queue.Count -and -not $DryRun) {
    Save-TmdbQueue -Config $config -Queue $pruned
    $queue = $pruned
}

$pending = @($queue | Where-Object { $_.status -eq 'ready-for-matching' })

if ($pending.Count -eq 0) {
    Write-TmdbMatcherLog -Config $config -Level Info -Message 'no jobs to match' -Data @{}
    exit 0
}

Write-TmdbMatcherLog -Config $config -Level Info -Message 'processing jobs' -Data @{ count = $pending.Count }

foreach ($job in $pending) {
    $logData = @{ id = $job.id; displayName = $job.displayName; sourceType = $job.sourceType }

    try {
        if (-not $DryRun) {
            $queueMark = Get-TmdbQueue -Config $config
            foreach ($q in $queueMark) {
                if ($q.id -eq $job.id) {
                    Set-JobProp $q 'status' 'matching'
                    Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
                }
            }
            Save-TmdbQueue -Config $config -Queue $queueMark
        }
        Write-TmdbMatcherLog -Config $config -Level Info -Message 'job status updated' -Data ($logData + @{ status = 'matching' })

        $parsed = Get-ParsedMediaName -DisplayName $job.displayName
        Write-TmdbMatcherLog -Config $config -Level Info -Message 'parsed media name' -Data ($logData + @{ type = $parsed.Type; title = $parsed.Title; showTitle = $parsed.ShowTitle; year = $parsed.Year })

        $metadata  = $null
        $outputDir = $null

        # ── movie ─────────────────────────────────────────────────────────────
        if ($parsed.Type -eq 'movie') {
            $yearArg = if ($null -ne $parsed.Year) { $parsed.Year } else { 0 }
            $result = Find-TmdbMovie -TmdbConfig $config.Tmdb -Title $parsed.Title -Year $yearArg -Language $config.Tmdb.LanguagePrimary

            if ($null -eq $result) {
                Write-TmdbMatcherLog -Config $config -Level Warning -Message 'no result in primary lang, trying fallback' -Data $logData
                $result = Find-TmdbMovie -TmdbConfig $config.Tmdb -Title $parsed.Title -Year $yearArg -Language $config.Tmdb.LanguageFallback
            }

            $safeName  = Get-SafeName -Name $job.displayName
            $outputDir = Join-Path $config.Paths.Streaming "movies\$safeName"

            if ($null -eq $result) {
                Write-TmdbMatcherLog -Config $config -Level Warning -Message 'TMDB no results, using filename as title' -Data $logData
                $metadata = [ordered]@{
                    type          = 'movie'
                    tmdbId        = $null
                    imdbId        = $null
                    title         = $parsed.Title
                    originalTitle = $parsed.Title
                    year          = $parsed.Year
                    overview      = ''
                    posterPath    = $null
                    backdropPath  = $null
                    genres        = @()
                    runtime       = $null
                    directors     = @()
                    cast          = @()
                    matchedAt     = (Get-Date).ToString('s')
                }
            }
            else {
                Write-TmdbMatcherLog -Config $config -Level Info -Message 'movie found' -Data ($logData + @{ tmdbId = $result.id; tmdbTitle = $result.title })
                $details  = Get-TmdbMovieDetails -TmdbConfig $config.Tmdb -MovieId $result.id -Language $config.Tmdb.LanguagePrimary
                $metadata = Build-MovieMetadata -Details $details
            }
        }

        # ── tv episode ────────────────────────────────────────────────────────
        elseif ($parsed.Type -eq 'tv') {
            $showResult = Find-TmdbTv -TmdbConfig $config.Tmdb -ShowTitle $parsed.ShowTitle -Language $config.Tmdb.LanguagePrimary

            if ($null -eq $showResult) {
                Write-TmdbMatcherLog -Config $config -Level Warning -Message 'no show in primary lang, trying fallback' -Data $logData
                $showResult = Find-TmdbTv -TmdbConfig $config.Tmdb -ShowTitle $parsed.ShowTitle -Language $config.Tmdb.LanguageFallback
            }

            $safeShow = Get-SafeName -Name $parsed.ShowTitle
            $epCode   = 'S{0:D2}E{1:D2}' -f $parsed.Season, $parsed.Episode

            if ($null -eq $showResult) {
                Write-TmdbMatcherLog -Config $config -Level Warning -Message 'TMDB no results for show, using filename as title' -Data $logData
                $safeEpTitle = Get-SafeName -Name $(if ($parsed.EpisodeTitle) { $parsed.EpisodeTitle } else { $epCode })
                $outputDir   = Join-Path $config.Paths.Streaming "series\$safeShow\$epCode - $safeEpTitle"
                $metadata = [ordered]@{
                    type         = 'tv'
                    showTmdbId   = $null
                    showTitle    = $parsed.ShowTitle
                    season       = $parsed.Season
                    episode      = $parsed.Episode
                    episodeTitle = $parsed.EpisodeTitle
                    overview     = ''
                    airDate      = $null
                    genres       = @()
                    posterPath   = $null
                    directors    = @()
                    cast         = @()
                    matchedAt    = (Get-Date).ToString('s')
                }
            }
            else {
                Write-TmdbMatcherLog -Config $config -Level Info -Message 'show found' -Data ($logData + @{ tmdbId = $showResult.id; tmdbTitle = $showResult.name })
                $show    = Get-TmdbShowDetails    -TmdbConfig $config.Tmdb -ShowId $showResult.id -Language $config.Tmdb.LanguagePrimary
                $episode = Get-TmdbEpisodeDetails -TmdbConfig $config.Tmdb -ShowId $showResult.id -Season $parsed.Season -Episode $parsed.Episode -Language $config.Tmdb.LanguagePrimary
                $metadata = Build-TvEpisodeMetadata -Show $show -Episode $episode
                $safeEpTitle = Get-SafeName -Name $(if ($episode.name) { $episode.name } else { $epCode })
                $outputDir   = Join-Path $config.Paths.Streaming "series\$safeShow\$epCode - $safeEpTitle"
            }
        }

        # ── save ──────────────────────────────────────────────────────────────
        if ($DryRun) {
            $logTmdbId = if ($null -ne $metadata['tmdbId']) { $metadata['tmdbId'] } else { $metadata['showTmdbId'] }
            Write-TmdbMatcherLog -Config $config -Level Info -Message '[DryRun] would write metadata' -Data ($logData + @{ outputDir = $outputDir; tmdbId = $logTmdbId })
        }
        else {
            Save-MediaMetadata -OutputDir $outputDir -Metadata $metadata
            Write-TmdbMatcherLog -Config $config -Level Info -Message 'metadata saved' -Data ($logData + @{ outputDir = $outputDir })
        }

        # ── update queue ──────────────────────────────────────────────────────
        $queue2 = Get-TmdbQueue -Config $config
        foreach ($q in $queue2) {
            if ($q.id -eq $job.id) {
                Set-JobProp $q 'status'      'matched'
                Set-JobProp $q 'metadataDir' $outputDir
                $qTmdbId = if ($null -ne $metadata['tmdbId']) { $metadata['tmdbId'] } else { $metadata['showTmdbId'] }
                Set-JobProp $q 'tmdbId'      $qTmdbId
                Set-JobProp $q 'updatedAt'   (Get-Date).ToString('s')
            }
        }
        if (-not $DryRun) {
            Save-TmdbQueue -Config $config -Queue $queue2
        }
    }
    catch {
        Write-TmdbMatcherLog -Config $config -Level Error -Message 'match failed' -Data ($logData + @{ error = $_.Exception.Message })

        $queue2 = Get-TmdbQueue -Config $config
        foreach ($q in $queue2) {
            if ($q.id -eq $job.id) {
                Set-JobProp $q 'status'    'error'
                Set-JobProp $q 'error'     $_.Exception.Message
                Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
            }
        }
        if (-not $DryRun) {
            Save-TmdbQueue -Config $config -Queue $queue2
        }
    }
}

Write-TmdbMatcherLog -Config $config -Level Info -Message 'tmdb-matcher finished' -Data @{}
