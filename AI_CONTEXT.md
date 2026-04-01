# AI_CONTEXT.md — MOVIESERVER
> Questo file è scritto per un'AI assistant che deve lavorare autonomamente sul progetto.
> Leggi tutto prima di toccare codice.

---

## 1. Cos'è questo progetto

**MOVIESERVER** è un server multimediale domestico completamente autosufficiente che:
1. **Rileva** dischi ottici (DVD/Blu-ray) inseriti o file video in `C:\MOVIESERVER\INGEST\`
2. **Rippa** i dischi con MakeMKV → produce un file `.mkv` in `C:\MOVIESERVER\RIP\`
3. **Abbina** il film a TMDB per ottenere titolo, anno, poster, descrizione
4. **Codifica** in HLS multi-risoluzione con ffmpeg (4K/1080p/720p/480p, AAC, segmenti `.ts`)
5. **Pubblica** un catalogo JSON + frontend HTML statico servito da Caddy su porta 80
6. Espone un **pannello admin** protetto da PIN su `http://movieserver.local/admin.html`

L'intero sistema gira su **Windows** (PowerShell 5.1), senza servizi cloud, senza Docker.

Il sito si chiama **GUARDA TAMBOSI** (titolo e logo 🎬 in `index.html` e `admin.html`).

---

## 2. Struttura cartelle

```
C:\MOVIESERVER\
├── APP\                        # Tutto il codice PowerShell (questo repo)
│   ├── run-all.ps1             # Orchestratore principale — avvia tutto
│   ├── stop-all.ps1            # Ferma tutti i processi
│   ├── admin-api.ps1           # HTTP API REST (porta 9095) per admin panel
│   ├── start-all-admin.exe     # Launcher elevato (UAC) — doppio click per avviare
│   ├── stop-all-admin.exe      # Launcher elevato (UAC) — doppio click per fermare
│   ├── build-start-all-launcher.ps1  # Ricompila start-all-admin.exe dal sorgente C#
│   ├── build-stop-all-launcher.ps1   # Ricompila stop-all-admin.exe dal sorgente C#
│   ├── tools\
│   │   ├── StartAllLauncher.cs      # Sorgente C# del launcher start
│   │   ├── StopAllLauncher.cs       # Sorgente C# del launcher stop
│   │   └── MovieServerService.cs   # Sorgente C# del servizio Windows (ServiceBase)
│   ├── service.ps1                 # Gestione servizio Windows (install/uninstall/start/stop/status/compile)
│   ├── movieserver-service.exe     # ⚠️ Compilato da service.ps1 — NON in git (APP\*.exe escluso)
│   └── apps\
│       ├── rip-watcher\        # Step 1: scoperta sorgenti
│       ├── tmdb-matcher\       # Step 3: metadata TMDB
│       ├── hls-encoder\        # Step 4: encoding ffmpeg
│       └── catalog-publisher\  # Step 5: pubblicazione frontend
├── CONFIG\
│   ├── local.psd1              # ⚠️ SEGRETI: PIN admin, TMDB API key, percorsi
│   ├── local.example.psd1      # Template da copiare come local.psd1
│   ├── manifest.json           # Configurazione comportamento pipeline
│   └── Caddyfile               # Config Caddy (porta 80, reverse proxy /api/*)
├── STREAMING\                  # Output pubblicato — servito da Caddy
│   ├── index.html              # Frontend pubblico catalogo
│   ├── admin.html              # Pannello admin (PIN-protected, JS)
│   ├── hls.min.js              # Player HLS (hls.js)
│   ├── catalog.json            # Catalogo generato (non in git)
│   └── movies\                 # Film codificati (non in git)
│       └── <Nome Film (Anno)>\
│           ├── metadata.json
│           └── hls\
│               ├── master.m3u8
│               ├── 1080p.m3u8
│               ├── 1080p_00001.ts ...
│               └── ...
├── TOOLS\
│   ├── ffmpeg\bin\             # ffmpeg.exe, ffprobe.exe, ffplay.exe (in LFS)
│   └── caddy\bin\              # caddy_windows_amd64.exe (in LFS)
├── WORK\queues\
│   └── rip-jobs.json           # Coda persistente — stato di ogni job
├── INGEST\                     # Punta qui i file .mp4/.mkv da codificare
├── RIP\                        # Output temporaneo MakeMKV (cancellato dopo encoding)
├── LOGS\                       # Log Caddy
├── TEMP\                       # Uso temporaneo pipeline
└── AI_CONTEXT.md               # ← questo file
```

