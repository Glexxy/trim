# ---------------------------------------------------------------------------
# Main
#
# Three ways in, one code path:
#
#   -DryRun            run every phase, change nothing, emit the manifest
#   -Gui               dry run, show the manifest, apply what survives
#   (neither)          run every phase for real
#
# The window never applies anything itself. It edits a selection, and the same
# phase code applies it - filtered. That is why what you saw is what you get:
# there is no second implementation to drift.
# ---------------------------------------------------------------------------

function Invoke-AllPhases {
    param([Parameter(Mandatory)]$Facts)

    if (Test-PhaseEnabled 'WinUtil')         { Invoke-WinUtilPhase -ConfigUrl $WinUtilConfigUrl }
    if (Test-PhaseEnabled 'Fixes')           { Invoke-FixesPhase }
    if (Test-PhaseEnabled 'Performance')     { Invoke-PerformancePhase -Facts $Facts }
    if (Test-PhaseEnabled 'Gaming')          { Invoke-GamingPhase -Facts $Facts }
    if (Test-PhaseEnabled 'Graphics')        { Invoke-GpuPhase -Facts $Facts -ProfileOverride $NvidiaProfile }
    if (Test-PhaseEnabled 'Privacy')         { Invoke-PrivacyPhase }
    if (Test-PhaseEnabled 'Background')      { Invoke-BackgroundPhase }
    if (Test-PhaseEnabled 'Appx')            { Invoke-AppxPhase }
    if (Test-PhaseEnabled 'Network')         { Invoke-NetworkPhase -Facts $Facts }
    if (Test-PhaseEnabled 'Security')        { Invoke-SecurityPhase -Facts $Facts -DisableMemoryIntegrity:$DisableMemoryIntegrity }
    if (Test-PhaseEnabled 'Extras')          { Invoke-ExtrasPhase -Facts $Facts }
    # Personalisation last: it restarts Explorer, and doing that mid-run makes
    # every later phase's output land in a window the user is watching redraw.
    if (Test-PhaseEnabled 'Personalisation') { Invoke-PersonalisationPhase }
}

function Show-Summary {
    param([Parameter(Mandatory)]$Facts, [Parameter(Mandatory)][datetime]$Started)

    $elapsed = (Get-Date) - $Started
    Write-Phase 'Summary'

    if ($DryRun) {
        Write-Log -Level DRY -Message 'DRY RUN - nothing was changed.'
        Write-Log "Planned changes : $($script:Ledger.Count)"
    } else {
        Write-Log "Changes applied : $($script:Applied)"
        Write-Log "Already correct : $($script:Skipped)"
    }
    Write-Log "Elapsed         : $([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s"
    Write-Log "Log             : $($script:LogPath)"

    if ($script:Warnings.Count -gt 0) {
        # Write-Host, not Write-Log: Write-Log at WARN level appends to the very
        # list being summarised, so the header counts itself.
        Write-Host ''
        Write-Host "$($script:Warnings.Count) warning(s) during this run:" -ForegroundColor Yellow
        foreach ($w in $script:Warnings) { Write-Host "    - $w" -ForegroundColor Yellow }
    }

}

<#
.SYNOPSIS
    Offer a restart, because a good half of this does not take effect without one.

.DESCRIPTION
    Fast Startup, hardware GPU scheduling, service start types, Memory Integrity
    and the power plan all need a reboot. Someone who applies changes, sees no
    difference and concludes the tool did nothing has been failed by the tool,
    not by Windows.

    In the window a real dialog is used; from the command line a typed answer.
    Either way the default is No - restarting somebody's machine is their call.
