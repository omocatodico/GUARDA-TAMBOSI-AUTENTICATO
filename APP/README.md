# MOVIESERVER — APP

Orchestrator pipeline + Admin API per MOVIESERVER.

## Avvio completo

Doppio click su `start-all-admin.exe` (richiede UAC). Avvia:
- Pipeline di ripping/encoding in loop
- Caddy (porta 80)
- Admin API (porta 9091)

Oppure da terminale:

```powershell
powershell -NoProfile -File .\run-all.ps1
```

Opzioni:

```powershell
.\run-all.ps1 -SingleCycle        # un solo ciclo (debug)
.\run-all.ps1 -NoCaddy            # senza avviare Caddy
.\run-all.ps1 -TickSeconds 30     # ciclo ogni 30s
```

## Stop

```powershell
powershell -NoProfile -File .\stop-all.ps1
```

Oppure doppio click su `stop-all-admin.exe`.

## Struttura

- `run-all.ps1`: orchestratore pipeline + Caddy + Admin API
- `admin-api.ps1`: server HTTP REST su porta 9091 (pannello admin)
- `stop-all.ps1`: ferma processi pipeline e Caddy
- `apps\rip-watcher\`: rileva dischi ottici e file INGEST
- `apps\tmdb-matcher\`: abbina film a TMDB
- `apps\hls-encoder\`: encoding HLS con ffmpeg
- `apps\catalog-publisher\`: genera catalog.json e index.html
- `logs\*.log`: log raw (JSON lines) per servizio

## MOVIESERVER Root

Runtime root reale:

```powershell
C:\MOVIESERVER
```

Cartelle base create:

- `C:\MOVIESERVER\INGEST`
- `C:\MOVIESERVER\RIP`
- `C:\MOVIESERVER\WORK`
- `C:\MOVIESERVER\STREAMING`
- `C:\MOVIESERVER\CONFIG`
- `C:\MOVIESERVER\LOGS`
- `C:\MOVIESERVER\TEMP`

Config locale da completare:

```powershell
C:\MOVIESERVER\CONFIG\local.psd1
```

## Rip Watcher

Avvio singola scansione:

```powershell
powershell -NoProfile -File .\apps\rip-watcher\rip-watcher.ps1 -RunOnce
```

Avvio continuo:

```powershell
powershell -NoProfile -File .\apps\rip-watcher\rip-watcher.ps1
```

Funzioni gia presenti:

- scan file video in `INGEST`
- scan drive ottici `DriveType = 5`
- coda persistente in `C:\MOVIESERVER\WORK\queues\rip-jobs.json`
- log strutturato in `C:\MOVIESERVER\LOGS\rip-watcher.log`
- deduplica su fingerprint sorgente

## Prossimi step

- gestire resize dinamico terminale con layout piu robusto
- aggiungere stato servizio (running/stopped/error)
- instradare input tastiera per pannello attivo
- sostituire servizi demo con processi reali

## Config servizi (base)

Ogni servizio in `config\Services.psd1` supporta:

- `Type = 'Script'` con `Script` e `IntervalMs`
- `Type = 'Command'` con `Command` e `Arguments`