---

## 3. Come funziona il ciclo pipeline

`run-all.ps1` lancia in loop (ogni 20s di default) questi step **in sequenza**:

```
rip-watcher → rip-worker → tmdb-matcher → hls-encoder → catalog-publisher
```

Ogni step è uno script PowerShell separato, invocato come processo figlio e atteso (`Invoke-Step`). Se un passo fallisce, il loop continua comunque al ciclo successivo.

In parallelo (avviati una volta sola con `Start-Process`):
- **Caddy** → serve i file statici e fa reverse proxy di `/api/*` verso porta 9095
- **admin-api.ps1** → HTTP listener su porta 9095

### Dettaglio step

| Step | Script | Cosa fa |
|---|---|---|
| rip-watcher | `apps\rip-watcher\rip-watcher.ps1` | Scansiona drive ottici e cartella INGEST. Per ogni sorgente nuova crea un job `queued` in `rip-jobs.json`. |
| rip-worker | `apps\rip-watcher\rip-worker.ps1` | Prende job `queued` di tipo `optical-disc` e invoca MakeMKV (`makemkvcon --robot mkv`). Output sincrono: `@(& makemkvcon ... 2>&1)`. |
| tmdb-matcher | `apps\tmdb-matcher\tmdb-matcher.ps1` | Prende job che hanno bisogno di metadata. Chiama TMDB API e scrive `metadata.json` in `STREAMING\movies\<nome>\`. |
| hls-encoder | `apps\hls-encoder\hls-encoder.ps1` | Prende job pronti per encoding. Lancia ffmpeg con profili 4K/1080p/720p/480p. Scrive segmenti HLS. Cancella `RIP\<nome>` dopo encoding riuscito. |
| catalog-publisher | `apps\catalog-publisher\catalog-publisher.ps1` | Legge tutti i `metadata.json` e aggiorna `catalog.json` e `index.html`. |

---

## 4. Struttura job (rip-jobs.json)

Ogni job è un oggetto JSON con questi campi principali:

```json
{
  "id": "uuid",
  "createdAt": "ISO8601",
  "sourceType": "optical-disc" | "ingest-file",
  "sourcePath": "percorso file sorgente (ingest) o null (disco)",
  "displayName": "Nome Film (Anno)",
  "status": "queued|ripping|rip-failed|encoded|encoding|matched|matching|ready-for-matching|error",
  "tmdbId": 12345,
  "hwEncoder": "nvenc|qsv|null",
  "metadataDir": "C:\\MOVIESERVER\\STREAMING\\movies\\Nome Film (Anno)",
  "hlsDir": "C:\\MOVIESERVER\\STREAMING\\movies\\Nome Film (Anno)\\hls",
  "ripOutputDir": "C:\\MOVIESERVER\\RIP\\NomeFilm",  // solo optical-disc, rimosso dopo encoding
  "error": "messaggio errore se status=error"
}
```

---

## 5. Configurazione (CONFIG\local.psd1)

```powershell
@{
    Tmdb = @{
        ApiKey = '20303ef14971f890568978a94f86dc5f'
        ReadAccessToken = 'eyJhbGci...'   # JWT Bearer per API TMDB v4
        LanguagePrimary = 'it-IT'
        LanguageFallback = 'en-US'
    }
    Admin = @{
        Pin = 'Melanzana666'              # PIN pannello admin
    }
    Paths = @{
        Ingest    = 'C:\MOVIESERVER\INGEST'
        Rip       = 'C:\MOVIESERVER\RIP'
        Work      = 'C:\MOVIESERVER\WORK'
        Streaming = 'C:\MOVIESERVER\STREAMING'
        Logs      = 'C:\MOVIESERVER\LOGS'
        Temp      = 'C:\MOVIESERVER\TEMP'
    }
    Tools = @{
        FfmpegBin  = 'C:\MOVIESERVER\TOOLS\ffmpeg\bin'
        FfmpegExe  = 'C:\MOVIESERVER\TOOLS\ffmpeg\bin\ffmpeg.exe'
        FfprobeExe = 'C:\MOVIESERVER\TOOLS\ffmpeg\bin\ffprobe.exe'
    }
    Caddy = @{
        AccessLogPath = 'C:\MOVIESERVER\LOGS\caddy-access.log'
        ErrorLogPath  = 'C:\MOVIESERVER\LOGS\caddy-error.log'
        BaseUrl       = 'http://movieserver.local'
    }
    RipWatcher = @{
        DiscTitleMaxAttempts   = 3
        DiscRetryDelaySeconds  = 8
    }
}
```

---

## 6. Rete e porte

| Porta | Processo | Note |
|---|---|---|
| 80 | Caddy | Serve file statici da `STREAMING\` e proxy `/api/*` |
| 9095 | admin-api.ps1 | HTTP listener, prefisso `http://localhost:9095/` |

Caddy ha `header_up Host localhost:9095` nel block `/api/*` per sovrascrivere l'header Host prima del reverse proxy (HTTP.sys PS 5.1 rifiuta host diversi da `localhost`).

Il DNS `movieserver.local` deve puntare all'IP del server (impostato dal router o nel file `hosts`).

---

## 7. Admin API — endpoint

Tutti gli endpoint richiedono `Authorization: Bearer <token>` tranne `/api/auth`.

| Metodo | Path | Descrizione |
|---|---|---|
| POST | `/api/auth` | Body: `{"pin":"..."}` → risponde `{"token":"..."}` |
| GET | `/api/processes` | Lista processi attivi pipeline (powershell, ffmpeg, caddy, makemkvcon) |
| POST | `/api/processes/kill` | Body: `{"pid":1234}` → termina processo |
| GET | `/api/queue` | Lista job dalla coda rip-jobs.json |
| DELETE | `/api/queue/{id}` | Rimuove un job dalla coda |
| GET | `/api/catalog` | Lista film da catalog.json |
| DELETE | `/api/catalog/{id}` | Elimina film dal catalogo + cartella HLS |

---

## 8. HLS encoding — profili

| Profilo | Risoluzione | Video bitrate | Audio |
|---|---|---|---|
| 4k | 3840×2160 | 12000k | 192k AAC stereo |
| 1080p | 1920×1080 | 6000k | 160k AAC stereo |
| 720p | 1280×720 | 3000k | 128k AAC stereo |
| 480p | 854×480 | 1200k | 96k AAC stereo |

Benchmark hardware: testa `nvenc` → `qsv` → `libx264` in quest'ordine. Usa il primo disponibile.

Audio probe: due passate ffprobe (`default` + `-probesize 100M -analyzeduration 100M`) per trovare tracce audio nei file MKV di MakeMKV.

---

## 9. Admin API — crash fix (commit e759ccc)

Con `$ErrorActionPreference = 'Stop'` qualsiasi eccezione non gestita in un handler di route
(es. `HttpListenerException` su client disconnect, errore in `ripFileSizeBytes`) propagava fuori
dal `while` loop nel blocco `finally`, fermando l'HttpListener.

**Fix:** ogni richiesta autenticata è avvolta in un `try/catch` interno che cattura tutto,
loga l'errore, risponde HTTP 500, e non interrompe il loop. Il listener rimane sempre attivo.

---

## 10. Problemi noti / gotcha importanti

### PowerShell 5.1 — limitazioni critiche
- **NON usare** `System.Diagnostics.Process.OutputDataReceived` / `ErrorDataReceived` eventi → crash silenzioso con `$ErrorActionPreference = 'Stop'`
- **NON usare** pipeline `| ForEach-Object` per output di processi esterni → stessa causa
- **Forma sicura per invocare programmi esterni e catturarne output**: `$output = @(& $exe @args 2>&1)`
- **NON usare** `try { expr(a, b) } catch {}` inside hashtable literals → il parser confonde la virgola come separatore di coppia chiave/valore. Assegna sempre prima a una variabile.

### HTTP.sys Host matching
- `http://localhost:9095/` come prefisso accetta SOLO richieste con `Host: localhost:9095`
- Caddy in reverse proxy passa `Host: movieserver.local` per default → 400 Bad Request
- Fix già applicato: `header_up Host localhost:9095` nel Caddyfile
- **NON usare** `http://+:9095/` → richiede privilegi Administrator / netsh urlacl → crash

### MakeMKV
- MakeMKV deve essere installato separatamente: **non è incluso nel repo**
- Percorso atteso: `C:\Program Files (x86)\MakeMKV\makemkvcon64.exe`
- Per trovare il percorso effettivo: `rip-watcher\src\MakeMkv.psm1` funzione `Get-MakeMkvConPath`
- Comando di rip: `makemkvcon --robot --decrypt mkv disc:<index> <titleId> <outputDir>`

### Git LFS
- I binari ffmpeg/caddy/exe sono in Git LFS, NON nel git normale
- Dopo `git clone` serve `git lfs pull` se LFS non è installato sul sistema
- La cartella `TOOLS\ffmpeg\bin\ffmpeg-8.1-full_build\` è esclusa dal git (duplicato del parent)

### Stale jobs
- Se la pipeline viene killata mentre un job è in status `ripping`, al prossimo avvio `rip-worker.ps1` lo resetta a `queued` automaticamente
- Il reset avviene SOLO all'avvio dello script, NON in ogni ciclo

---

## 11. Come avviare (da zero su un nuovo PC)

```powershell
# 1. Installare Git + Git LFS
winget install Git.Git
winget install GitHub.GitLFS
git lfs install

# 2. Clonare il repo
git clone https://github.com/omocatodico/MOVIESERVER.git C:\MOVIESERVER
cd C:\MOVIESERVER
git lfs pull   # scarica i binari pesanti

# 3. Installare MakeMKV (separatamente, da makemkv.com)

# 4. Impostare DNS movieserver.local nel router o in C:\Windows\System32\drivers\etc\hosts
#    192.168.x.x  movieserver.local

# 5a. Avvio manuale (doppio click o PowerShell)
double-click C:\MOVIESERVER\APP\start-all-admin.exe
# oppure:
powershell -NoProfile -File C:\MOVIESERVER\APP\run-all.ps1

# 5b. Avvio come servizio Windows (auto-start al boot) — vedi sezione 12
powershell -ExecutionPolicy Bypass -File C:\MOVIESERVER\APP\service.ps1 install
```

---

## 12. Servizio Windows (avvio automatico)

Il servizio si chiama **GuardaTambosi** e avvolge `run-all.ps1` / `stop-all.ps1` tramite
`APP\tools\MovieServerService.cs` (C# `ServiceBase`). La gestione avviene tramite `APP\service.ps1`.

### Comandi
```powershell
# Dalla cartella APP (auto-elevazione UAC automatica):
powershell -ExecutionPolicy Bypass -File service.ps1 install    # compila, installa e avvia
powershell -ExecutionPolicy Bypass -File service.ps1 uninstall  # ferma e rimuove
powershell -ExecutionPolicy Bypass -File service.ps1 start      # avvia servizio esistente
powershell -ExecutionPolicy Bypass -File service.ps1 stop       # ferma servizio
powershell -ExecutionPolicy Bypass -File service.ps1 status     # stato corrente
powershell -ExecutionPolicy Bypass -File service.ps1 compile    # solo ri-compilazione exe
```

### Dettagli tecnici
- **`install`** compila automaticamente l'exe se mancante o se `MovieServerService.cs` è più recente
- **`OnStart`** lancia `powershell.exe -NonInteractive -File run-all.ps1` come processo figlio
- **`OnStop`** esegue `stop-all.ps1` (attende max 30s), poi termina il processo principale
- **StartupType**: `Automatic` — si avvia con Windows senza login utente
- **L'exe `movieserver-service.exe`** è escluso da git (regola `APP\*.exe` in `.gitignore`)
  e viene rigenerato da `service.ps1 install` o `service.ps1 compile`
- **coesistenza**: il servizio e i launcher `start-all-admin.exe`/`stop-all-admin.exe` sono
  indipendenti — non installarli entrambi attivi contemporaneamente (doppio avvio della pipeline)

### Gotcha servizio
- Se Caddy è già in esecuzione (sessione elevata precedente), `run-all.ps1` fallirà con
  "Caddy si è chiuso subito dopo l'avvio" — terminare il processo Caddy manualmente prima
  dell'installazione del servizio
- Il servizio gira come **LocalSystem** (privilegiato) — accede a tutte le risorse locali

---

## 13. Cosa manca / TODO noti

- [ ] **MakeMKV non incluso**: il repo non ha il binario `makemkvcon64.exe`. Deve essere installato separatamente. Considerare documentarlo meglio o aggiungere un controllo pre-avvio esplicito.
- [ ] **DNS movieserver.local**: non configurato automaticamente. Su una nuova installazione bisogna aggiungerlo a mano nel router o nel file `hosts`.
- [ ] **build-admin-launcher.ps1**: nel workspace originale c'è `build-admin-launcher.ps1` ma non `build-start-all-launcher.ps1` — i nomi sono leggermente inconsistenti rispetto all'EXE prodotto. Verificare.
- [ ] **APP\apps\admin-api\admin-api.ps1**: esiste una copia in `apps\admin-api\` oltre a `APP\admin-api.ps1`. Da verificare se è un doppione obsoleto o serve a qualcosa.
- [ ] **STREAMING\catalog.json**: presente nel repo ma escluso dal gitignore — possibile conflitto se viene aggiornato dalla pipeline e poi si fa push.
- [ ] **Subtitoli**: `manifest.json` dice `subtitlePreference: ["ita","eng","all"]` ma non c'è codice che gestisce i sottotitoli. Feature non ancora implementata.
- [ ] **Series/episodi**: `manifest.json` definisce naming per serie TV (`S01E01`) ma la pipeline attuale gestisce solo film singoli.
- [ ] **Notifiche / monitoring**: nessun sistema di alert se la pipeline si ferma o un job rimane bloccato a lungo.
- [ ] **HTTPS**: Caddy attualmente usa `auto_https off`. Certificato TLS configurato tramite variabili `LEGO_CERT_FILE`/`LEGO_KEY_FILE` in `run-all.ps1` — verificare che il percorso `CONFIG\lego\certificates\` sia presente su nuove installazioni.
- [ ] **Coesistenza servizio+launcher**: no guardia che impedisca di avviare `start-all-admin.exe` mentre il servizio Windows è già in esecuzione (doppio avvio della pipeline).

---

## 14. File chiave da leggere per capire il codice

| File | Perché leggerlo |
|---|---|
| `APP\run-all.ps1` | Entry point — capisce come si avvia tutto |
| `APP\admin-api.ps1` | API REST completa — tutti gli endpoint |
| `APP\apps\rip-watcher\rip-worker.ps1` | Logica di rip MakeMKV |
| `APP\apps\rip-watcher\src\MakeMkv.psm1` | Wrapper MakeMKV — parsing output `--robot` |
| `APP\apps\hls-encoder\hls-encoder.ps1` | Logica encoding con benchmark HW |
| `APP\apps\hls-encoder\src\FfTools.psm1` | Costruzione argomenti ffmpeg, probe audio |
| `APP\apps\hls-encoder\src\Profiles.psm1` | Definizione profili HLS (bitrate, risoluzioni) |
| `APP\apps\tmdb-matcher\src\TmdbApi.psm1` | Client TMDB API |
| `CONFIG\Caddyfile` | Config server web + reverse proxy |
| `WORK\queues\rip-jobs.json` | Stato corrente della coda (runtime) |
| `APP\service.ps1` | Gestione servizio Windows (install/uninstall/compile) |
| `APP\tools\MovieServerService.cs` | Wrapper C# ServiceBase del servizio Windows |