#>
function Request-Restart {
    if ($DryRun -or $NoRestartPrompt) { return }
    if ($script:Applied -eq 0) { return }

    $msg = "Trim applied $($script:Applied) change(s)." + [Environment]::NewLine + [Environment]::NewLine +
           'A restart is needed before some of them take effect - Fast Startup, GPU scheduling, ' +
           'service changes and the power plan all apply at boot.' + [Environment]::NewLine + [Environment]::NewLine +
           'Restart now?'

    $wantsRestart = $false
    if ($Gui) {
        try {
            Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
            $answer = [Windows.MessageBox]::Show($msg, 'Trim - restart required', 'YesNo', 'Question', 'No')
            $wantsRestart = ($answer -eq 'Yes')
        } catch {
            Write-Log -Level WARN -Message 'Could not show the restart dialog. Restart when convenient.'
            return
        }
    } else {
        Write-Host ''
        Write-Host $msg -ForegroundColor Cyan
        $answer = Read-Host 'Restart now? [y/N]'
        $wantsRestart = ($answer -match '^(y|yes)$')
    }

    if (-not $wantsRestart) {
        Write-Log 'Not restarting. Some changes take effect at the next boot.'
        return
    }

    Write-Log -Level WARN -Message 'Restarting in 10 seconds. Close anything unsaved. Cancel with: shutdown /a'
    try {
        & (Get-SystemTool 'shutdown.exe') /r /t 10 /c 'Restarting to apply Trim changes.' 2>&1 | Out-Null
    } catch {
        Write-Log -Level FAIL -Message "Could not schedule the restart: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Say out loud that per-user settings only reach the user running the script.

.DESCRIPTION
    Roughly half of what this script changes lives in HKCU. On a shared family
    machine, running it as one account leaves every other account exactly as it
    was - Start menu, taskbar, privacy toggles, GPU preferences, all untouched.
    That is not a bug, but a person handing the machine back believing it is done
    deserves to know.
#>
function Test-SingleUserAssumption {
    $profiles = @()
    try {
        $profiles = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object { -not $_.Special -and $_.LocalPath -and $_.LocalPath -notmatch '\\(systemprofile|ServiceProfiles)' })
    } catch { return }

    if ($profiles.Count -le 1) { return }

    Write-Log -Level WARN -Message "$($profiles.Count) user profiles on this machine. Per-user settings apply ONLY to '$env:USERNAME'."
    Write-Log -Level WARN -Message '  Start menu, taskbar, privacy toggles and GPU preferences are per-user.'
    Write-Log -Level WARN -Message '  Run this again signed in as each account that needs them.'
}

<#
.SYNOPSIS
    Take a selection and either apply it here, or elevate and apply it there.

.DESCRIPTION
    The selection crosses the elevation boundary as a file rather than a command
    line. It can be hundreds of entries, and pushing registry paths through
    Start-Process quoting is a reliable way to corrupt them.
#>
function Invoke-Selection {
    param([Parameter(Mandatory)]$Selection)

    $dir = Join-Path $script:RunRoot 'selection'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir "selection_$($script:RunStamp).json"
    @($Selection | Select-Object Key, Kind, Phase, Title, Tier) |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8

    Write-Log "Selection saved: $file ($(@($Selection).Count) item(s))"

    if ($isAdmin) {
        Set-Variable -Name DryRun -Value $false -Scope Script
        $script:SelectionFilter = @{}
        foreach ($s in $Selection) { $script:SelectionFilter[$s.Key] = $true }
        return $true    # the caller runs the phases
    }

    Write-Log 'Requesting administrator rights to apply...'
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    try {
        if ($PSCommandPath) {
            # -File, so the path is an argument rather than something spliced
            # into a command line that a quote could break out of.
            Start-Process $shell -Verb RunAs -ArgumentList @(
                '-ExecutionPolicy','Bypass','-NoProfile','-File', $PSCommandPath,
                '-ApplySelection', $file, '-Gui'
            )
        } else {
            # Same reasoning as the elevation in 01-header: stage the script to
            # a file and pin it by hash, rather than handing the elevated
            # process a command line that downloads and executes. This is the
            # path the Apply button takes, so it is the one most people hit.
            $self = Get-StagedSelf
            if (-not $self) {
                Write-Log -Level FAIL -Message "Could not stage the script to elevate. To apply by hand: trim.ps1 -ApplySelection '$file'"
                return $false
            }
            Start-Process $shell -Verb RunAs -ArgumentList @(
                '-ExecutionPolicy','Bypass','-NoProfile','-NoExit','-File', $self.Path,
                '-ElevationHash', $self.Hash,
                '-ApplySelection', $file, '-Gui'
            )
        }
        Write-Log -Level OK -Message 'Elevated window launched. This one is finished.'
    } catch {
        Write-Log -Level FAIL -Message "Elevation was declined or failed: $($_.Exception.Message)"
        Write-Log -Level FAIL -Message "Nothing was changed. To apply by hand: trim.ps1 -ApplySelection '$file'"
    }
    return $false
}

function Invoke-Main {
    $started = Get-Date

    # Only set when this script staged itself to a temp file in order to
    # elevate. Between writing that file and Windows starting it as
    # administrator there is a window in which anything that can write to the
    # temp directory could replace it - and it would then run with full rights.
    # Re-hashing the file we were actually launched from closes that window.
    if ($ElevationHash) {
        if (-not $PSCommandPath -or -not (Test-Path -LiteralPath $PSCommandPath)) {
            Write-Host '  Cannot verify this script against the hash it was launched with.' -ForegroundColor Red
            exit 1
        }
        $actual = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        if ($actual -ne $ElevationHash.Trim()) {
            Write-Host '  This script does not match the fingerprint it was elevated with.' -ForegroundColor Red
            Write-Host "    expected $($ElevationHash.Trim())" -ForegroundColor DarkGray
            Write-Host "    actual   $actual" -ForegroundColor DarkGray
            Write-Host '  It was modified after being staged. Refusing to run.' -ForegroundColor Red
            exit 1
        }
    }

    Show-TrimBanner

    # With a window in play the console is not the interface. Everything still
    # goes to the log file.
    if ($Gui -or $ApplySelection) {
        Write-Host '  Launching...' -ForegroundColor DarkGray
        Write-Host ''
        $script:Quiet = $true
    }

    $facts = Get-MachineFacts
    $script:MachineFacts = $facts
    Show-MachineFacts -Facts $facts

    if ($facts.OSBuild -lt 22000) {
        Write-Log -Level WARN -Message 'Windows 10 or older detected. Windows 11-only settings are skipped rather than written where nothing reads them.'
    }
    Test-SingleUserAssumption

    # -------------------------------------------------------------------
    # Disk cleanup. Never part of a preset; always asked for by name.
    # -------------------------------------------------------------------
    # -LargeFiles enters here too. Requiring -Cleanup alongside it would mean
    # `trim.ps1 -LargeFiles` silently did nothing, which is the worst kind of
    # flag.
    if ($Cleanup -or $LargeFiles) {
        Invoke-CleanupPhase -IncludeDuplicates:$IncludeDuplicates -ReportLargeFiles:$LargeFiles
        return
    }

    # -------------------------------------------------------------------
    # Elevated apply of a selection made in an earlier, unelevated window.
    # -------------------------------------------------------------------
    if ($ApplySelection) {
        if (-not (Test-Path -LiteralPath $ApplySelection)) {
            Write-Log -Level FAIL -Message "No selection file at '$ApplySelection'."
            return
        }
        # A malformed selection file should say so, not surface a raw parser
        # stack trace at someone who only pressed Apply.
        try {
            $sel = Get-Content -Raw -LiteralPath $ApplySelection | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Log -Level FAIL -Message "The selection file is not valid JSON: $($_.Exception.Message.Trim())"
            Write-Log -Level FAIL -Message "  File: $ApplySelection"
            Write-Log -Level FAIL -Message '  Nothing was changed. Re-run the window to make a fresh selection.'
            return
        }
        if (-not $sel -or @($sel).Count -eq 0) {
            Write-Log -Level FAIL -Message 'The selection file is empty. Nothing to apply.'
            return
        }

        # This file is read by an elevated process and may have been written by
        # a less privileged one, so it is treated as untrusted input.
        #
        # It is worth being precise about what it can and cannot do. A selection
        # key only ever gates whether a change the phases were already going to
        # make actually happens - it cannot introduce a new one, name a path, or
        # carry a command. So a tampered file can at worst turn our own options
        # on and off. Malformed keys are still rejected rather than trusted.
        $script:SelectionFilter = @{}
        $rejected = 0
        foreach ($s in @($sel)) {
            $k = "$($s.Key)"
            if ($k -notmatch '^(reg|act)\|[^\x00-\x1F]{1,512}$') { $rejected++; continue }
            $script:SelectionFilter[$k] = $true
        }
        if ($rejected -gt 0) {
            Write-Log -Level WARN -Message "$rejected malformed selection key(s) ignored."
        }
        if ($script:SelectionFilter.Count -eq 0) {
            Write-Log -Level FAIL -Message 'No valid selection keys. Nothing to apply.'
            return
        }
        Write-Log "Applying a saved selection: $(@($sel).Count) item(s) from $ApplySelection"

        try {
            if ($Gui -and (Test-CanShowGui)) {
                Invoke-WithProgress -Total (@($sel).Count) -Work {
                    New-SafetyRestorePoint
                    Invoke-AllPhases -Facts $facts
                }
            } else {
                New-SafetyRestorePoint
                Invoke-AllPhases -Facts $facts
            }
        }
        catch { Write-Log -Level FAIL -Message "Run aborted: $($_.Exception.Message)"; Write-Log -Level FAIL -Message $_.ScriptStackTrace }
        finally {
            Write-UndoScript; Write-LedgerJson
            $script:Quiet = $false
            Show-Summary -Facts $facts -Started $started; Request-Restart
        }
        return
    }

    # -------------------------------------------------------------------
    # Window: dry run to build the manifest, then apply what survives it.
    # -------------------------------------------------------------------
    if ($Gui) {
        if (-not (Test-CanShowGui)) { return }

        Set-Variable -Name DryRun -Value $true -Scope Script

        # The window opens first and calls this to fill itself in, so the few
        # seconds of scanning happen in front of the user rather than before
        # anything appears.
        $build = {
            Invoke-AllPhases -Facts $facts
            Write-LedgerJson
            [pscustomobject]@{
                Items          = Get-GuiItems -Ledger $script:Ledger -Actions $script:Actions
                AlreadyCorrect = $script:AlreadySet.Count
            }
        }

        $selection = Show-TrimWindow -Facts $facts -BuildPlan $build
        if (-not $selection) { Write-Log 'Closed without applying. Nothing was changed.'; return }

        # Reset the run state. The dry pass filled it with intentions; the real
        # pass has to start from an empty ledger or the undo script would carry
        # entries for changes that were never made.
        $script:Ledger.Clear(); $script:Actions.Clear(); $script:AlreadySet.Clear()
        $script:Applied = 0; $script:Skipped = 0

        if (-not (Invoke-Selection -Selection $selection)) { return }

        try {
            Invoke-WithProgress -Total (@($selection).Count) -Work {
                New-SafetyRestorePoint
                Invoke-AllPhases -Facts $facts
            }
        }
        catch { Write-Log -Level FAIL -Message "Run aborted: $($_.Exception.Message)"; Write-Log -Level FAIL -Message $_.ScriptStackTrace }
        finally {
            Write-UndoScript; Write-LedgerJson
            $script:Quiet = $false
            Show-Summary -Facts $facts -Started $started; Request-Restart
        }
        return
    }

    # -------------------------------------------------------------------
    # Plain command line.
    # -------------------------------------------------------------------
    if ($DryRun) {
        Write-Log -Level DRY -Message 'DRY RUN. Nothing will be changed. Re-run without -DryRun to apply.'
    }
    New-SafetyRestorePoint

    try {
        Invoke-AllPhases -Facts $facts
    } catch {
        Write-Log -Level FAIL -Message "Run aborted: $($_.Exception.Message)"
        Write-Log -Level FAIL -Message $_.ScriptStackTrace
    } finally {
        # Always emit the undo script, including after a crash - a half-applied
        # run is exactly when you most want to be able to reverse it.
        Write-UndoScript
        Write-LedgerJson
        Show-Summary -Facts $facts -Started $started
        Request-Restart
    }
}

Invoke-Main
