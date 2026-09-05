# ---------------------------------------------------------------------------
# Phase: WinUtil
#
# Chris Titus' winutil accepts -Config with a local path OR an https URL. When
# given one it imports the selections, calls Invoke-WinUtilAutoRun, and exits.
# No GUI, no interaction. Verified against winutil v26.08.19.
#
# Two things that version does NOT do, which is why the next phase exists:
#   * Invoke-WinUtilAutoRun processes Tweaks / Features / Apps / AppX only.
#     Any WPFToggle* key in a config is imported and then silently ignored.
#   * The Fixes panel entries (AutoLogon, System Corruption Scan, CTT PowerShell
#     Profile) are Buttons, not checkboxes. Update-WinUtilSelections throws
#     "Unsupported selection key" if one appears in a config.
# ---------------------------------------------------------------------------

$script:WinUtilSource = 'https://christitus.com/win'

<#
.SYNOPSIS
    Read a winutil selection config from a URL or a local path.

.DESCRIPTION
    winutil itself accepts either, so the preflight check has to as well -
    otherwise running from a cloned repo with a local config fails validation
    for a config winutil would have loaded happily.
#>
function Read-WinUtilConfig {
    param([Parameter(Mandatory)][string]$Source)

    if ($Source -match '^https?://') {
        return (Invoke-RestMethod -Uri $Source -UseBasicParsing -ErrorAction Stop)
    }
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "no such file: $Source"
    }
    return (Get-Content -Raw -LiteralPath $Source | ConvertFrom-Json)
}

function Invoke-WinUtilPhase {
    param([Parameter(Mandatory)][string]$ConfigUrl)

    Write-Phase 'WinUtil tweaks'

    # Fail fast on an unreachable config rather than letting winutil launch its
    # GUI, which is what happens when the import silently produces no selections.
    try {
        $selections = Read-WinUtilConfig -Source $ConfigUrl
        if (-not $selections -or @($selections).Count -eq 0) { throw 'config is empty' }
        Write-Log "Config resolved: $(@($selections).Count) selection(s) from $ConfigUrl"
    } catch {
        Write-Log -Level FAIL -Message "WinUtil config unreadable ($ConfigUrl): $($_.Exception.Message)"
        Write-Log -Level FAIL -Message 'Skipping the WinUtil phase. Everything else still runs.'
        return
    }

    $bad = @($selections | Where-Object { $_ -notmatch '^WPF(Install|Tweaks|Toggle|Feature|Appx)' })
    if ($bad.Count -gt 0) {
        Write-Log -Level FAIL -Message "Config contains keys winutil will reject: $($bad -join ', ')"
        Write-Log -Level FAIL -Message 'Remove them from config/winutil-tweaks.json. Skipping this phase.'
        return
    }

    $toggles = @($selections | Where-Object { $_ -match '^WPFToggle' })
    if ($toggles.Count -gt 0) {
        Write-Log -Level WARN -Message "Config contains $($toggles.Count) toggle(s). WinUtil ignores toggles in headless mode; this script sets them directly instead."
    }

    # Some selections only mean anything on Windows 11, and one of them is
    # actively misleading on Windows 10: "restore the previous right-click menu"
    # offers to give a Windows 10 user the menu they already have. Dropped here
    # rather than at apply time so they never appear in the plan either.
    $winOnly = @{
        'WPFTweaksRightClickMenu'   = @{ Min = 22000; Why = 'Windows 10 already has the classic context menu' }
        'WPFTweaksWindowsAI'        = @{ Min = 22000; Why = 'Windows AI and Recall do not exist on Windows 10' }
        'WPFTweaksEndTaskOnTaskbar' = @{ Min = 22631; Why = 'End Task on the taskbar arrived in Windows 11 23H2' }
    }
    $build = if ($script:MachineFacts) { [int]$script:MachineFacts.OSBuild } else { 0 }
    if ($build -gt 0) {
        $dropped = @($selections | Where-Object { $winOnly.ContainsKey($_) -and $build -lt $winOnly[$_].Min })
        foreach ($d in $dropped) {
            Write-Log -Level INFO -Message "skipped winutil:$d - $($winOnly[$d].Why) (build $build)"
        }
        if ($dropped.Count -gt 0) {
            $selections = @($selections | Where-Object { $dropped -notcontains $_ })
        }
    }

    foreach ($s in $selections) {
        # Service changes and browser debloat are the two winutil selections
        # someone might reasonably want left alone.
        $t = if ($s -match 'Services|EdgeDebloat|BraveDebloat') { 'op' } else { 'safe' }
        Add-PlannedAction -Kind 'external' -Target "winutil:$s" `
            -Detail 'applied by ChrisTitusTech/winutil' -Reversible 'restore point only' -Tier $t
    }

    # Drop anything the user unticked, then hand winutil a config of what is
    # left rather than the one on disk.
    $selections = @($selections | Where-Object { Test-SelectedChange "act|external|winutil:$_" })
    if (@($selections).Count -eq 0) {
        Write-Log 'No winutil selections remain after filtering. Skipping this phase.'
        return
    }

    if ($DryRun) {
        Write-Log -Level DRY -Message "would run: winutil -Config '$ConfigUrl'"
        foreach ($s in $selections) { Write-Log -Level DRY -Message "  $s" }
        return
    }

    if ($null -ne $script:SelectionFilter) {
        $tmp = Join-Path $script:RunRoot "winutil-selection_$($script:RunStamp).json"
        @($selections) | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        Write-Log "Filtered winutil config: $tmp ($(@($selections).Count) of the original)"
        $ConfigUrl = $tmp
    }

    Write-Log 'Handing off to winutil. This takes several minutes and is noisy.'
    try {
        $block = [ScriptBlock]::Create((Invoke-RestMethod -Uri $script:WinUtilSource -UseBasicParsing))

        # This script runs under Set-StrictMode -Version 2.0, and anything it
        # invokes inherits that. WinUtil is not written for it: it reads
        # $sync.runspace on a hashtable that does not always have the key,
        # which is $null normally and a terminating error under strict mode.
        # The phase died on its first statement with
        #   The property 'runspace' cannot be found on this object.
        # every time it ran, so the tweak set never actually applied.
        #
        # Strict mode is scoped to here and downwards, so turning it off for
        # the handoff leaves the rest of the script under it.
        Set-StrictMode -Off
        try     { & $block -Config $ConfigUrl }
        finally { Set-StrictMode -Version 2.0 }

        Write-Log -Level OK -Message 'WinUtil phase complete.'
    } catch {
        Write-Log -Level FAIL -Message "WinUtil failed: $($_.Exception.Message)"
    }

    Write-Log -Level WARN -Message 'WinUtil changes are NOT covered by this run''s undo script. Use its own restore point or the one made at the start of this run.'
}
