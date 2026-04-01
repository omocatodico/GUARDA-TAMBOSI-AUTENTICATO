@{
    Tmdb = @{
        ApiKey = 'PUT_API_KEY_HERE'
        ReadAccessToken = 'PUT_READ_ACCESS_TOKEN_HERE'
        LanguagePrimary = 'it-IT'
        LanguageFallback = 'en-US'
    }

    Admin = @{
        Pin = 'PUT_ADMIN_PIN_HERE'
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
        MakeMkvDir = 'TOOLS\makemkv'
    }

    Caddy = @{
        AccessLogPath = 'LOGS\caddy-access.log'
        ErrorLogPath  = 'LOGS\caddy-error.log'
        BaseUrl       = 'http://movieserver.local'
    }

    RipWatcher = @{
        DiscTitleMaxAttempts = 3
        DiscRetryDelaySeconds = 8
    }

    # URL da cui Bootstrap.psm1 scarica i binari al primo avvio.
    # Lascia vuoto per usare i sorgenti pubblici (GitHub releases / makemkv.com).
    # Compila con URL del tuo server per hosting privato dei binari.
    Downloads = @{
        FfmpegZipUrl        = ''   # zip contenente ffmpeg.exe, ffprobe.exe, ffplay.exe
        CaddyZipUrl         = ''   # zip contenente caddy.exe
        MakeMkvInstallerUrl = ''   # installer .exe di MakeMKV
    }

    # Autenticazione LDAP per il catalogo pubblico (opzionale).
    # Se presente e Server non vuoto, index.html richiede login LDAP.
    # Se assente, il catalogo resta pubblico senza autenticazione.
    Ldap = @{
        Server       = ''
        Port         = 389
        Domain       = 'EXAMPLE.LOCAL'
        BaseDN       = 'dc=example,dc=local'
        SearchFilter = '(&(sAMAccountName=:user))'
        UseTLS       = $false
        SessionDays  = 30   # durata sessione in giorni
    }
}
