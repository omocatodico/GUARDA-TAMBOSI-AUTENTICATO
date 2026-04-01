[CmdletBinding()]
param(
    [string]$ServerRoot = '',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-JobProp {
    param([pscustomobject]$Job, [string]$Name, $Value)
    $Job | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($ServerRoot)) {
    $ServerRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptRoot))
}
Import-Module (Join-Path $scriptRoot 'src\Config.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Logger.psm1') -Force
Import-Module (Join-Path $scriptRoot 'src\Queue.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $scriptRoot 'src\MakeMkv.psm1') -Force -DisableNameChecking

$config = Get-RipWatcherConfig -ServerRoot $ServerRoot
Initialize-RipWatcherStorage -Config $config

$discTitleMaxAttempts = [int]$config.RipWatcher.DiscTitleMaxAttempts
$discRetryDelaySeconds = [int]$config.RipWatcher.DiscRetryDelaySeconds

Write-RipWatcherLog -Config $config -Level Info -Message 'rip-worker started' -Data @{ dryRun = [bool]$DryRun; discTitleMaxAttempts = $discTitleMaxAttempts; discRetryDelaySeconds = $discRetryDelaySeconds }

$makemkvcon = Find-MakeMkvCon -HintDir $config.Tools.MakeMkvDir
if ($null -eq $makemkvcon) {
    Write-RipWatcherLog -Config $config -Level Warning -Message 'makemkvcon not found - optical-disc jobs will be skipped' -Data @{}
}
else {
    Write-RipWatcherLog -Config $config -Level Info -Message 'makemkvcon found' -Data @{ path = $makemkvcon }
}

$queue = Get-RipQueue -Config $config

# Reset any jobs stuck at 'ripping' back to 'queued' — they were in-flight when the worker last crashed/was stopped
$stuckRipping = @($queue | Where-Object { $_.status -eq 'ripping' -and $_.sourceType -eq 'optical-disc' })
if ($stuckRipping.Count -gt 0) {
    foreach ($stuckJob in $stuckRipping) {
        Write-RipWatcherLog -Config $config -Level Warning -Message 'resetting stale ripping job to queued' -Data @{ id = $stuckJob.id; displayName = $stuckJob.displayName }
    }
    foreach ($q in $queue) {
        if ($q.status -eq 'ripping' -and $q.sourceType -eq 'optical-disc') {
            Set-JobProp $q 'status' 'queued'
            Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
            $props = $q.PSObject.Properties
            if ($null -ne $props['error'])       { $q.PSObject.Properties.Remove('error') }
            if ($null -ne $props['ripPercent'])  { $q.PSObject.Properties.Remove('ripPercent') }
            if ($null -ne $props['ripDetail'])   { $q.PSObject.Properties.Remove('ripDetail') }
        }
    }
    Save-RipQueue -Config $config -Queue $queue
}

$pending = @($queue | Where-Object { $_.status -eq 'queued' })

# Delete source files for any already-encoded ingest jobs (catches leftovers from past runs)
foreach ($doneJob in @($queue | Where-Object { $_.status -eq 'encoded' -and $_.sourceType -eq 'ingest-file' })) {
    if ($null -ne $doneJob.sourcePath -and (Test-Path -LiteralPath $doneJob.sourcePath)) {
        try {
            Remove-Item -LiteralPath $doneJob.sourcePath -Force
            Write-RipWatcherLog -Config $config -Level Info -Message 'deleted encoded ingest source' -Data @{ id = $doneJob.id; displayName = $doneJob.displayName; sourcePath = $doneJob.sourcePath }
        } catch {
            Write-RipWatcherLog -Config $config -Level Warning -Message 'failed to delete ingest source' -Data @{ id = $doneJob.id; displayName = $doneJob.displayName; sourcePath = $doneJob.sourcePath; error = $_.Exception.Message }
        }
    }
}

# Remove orphaned ingest-file jobs whose source no longer exists and are not fully encoded
$activeStatuses = @('queued','error','pending','matching','matched','ready-for-matching')
$pruned = @($queue | Where-Object {
    $isOrphaned = $_.sourceType -eq 'ingest-file' `
        -and ($activeStatuses -contains $_.status) `
        -and ($null -ne $_.sourcePath) `
        -and (-not (Test-Path -LiteralPath $_.sourcePath))
    if ($isOrphaned) {
        Write-RipWatcherLog -Config $config -Level Warning -Message 'removing orphaned ingest job (source file missing)' -Data @{ id = $_.id; displayName = $_.displayName; sourcePath = $_.sourcePath }
    }
    -not $isOrphaned
})
if ($pruned.Count -lt $queue.Count) {
    Save-RipQueue -Config $config -Queue $pruned
    $queue = $pruned
    $pending = @($queue | Where-Object { $_.status -eq 'queued' })
}

if ($pending.Count -eq 0) {
    Write-RipWatcherLog -Config $config -Level Info -Message 'no queued jobs found' -Data @{}
    exit 0
}

Write-RipWatcherLog -Config $config -Level Info -Message 'processing pending jobs' -Data @{ count = $pending.Count }

foreach ($job in $pending) {
    $logData = @{ id = $job.id; sourceType = $job.sourceType; displayName = $job.displayName }

    try {
        if ($job.sourceType -eq 'optical-disc') {
            $queue = Get-RipQueue -Config $config
            foreach ($q in $queue) {
                if ($q.id -eq $job.id) {
                    Set-JobProp $q 'status' 'ripping'
                    Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
                }
            }
            Save-RipQueue -Config $config -Queue $queue
            Write-RipWatcherLog -Config $config -Level Info -Message 'job status updated' -Data ($logData + @{ status = 'ripping' })
        }

        if ($job.sourceType -eq 'ingest-file') {
            Write-RipWatcherLog -Config $config -Level Info -Message 'ingest-file ready for matching' -Data $logData

            $queue = Get-RipQueue -Config $config
            foreach ($q in $queue) {
                if ($q.id -eq $job.id) {
                    Set-JobProp $q 'status' 'ready-for-matching'
                    Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
                }
            }
            Save-RipQueue -Config $config -Queue $queue
            continue
        }

        if ($job.sourceType -eq 'optical-disc') {
            if ($null -eq $makemkvcon) {
                Write-RipWatcherLog -Config $config -Level Warning -Message 'skipping optical-disc job: makemkvcon not found' -Data $logData
                continue
            }

            $driveLetter = [string]$job.details.driveLetter
            Write-RipWatcherLog -Config $config -Level Info -Message 'querying disc info' -Data ($logData + @{ driveLetter = $driveLetter })

            $titles = @()
            for ($attempt = 1; $attempt -le $discTitleMaxAttempts; $attempt++) {
                $titles = @(Get-DiscTitles -MakeMkvConPath $makemkvcon -DriveLetter $driveLetter)
                if ($titles.Count -gt 0) {
                    if ($attempt -gt 1) {
                        Write-RipWatcherLog -Config $config -Level Info -Message 'disc titles detected after retry' -Data ($logData + @{ driveLetter = $driveLetter; attempt = $attempt; titleCount = $titles.Count; progress = "disc info ready (attempt $attempt/$discTitleMaxAttempts)" })
                    }
                    break
                }

                if ($attempt -lt $discTitleMaxAttempts) {
                    $progressText = "disc info retry $attempt/$discTitleMaxAttempts"
                    Write-RipWatcherLog -Config $config -Level Warning -Message 'no titles detected yet, retrying' -Data ($logData + @{ driveLetter = $driveLetter; attempt = $attempt; maxAttempts = $discTitleMaxAttempts; retryInSeconds = $discRetryDelaySeconds; status = 'ripping'; progress = $progressText })

                    $queueNow = Get-RipQueue -Config $config
                    foreach ($q in $queueNow) {
                        if ($q.id -eq $job.id) {
                            Set-JobProp $q 'status' 'ripping'
                            Set-JobProp $q 'ripDetail' $progressText
                            Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
                        }
                    }
                    Save-RipQueue -Config $config -Queue $queueNow

                    Start-Sleep -Seconds $discRetryDelaySeconds
                }
            }

            $mainTitle = Select-MainTitle -Titles $titles

            if ($null -eq $mainTitle) {
                $hint = 'No title detected. Verifica che il disco sia leggibile in MakeMKV GUI, attendi 10-20s dopo inserimento, poi riprova. Se persiste: possibile protezione/struttura non supportata o drive occupato.'
                Write-RipWatcherLog -Config $config -Level Warning -Message 'no titles found on disc' -Data ($logData + @{ driveLetter = $driveLetter; titleCount = $titles.Count; hint = $hint; status = 'error' })

                $queue = Get-RipQueue -Config $config
                foreach ($q in $queue) {
                    if ($q.id -eq $job.id) {
                        Set-JobProp $q 'status' 'error'
                        Set-JobProp $q 'error' 'no titles found on disc; possible unsupported/protected disc, drive busy, or not fully initialized'
                        Set-JobProp $q 'errorHint' $hint
                        Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
                    }
                }
                Save-RipQueue -Config $config -Queue $queue
                continue
            }

            $titleData = @{ titleId = $mainTitle.Id; duration = $mainTitle.DurationString; name = $mainTitle.Name }
            Write-RipWatcherLog -Config $config -Level Info -Message 'main title selected' -Data ($logData + $titleData)

            $safeDisplayName = ($job.displayName -replace '[\\/:*?"<>|]', '_')
            $outputDir = Join-Path $config.Paths.Rip $safeDisplayName

            if ($DryRun) {
                Write-RipWatcherLog -Config $config -Level Info -Message '[DryRun] would rip title' -Data ($logData + $titleData + @{ outputDir = $outputDir })
            }
            else {
                Write-RipWatcherLog -Config $config -Level Info -Message 'starting rip' -Data ($logData + $titleData + @{ outputDir = $outputDir })

                $lastProgressPercent = -1
                $lastProgressDetail = ''
                $lastProgressUpdateAt = Get-Date '2000-01-01'

                Write-RipWatcherLog -Config $config -Level Info -Message 'invoking makemkvcon' -Data ($logData + @{ titleId = $mainTitle.Id; outputDir = $outputDir })
                $ripResult = Invoke-DiscRip -MakeMkvConPath $makemkvcon -DriveLetter $driveLetter -TitleId $mainTitle.Id -OutputDir $outputDir -OnProgress {
                    param($progress)

                    $now = Get-Date
                    $percent = if ($null -ne $progress.Percent) { [int]$progress.Percent } else { $null }
                    $detail = if ($null -ne $progress.Detail) { [string]$progress.Detail } else { '' }

                    $percentChanged = ($null -ne $percent) -and ($percent -ge 0) -and ($percent -ne $lastProgressPercent)
                    $detailChanged = (-not [string]::IsNullOrWhiteSpace($detail)) -and ($detail -ne $lastProgressDetail)
                    $timeElapsed = (($now - $lastProgressUpdateAt).TotalSeconds -ge 2)
                    $stepReached = ($null -ne $percent) -and (($lastProgressPercent -lt 0) -or ($percent -ge ($lastProgressPercent + 2)) -or ($percent -eq 100))

                    if ((-not $timeElapsed) -and (-not $stepReached) -and (-not $detailChanged)) {
                        return
                    }

                    $progressText = if ($null -ne $percent) { "rip $percent%" } else { 'rip in progress' }
                    if (-not [string]::IsNullOrWhiteSpace($detail)) {
                        $progressText = "$progressText - $detail"
                    }

                    $queueNow = Get-RipQueue -Config $config
                    foreach ($q in $queueNow) {
                        if ($q.id -eq $job.id) {
                            Set-JobProp $q 'status' 'ripping'
                            if ($null -ne $percent) {
                                Set-JobProp $q 'ripPercent' $percent
                            }
                            if (-not [string]::IsNullOrWhiteSpace($detail)) {
                                Set-JobProp $q 'ripDetail' $detail
                            }
                            Set-JobProp $q 'updatedAt' $now.ToString('s')
                        }
                    }
                    Save-RipQueue -Config $config -Queue $queueNow

                    Write-RipWatcherLog -Config $config -Level Info -Message 'rip progress' -Data ($logData + @{ status = 'ripping'; progress = $progressText; percent = $percent; detail = $detail })

                    if ($null -ne $percent -and $percent -ge 0) {
                        $lastProgressPercent = $percent
                    }
                    if (-not [string]::IsNullOrWhiteSpace($detail)) {
                        $lastProgressDetail = $detail
                    }
                    $lastProgressUpdateAt = $now
                }

                $exitCode = [int]$ripResult.ExitCode
                Write-RipWatcherLog -Config $config -Level Info -Message 'makemkvcon returned' -Data ($logData + @{ exitCode = $exitCode; outputLines = $ripResult.Output.Count })

                if ($exitCode -ne 0) {
                    $ripSummary = ($ripResult.Output | Where-Object { $_ -match '^MSG:' } | Select-Object -Last 5) -join ' | '
                    Write-RipWatcherLog -Config $config -Level Error -Message 'rip failed' -Data ($logData + @{ exitCode = $exitCode; lastOutput = $ripSummary })
                    $queue = Get-RipQueue -Config $config
                    foreach ($q in $queue) {
                        if ($q.id -eq $job.id) {
                            Set-JobProp $q 'status' 'error'
                            Set-JobProp $q 'error' "makemkvcon exited with code $exitCode"
                            Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
                        }
                    }
                    Save-RipQueue -Config $config -Queue $queue
                    continue
                }

                Write-RipWatcherLog -Config $config -Level Info -Message 'rip complete - ejecting disc' -Data ($logData + @{ outputDir = $outputDir })
                Eject-OpticalDrive -DriveLetter $driveLetter
            }

            $queue = Get-RipQueue -Config $config
            foreach ($q in $queue) {
                if ($q.id -eq $job.id) {
                    Set-JobProp $q 'status' 'ready-for-matching'
                    Set-JobProp $q 'ripOutputDir' $outputDir
                    Set-JobProp $q 'ripTitleId' $mainTitle.Id
                    Set-JobProp $q 'ripDuration' $mainTitle.DurationString
                    Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
                }
            }
            Save-RipQueue -Config $config -Queue $queue

            Write-RipWatcherLog -Config $config -Level Info -Message 'job advanced to ready-for-matching' -Data $logData
            continue
        }

        Write-RipWatcherLog -Config $config -Level Warning -Message 'unknown sourceType - skipping' -Data $logData
    }
    catch {
        Write-RipWatcherLog -Config $config -Level Error -Message 'unhandled error processing job' -Data ($logData + @{ error = $_.Exception.Message })
        $queue = Get-RipQueue -Config $config
        foreach ($q in $queue) {
            if ($q.id -eq $job.id) {
                Set-JobProp $q 'status' 'error'
                Set-JobProp $q 'error' $_.Exception.Message
                Set-JobProp $q 'updatedAt' (Get-Date).ToString('s')
            }
        }
        Save-RipQueue -Config $config -Queue $queue
    }
}

Write-RipWatcherLog -Config $config -Level Info -Message 'rip-worker finished' -Data @{}
exit 0
