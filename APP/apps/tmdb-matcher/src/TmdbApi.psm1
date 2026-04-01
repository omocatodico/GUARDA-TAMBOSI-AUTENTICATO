Set-StrictMode -Version Latest

$script:TmdbBase = 'https://api.themoviedb.org/3'

# Internal helper — sends a GET to TMDB and returns the parsed JSON object.
function Invoke-TmdbGet {
    param(
        [string]$Endpoint,
        [hashtable]$Query,
        [string]$ReadAccessToken
    )

    $headers = @{ Authorization = "Bearer $ReadAccessToken" }

    $qParts = foreach ($kv in $Query.GetEnumerator()) {
        '{0}={1}' -f [uri]::EscapeDataString($kv.Key), [uri]::EscapeDataString([string]$kv.Value)
    }
    $qs  = $qParts -join '&'
    $url = '{0}{1}?{2}' -f $script:TmdbBase, $Endpoint, $qs

    $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop
    return $resp
}

# Search for a movie. Returns the first result object, or $null.
function Find-TmdbMovie {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$TmdbConfig,

        [Parameter(Mandatory)]
        [string]$Title,

        [int]$Year = 0,

        [Parameter(Mandatory)]
        [string]$Language
    )

    $query = @{ query = $Title; language = $Language }
    if ($Year -gt 0) { $query['year'] = $Year }

    $resp = Invoke-TmdbGet -Endpoint '/search/movie' -Query $query -ReadAccessToken $TmdbConfig.ReadAccessToken

    if ($null -eq $resp -or $resp.total_results -eq 0) {
        return $null
    }

    return $resp.results[0]
}

# Get full movie details (credits appended). Returns the details object.
function Get-TmdbMovieDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$TmdbConfig,

        [Parameter(Mandatory)]
        [int]$MovieId,

        [Parameter(Mandatory)]
        [string]$Language
    )

    $query = @{ language = $Language; append_to_response = 'credits' }
    return Invoke-TmdbGet -Endpoint "/movie/$MovieId" -Query $query -ReadAccessToken $TmdbConfig.ReadAccessToken
}

# Search for a TV show. Returns the first result object, or $null.
function Find-TmdbTv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$TmdbConfig,

        [Parameter(Mandatory)]
        [string]$ShowTitle,

        [Parameter(Mandatory)]
        [string]$Language
    )

    $query = @{ query = $ShowTitle; language = $Language }
    $resp = Invoke-TmdbGet -Endpoint '/search/tv' -Query $query -ReadAccessToken $TmdbConfig.ReadAccessToken

    if ($null -eq $resp -or $resp.total_results -eq 0) {
        return $null
    }

    return $resp.results[0]
}

# Get TV show details (credits appended). Returns the show details object.
function Get-TmdbShowDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$TmdbConfig,

        [Parameter(Mandatory)]
        [int]$ShowId,

        [Parameter(Mandatory)]
        [string]$Language
    )

    $query = @{ language = $Language; append_to_response = 'credits' }
    return Invoke-TmdbGet -Endpoint "/tv/$ShowId" -Query $query -ReadAccessToken $TmdbConfig.ReadAccessToken
}

# Get details for a specific episode. Returns the episode details object.
function Get-TmdbEpisodeDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$TmdbConfig,

        [Parameter(Mandatory)]
        [int]$ShowId,

        [Parameter(Mandatory)]
        [int]$Season,

        [Parameter(Mandatory)]
        [int]$Episode,

        [Parameter(Mandatory)]
        [string]$Language
    )

    $query = @{ language = $Language }
    return Invoke-TmdbGet -Endpoint "/tv/$ShowId/season/$Season/episode/$Episode" -Query $query -ReadAccessToken $TmdbConfig.ReadAccessToken
}

Export-ModuleMember -Function Find-TmdbMovie, Get-TmdbMovieDetails, Find-TmdbTv, Get-TmdbShowDetails, Get-TmdbEpisodeDetails
