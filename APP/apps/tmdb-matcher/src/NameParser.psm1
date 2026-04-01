Set-StrictMode -Version Latest

# Returns a pscustomobject describing the parsed media name.
# Supports two naming conventions (from manifest.json):
#   Movie:   "Movie Title - YYYY"
#   Episode: "Show Name - S01E01 - Episode Title"
# Falls back to treating the full name as a movie title when no pattern matches.

function Get-ParsedMediaName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    # Series: "Show Name - S01E01" or "Show Name - S01E01 - Episode Title"
    if ($DisplayName -match '^(.+?) - S(\d{2})E(\d{2})(?:\s*-\s*(.+))?$') {
        return [pscustomobject]@{
            Type         = 'tv'
            Title        = $null
            Year         = $null
            ShowTitle    = $Matches[1].Trim()
            Season       = [int]$Matches[2]
            Episode      = [int]$Matches[3]
            EpisodeTitle = if ($Matches[4]) { $Matches[4].Trim() } else { '' }
        }
    }

    # Movie: "Title - YYYY"
    if ($DisplayName -match '^(.+?) - (\d{4})$') {
        return [pscustomobject]@{
            Type         = 'movie'
            Title        = $Matches[1].Trim()
            Year         = [int]$Matches[2]
            ShowTitle    = $null
            Season       = $null
            Episode      = $null
            EpisodeTitle = $null
        }
    }

    # Movie: "Title (YYYY)" — parentheses variant
    if ($DisplayName -match '^(.+?)\s*\((\d{4})\)$') {
        return [pscustomobject]@{
            Type         = 'movie'
            Title        = $Matches[1].Trim()
            Year         = [int]$Matches[2]
            ShowTitle    = $null
            Season       = $null
            Episode      = $null
            EpisodeTitle = $null
        }
    }

    # Movie: "Title YYYY" — bare year at end (no dash, no parentheses)
    # Only matches plausible movie years (1888-2099) to avoid false positives.
    if ($DisplayName -match '^(.+?)\s+([12]\d{3})$') {
        return [pscustomobject]@{
            Type         = 'movie'
            Title        = $Matches[1].Trim()
            Year         = [int]$Matches[2]
            ShowTitle    = $null
            Season       = $null
            Episode      = $null
            EpisodeTitle = $null
        }
    }

    # Fallback: treat as movie with unknown year.
    # Normalize disc volume labels (ALL_CAPS_NOSPACES) by inserting spaces
    # around common English connector words so TMDB can find them.
    # Only THE/FOR/AND used — short 2-letter words (IN, AT, OR...) cause
    # false splits inside longer words (e.g. AVATAR → AV AT AR).
    $title = $DisplayName.Trim()
    if ($title -match '^[A-Z0-9]+$') {
        # Insert spaces around connector words that appear sandwiched between
        # other uppercase characters (e.g. GARFIELDTHEMOVIE → GARFIELD THE MOVIE)
        $expanded = $title -replace '(?<=[A-Z0-9])(THE|FOR|AND)(?=[A-Z])', ' $1 '
        # Also handle leading THE/A (e.g. THEDARKKNIGHT → THE DARKKNIGHT)
        $expanded = $expanded -replace '^(THE|FOR|AND)(?=[A-Z])', '$1 '
        $expanded = $expanded.Trim() -replace '\s+', ' '
        if ($expanded -ne $title) {
            $title = (Get-Culture).TextInfo.ToTitleCase($expanded.ToLowerInvariant())
        }
    }
    return [pscustomobject]@{
        Type         = 'movie'
        Title        = $title
        Year         = $null
        ShowTitle    = $null
        Season       = $null
        Episode      = $null
        EpisodeTitle = $null
    }
}

Export-ModuleMember -Function Get-ParsedMediaName
