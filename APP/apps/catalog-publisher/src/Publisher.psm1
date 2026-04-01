Set-StrictMode -Version Latest

function ConvertTo-WebPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AbsolutePath,

        [Parameter(Mandatory)]
        [string]$StreamingRoot
    )

    $root = [System.IO.Path]::GetFullPath($StreamingRoot).TrimEnd('\\')
    $full = [System.IO.Path]::GetFullPath($AbsolutePath)
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $rel = $full.Substring($root.Length).TrimStart('\\')
    return ($rel -replace '\\', '/')
}

function Get-CatalogItems {
    [CmdletBinding()]
    param(
        [Parameter()]
        [object[]]$Queue = @(),

        [Parameter(Mandatory)]
        [string]$StreamingRoot
    )

    $items = @()
    foreach ($job in @($Queue | Where-Object { $_.status -eq 'encoded' })) {
        if ($null -eq $job.metadataDir -or -not (Test-Path $job.metadataDir)) {
            continue
        }

        $metadataPath = Join-Path $job.metadataDir 'metadata.json'
        if (-not (Test-Path $metadataPath)) {
            continue
        }

        $metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
        $masterPath = $null
        if ($null -ne $job.hlsDir) {
            $cand = Join-Path $job.hlsDir 'master.m3u8'
            if (Test-Path $cand) {
                $masterPath = $cand
            }
        }

        $posterUrl = $null
        # Custom poster uploaded via admin overrides TMDB poster
        $customPosterProp = $metadata.PSObject.Properties['customPosterPath']
        if ($null -ne $customPosterProp -and -not [string]::IsNullOrWhiteSpace([string]$customPosterProp.Value)) {
            $customAbs = Join-Path $job.metadataDir ([string]$customPosterProp.Value)
            if (Test-Path $customAbs) {
                $webPath = ConvertTo-WebPath -AbsolutePath $customAbs -StreamingRoot $StreamingRoot
                if ($null -ne $webPath) { $posterUrl = '/' + $webPath }
            }
        }
        # Fallback to TMDB poster
        if ($null -eq $posterUrl) {
            $posterProp = $metadata.PSObject.Properties['posterPath']
            if ($null -ne $posterProp -and -not [string]::IsNullOrWhiteSpace([string]$posterProp.Value)) {
                $posterUrl = 'https://image.tmdb.org/t/p/w500' + [string]$posterProp.Value
            }
        }

        # Safely read properties absent in one metadata type (movie vs tv)
        $metaProps    = $metadata.PSObject.Properties
        $typeProp     = $metaProps['type']
        $metaType     = if ($null -ne $typeProp)     { [string]$typeProp.Value }     else { '' }
        $titleProp    = if ($metaType -eq 'tv')      { $metaProps['showTitle'] }      else { $metaProps['title'] }
        $metaTitle    = if ($null -ne $titleProp)    { [string]$titleProp.Value }    else { '' }
        $yearProp     = $metaProps['year']
        $metaYear     = if ($null -ne $yearProp)     { $yearProp.Value }              else { $null }
        $overviewProp = $metaProps['overview']
        $metaOverview = if ($null -ne $overviewProp) { [string]$overviewProp.Value } else { '' }
        $tmdbProp     = $metaProps['tmdbId']
        $showTmdbProp = $metaProps['showTmdbId']
        $rawTmdbId    = 0
        if ($null -ne $tmdbProp -and $null -ne $tmdbProp.Value)             { $rawTmdbId = $tmdbProp.Value }
        elseif ($null -ne $showTmdbProp -and $null -ne $showTmdbProp.Value) { $rawTmdbId = $showTmdbProp.Value }

        $metaYearInt  = if ($null -ne $metaYear) { [int]$metaYear } else { $null }
        $hlsMasterUrl = if ($null -ne $masterPath) { ConvertTo-WebPath -AbsolutePath $masterPath -StreamingRoot $StreamingRoot } else { $null }

        # director(s): first entry from directors array, or empty string
        $directorsProp = $metaProps['directors']
        $metaDirector  = ''
        if ($null -ne $directorsProp -and $null -ne $directorsProp.Value) {
            $dirList = @($directorsProp.Value)
            if ($dirList.Count -gt 0) { $metaDirector = [string]$dirList[0] }
        }

        # runtime (minutes as integer)
        $runtimeProp = $metaProps['runtime']
        $metaRuntime = $null
        if ($null -ne $runtimeProp -and $null -ne $runtimeProp.Value) {
            $rv = $runtimeProp.Value
            if ($rv -is [int] -or $rv -is [long] -or $rv -is [double]) { $metaRuntime = [int]$rv }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$rv)) {
                $parsed = 0
                if ([int]::TryParse([string]$rv, [ref]$parsed)) { $metaRuntime = $parsed }
            }
        }

        # maxResolution: read master.m3u8 and pick largest RESOLUTION= value
        $metaMaxRes = ''
        if ($null -ne $masterPath -and (Test-Path $masterPath)) {
            $bestW = 0
            foreach ($line in (Get-Content $masterPath)) {
                if ($line -match 'RESOLUTION=(\d+)x(\d+)') {
                    if ([int]$Matches[1] -gt $bestW) {
                        $bestW = [int]$Matches[1]
                        $metaMaxRes = "$($Matches[1])x$($Matches[2])"
                    }
                }
            }
        }

        $items += [ordered]@{
            id          = $job.id
            type        = $metaType
            title       = $metaTitle
            year        = $metaYearInt
            overview    = $metaOverview
            director    = $metaDirector
            runtime     = $metaRuntime
            maxRes      = $metaMaxRes
            tmdbId      = [int]$rawTmdbId
            hlsMaster   = $hlsMasterUrl
            metadata    = ConvertTo-WebPath -AbsolutePath $metadataPath -StreamingRoot $StreamingRoot
            posterUrl   = $posterUrl
            updatedAt   = [string]$job.updatedAt
        }
    }

    return @($items | Sort-Object @{ Expression = 'updatedAt'; Descending = $true })
}

