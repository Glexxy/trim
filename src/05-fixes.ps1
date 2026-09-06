# ---------------------------------------------------------------------------
# Phase: Fixes
#
# The winutil "Config > Fixes" items that are Buttons rather than checkboxes, so
# they cannot ride along in a -Config run. Reimplemented directly.
#
# AutoLogon is deliberately absent. It writes the account password to
# HKLM\...\Winlogon\DefaultPassword in a form that is trivially recoverable by
# anything running on the box, and leaves the machine booting straight to an
# unlocked desktop. That is not a trade worth making on a machine you are
# handing back to someone else.
# ---------------------------------------------------------------------------

function Invoke-FixesPhase {
    Write-Phase 'Fixes'

    Invoke-CorruptionScan
    Install-CttPowerShellProfile
}

function Invoke-CorruptionScan {
    Add-PlannedAction -Kind 'command' -Target 'DISM /Online /Cleanup-Image /RestoreHealth' `
        -Detail 'repairs the component store; 10-30 minutes' -Reversible 'n/a - repair only'
    Add-PlannedAction -Kind 'command' -Target 'sfc /scannow' `
        -Detail 'repairs protected system files' -Reversible 'n/a - repair only'
    if (-not (Test-SelectedChange 'act|command|DISM /Online /Cleanup-Image /RestoreHealth')) {
        Write-Log 'Corruption scan not selected. Skipping.'
        return
    }
    if ($DryRun) {
        Write-Log -Level DRY -Message 'would run: DISM /RestoreHealth then sfc /scannow (10-30 minutes)'
        return
    }

    Write-Log 'Running DISM /RestoreHealth. This can take 10-30 minutes and may look stuck at 20%.'
    try {
        # DISM first: sfc repairs from the component store, so a corrupt store
        # makes sfc report damage it cannot fix. Order matters here.
        #
        # unbounded-by-design: stopping DISM part-way through a component-store
        # repair can leave the store in a worse state than the damage it was
        # sent to fix. The run says up front that this takes 10-30 minutes and
        # may look stuck at 20%, so a person watching it knows what they are
        # seeing. Waiting is the lesser risk.
        $dism = Start-Process -FilePath (Get-SystemTool 'DISM.exe') -Wait -PassThru -NoNewWindow `
            -ArgumentList '/Online','/Cleanup-Image','/RestoreHealth'
        if ($dism.ExitCode -eq 0) {
            Write-Log -Level OK -Message 'DISM completed cleanly.'
        } else {
            Write-Log -Level WARN -Message "DISM exited with code $($dism.ExitCode). Continuing to sfc."
        }
    } catch {
        Write-Log -Level FAIL -Message "DISM failed to start: $($_.Exception.Message)"
    }

    Write-Log 'Running sfc /scannow.'
    try {
        # unbounded-by-design: same reasoning as DISM above. sfc repairs
        # protected system files; interrupting it mid-replacement is how a
        # machine ends up with a half-written system binary.
        $sfc = Start-Process -FilePath (Get-SystemTool 'sfc.exe') -Wait -PassThru -NoNewWindow -ArgumentList '/scannow'
        switch ($sfc.ExitCode) {
            0       { Write-Log -Level OK   -Message 'sfc found no integrity violations.' }
            default { Write-Log -Level WARN -Message "sfc exited with code $($sfc.ExitCode). See CBS.log if this machine misbehaves." }
        }
    } catch {
        Write-Log -Level FAIL -Message "sfc failed to start: $($_.Exception.Message)"
    }
}

function Install-CttPowerShellProfile {
    # Only meaningful on PowerShell 7+. On 5.1 it installs a profile the user
    # will never see, so skip rather than pretend.
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Log -Level WARN -Message 'CTT PowerShell profile skipped: requires PowerShell 7+, this session is 5.1.'
        return
    }
    Add-PlannedAction -Kind 'external' -Target 'CTT PowerShell profile' `
        -Detail 'ChrisTitusTech/powershell-profile' -Reversible 'yes - its own uninstaller' -Tier op
    if (-not (Test-SelectedChange 'act|external|CTT PowerShell profile')) { return }
    if ($DryRun) {
        Write-Log -Level DRY -Message 'would install the CTT PowerShell profile'
        return
    }
    try {
        Invoke-RestMethod 'https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1' | Invoke-Expression
        Write-Log -Level OK -Message 'CTT PowerShell profile installed.'
    } catch {
        Write-Log -Level FAIL -Message "CTT profile install failed: $($_.Exception.Message)"
    }
}
