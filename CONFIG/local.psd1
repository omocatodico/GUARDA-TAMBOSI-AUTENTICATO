@{
    Tmdb = @{
        ApiKey = '20303ef14971f890568978a94f86dc5f'
        ReadAccessToken = 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIyMDMwM2VmMTQ5NzFmODkwNTY4OTc4YTk0Zjg2ZGM1ZiIsIm5iZiI6MTY0MTgxNzQyNy4xMTAwMDAxLCJzdWIiOiI2MWRjMjU1MzEyMTk3ZTAwNDFiYjE4OTYiLCJzY29wZXMiOlsiYXBpX3JlYWQiXSwidmVyc2lvbiI6MX0.NwMETA7WByNpFoWsJ-yXPg4fgNpWfIaIwcRcXujzucw'
        LanguagePrimary = 'it-IT'
        LanguageFallback = 'en-US'
    }

    Admin = @{
        Pin = 'Melanzana666'
    }

    Paths = @{
        Ingest    = 'INGEST'
        Rip       = 'RIP'
        Work      = 'WORK'
        Streaming = 'STREAMING'
        Logs      = 'LOGS'
        Temp      = 'TEMP'
    }

    Tools = @{
        FfmpegBin  = 'TOOLS\ffmpeg\bin'
        FfmpegExe  = 'TOOLS\ffmpeg\bin\ffmpeg.exe'
        FfprobeExe = 'TOOLS\ffmpeg\bin\ffprobe.exe'
    }

    Caddy = @{
        AccessLogPath = 'LOGS\caddy-access.log'
        ErrorLogPath  = 'LOGS\caddy-error.log'
        BaseUrl       = 'https://guarda.tambosi.asetti.co'
    }

    RipWatcher = @{
        DiscTitleMaxAttempts = 3
        DiscRetryDelaySeconds = 8
    }

    # URL da cui Bootstrap.psm1 scarica i binari al primo avvio.
    # Lascia vuoto per usare i sorgenti pubblici (GitHub releases / makemkv.com).
    # Compila con URL del tuo server per hosting privato.
    Downloads = @{
        FfmpegZipUrl        = ''   # zip contenente ffmpeg.exe, ffprobe.exe, ffplay.exe
        CaddyZipUrl         = ''   # zip contenente caddy.exe
        MakeMkvInstallerUrl = ''   # installer .exe di MakeMKV
    }

    Cloudflare = @{
        ApiToken = 'cfat_2QfHBvvcCWVtLFJiLU8IXh1d26eSlmvAXpAGcajsd6498649'
    }

    # Autenticazione LDAP per il catalogo pubblico (opzionale).
    # Se presente e Server non vuoto, index.html richiede login LDAP.
    # Se assente, il catalogo resta pubblico senza autenticazione.
    Ldap = @{
        Server       = '172.21.0.10'
        Port         = 389
        Domain       = 'tambosi.local'
        BaseDN       = 'dc=tambosi,dc=local'
        SearchFilter = '(&(sAMAccountName=:user)(|(memberof=CN=Assistenti_laboratorio,OU=Gruppi,OU=didattica,DC=tambosi,DC=local)(memberof=CN=Docenti,OU=Gruppi,OU=didattica,DC=tambosi,DC=local)))'
        UseTLS       = $false
        SessionDays  = 30   # durata sessione in giorni
    }
}