function Get-CatalogIndexHtml {
    [CmdletBinding()]
    param()

    return @'
<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>MOVIESERVER Catalog</title>
  <style>
    :root {
      --bg: #f5f2ea;
      --ink: #1b1b1b;
      --accent: #bb3e03;
      --card: #fffaf2;
      --muted: #6b675f;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Trebuchet MS", "Segoe UI", sans-serif;
      background: radial-gradient(circle at 20% 0%, #fff4de 0%, var(--bg) 45%, #efe6d8 100%);
      color: var(--ink);
    }
    header {
      padding: 20px;
      border-bottom: 3px solid #e8d6bc;
      background: linear-gradient(90deg, #fff8ee, #f9ebd7);
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
    }
    h1 { margin: 0; font-size: 1.6rem; letter-spacing: 1px; }
    .sub { color: var(--muted); font-size: 0.9rem; }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
      gap: 16px;
      padding: 20px;
    }
    .card {
      background: var(--card);
      border: 1px solid #ead7be;
      border-radius: 12px;
      overflow: hidden;
      box-shadow: 0 8px 24px rgba(0,0,0,0.08);
      animation: rise .35s ease both;
    }
    @keyframes rise {
      from { transform: translateY(6px); opacity: 0; }
      to { transform: translateY(0); opacity: 1; }
    }
    .poster {
      width: 100%;
      height: 320px;
      object-fit: cover;
      background: #ddd;
    }
    .body { padding: 12px; }
    .title { font-weight: 700; font-size: 1.05rem; }
    .meta { color: var(--muted); font-size: .88rem; margin-top: 4px; }
    .ov { margin-top: 10px; font-size: .9rem; line-height: 1.4; min-height: 76px; }
    .actions { display: flex; gap: 8px; margin-top: 10px; }
    .btn {
      border: 0;
      background: var(--accent);
      color: #fff;
      padding: 8px 10px;
      border-radius: 8px;
      cursor: pointer;
      text-decoration: none;
      font-size: .88rem;
      display: inline-block;
    }
    .empty { padding: 28px; color: var(--muted); }
  </style>
</head>
<body>
  <header>
    <div>
      <h1>MOVIESERVER Catalog</h1>
      <div class="sub" id="sub">Loading...</div>
    </div>
    <a class="btn" href="admin.html">Admin</a>
  </header>
  <main>
    <div id="grid" class="grid"></div>
    <div id="empty" class="empty" style="display:none;">Nessun contenuto pubblicato.</div>
  </main>

  <script>
    const grid = document.getElementById('grid');
    const empty = document.getElementById('empty');
    const sub = document.getElementById('sub');

    function esc(v) {
      return String(v || '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
    }

    async function main() {
      try {
        const res = await fetch('catalog.json', { cache: 'no-store' });
        const data = await res.json();
        const items = Array.isArray(data.items) ? data.items : [];
        sub.textContent = `Aggiornato: ${data.generatedAt || '-'} | Titoli: ${items.length}`;

        if (!items.length) {
          empty.style.display = 'block';
          return;
        }

        for (const it of items) {
          const poster = it.posterUrl ? `<img class="poster" src="${esc(it.posterUrl)}" alt="${esc(it.title)}">` : `<div class="poster"></div>`;
          const hls = it.hlsMaster ? `<a class="btn" href="${esc(it.hlsMaster)}">Playlist HLS</a>` : '';
          const meta = it.metadata ? `<a class="btn" href="${esc(it.metadata)}">Metadata</a>` : '';

          const card = document.createElement('article');
          card.className = 'card';
          card.innerHTML = `
            ${poster}
            <div class="body">
              <div class="title">${esc(it.title)}</div>
              <div class="meta">${esc(it.type)} ${it.year ? '• ' + esc(it.year) : ''}</div>
              <div class="ov">${esc(it.overview || 'Nessuna descrizione disponibile.')}</div>
              <div class="actions">${hls}${meta}</div>
            </div>`;
          grid.appendChild(card);
        }
      } catch (e) {
        sub.textContent = 'Errore caricamento catalogo';
        empty.style.display = 'block';
      }
    }

    main();
  </script>
</body>
</html>
'@
}

function Get-AdminHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Pin
    )

    $safePin = ($Pin -replace '\\', '\\\\' -replace "'", "\\'")

    return @"
<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>MOVIESERVER Admin</title>
  <style>
    body { margin: 0; font-family: "Trebuchet MS", sans-serif; background:#111; color:#f5f5f5; }
    .wrap { max-width: 760px; margin: 40px auto; padding: 20px; }
    .card { background:#1d1d1d; border:1px solid #333; border-radius: 12px; padding: 20px; }
    h1 { margin-top: 0; }
    .ok { color:#7ad66f; }
    .ko { color:#ff7d7d; }
    a { color:#f7b267; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>Admin Area</h1>
      <p id="state">Verifica PIN...</p>
      <div id="content" style="display:none;">
        <p class="ok">Accesso autorizzato.</p>
        <p>Questa area e statica. Per operazioni server-side usa gli script PowerShell nel workspace.</p>
        <ul>
          <li>Rigenera catalogo: <code>apps\catalog-publisher\catalog-publisher.ps1</code></li>
          <li>Riesegui encode: <code>apps\hls-encoder\hls-encoder.ps1</code></li>
        </ul>
        <p><a href="index.html">Torna al catalogo</a></p>
      </div>
    </div>
  </div>

  <script>
    const state = document.getElementById('state');
    const content = document.getElementById('content');
    const expected = '$safePin';
    const input = prompt('Inserisci PIN admin');
    if (input === expected) {
      state.textContent = 'PIN valido';
      state.className = 'ok';
      content.style.display = 'block';
    } else {
      state.textContent = 'PIN non valido';
      state.className = 'ko';
    }
  </script>
</body>
</html>
"@
}

Export-ModuleMember -Function ConvertTo-WebPath, Get-CatalogItems, Get-CatalogIndexHtml, Get-AdminHtml
