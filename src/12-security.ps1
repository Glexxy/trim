# ---------------------------------------------------------------------------
# Phase: Security
#
# The one phase whose default is to change nothing.
#
# Memory Integrity (HVCI, part of Virtualization-Based Security) checks every
# kernel-mode driver against a list of trusted code before it is allowed to run,
# with the hypervisor keeping that check isolated from Windows itself. It is the
# protection that stops a malicious or vulnerable driver reaching the kernel.
#
# Turning it off is worth roughly 3-7% average frame rate and up to about 15% on
# 1% lows, depending on the CPU. That is a real gain, and it is a real security
# downgrade - not a stability trade like most of this script, but a genuine
# reduction in what the machine can defend against.
#
# So: enabled stays enabled. The opt-out exists, is never the default, and says
# out loud what is being given up.
#
# Timing matters as of this writing. From October 2026 Windows quality updates
# begin enabling Memory Integrity on eligible machines where it is currently
# inactive - but Microsoft has said it will NOT re-enable it where it has been
# deliberately turned off. A machine that has it on today may lose frames after
# an update with no obvious cause, which is worth knowing before blaming a
# driver.
# ---------------------------------------------------------------------------

function Invoke-SecurityPhase {
    param(
        [Parameter(Mandatory)]$Facts,
        [switch]$DisableMemoryIntegrity
    )
    Write-Phase 'Security'

    $state = Get-MemoryIntegrityState
    Show-MemoryIntegrityState -State $state

    # The window can request this even when the command line did not, which is
    # the only way a trade-off ever gets selected: by someone ticking it.
    if ($null -ne $script:SelectionFilter -and
        (Test-SelectedChange 'act|command|Disable Memory Integrity (HVCI)')) {
        Disable-MemoryIntegrity -State $state
        return
    }

    if (-not $DisableMemoryIntegrity) {
        if ($state.HvciEnabled) {
            Write-Log 'Memory Integrity is ON and is being left ON. This is the correct default.'
            Write-Log 'To trade it for frames, re-run with -DisableMemoryIntegrity. Read the warning first.'
        }
        return
    }

    Disable-MemoryIntegrity -State $state
}

<#
.SYNOPSIS
    Read the real VBS / HVCI state, not just the registry intent.

.DESCRIPTION
    The registry says what was asked for; Win32_DeviceGuard says what is actually
    running. They disagree more often than people expect - a policy can be set
    while the feature fails to start because of an incompatible driver - so both
    are reported.
#>
function Get-MemoryIntegrityState {
    $running   = @()
    $vbsStatus = $null
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard `
            -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
        $running   = @($dg.SecurityServicesRunning)
        $vbsStatus = $dg.VirtualizationBasedSecurityStatus
    } catch {
        Write-Log -Level WARN -Message "Could not query Device Guard state: $($_.Exception.Message)"
    }

    # SecurityServicesRunning: 1 = Credential Guard, 2 = HVCI / Memory Integrity.
    # VirtualizationBasedSecurityStatus: 0 off, 1 configured but not running, 2 running.
    $regEnabled = $null
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    $v = Get-RegValueOrAbsent -Path $key -Name 'Enabled'
    if ($v.Exists) { $regEnabled = [int]$v.Value }

    return [pscustomobject]@{
        HvciEnabled     = ($running -contains 2)
        CredGuardActive = ($running -contains 1)
        VbsStatus       = $vbsStatus
        VbsRunning      = ($vbsStatus -eq 2)
        RegistryEnabled = $regEnabled
        Key             = $key
    }
}

function Show-MemoryIntegrityState {
    param([Parameter(Mandatory)]$State)

    $vbsText = switch ($State.VbsStatus) {
        0       { 'not enabled' }
        1       { 'enabled but not running' }
        2       { 'running' }
        default { 'unknown' }
    }
    Write-Log "Virtualization-Based Security : $vbsText"
    Write-Log "Memory Integrity (HVCI)       : $(if ($State.HvciEnabled) { 'ON' } else { 'off' })"
    if ($State.CredGuardActive) { Write-Log 'Credential Guard              : running' }

    if ($null -ne $State.RegistryEnabled -and
        [bool]$State.RegistryEnabled -ne $State.HvciEnabled) {
        Write-Log -Level WARN -Message "Policy says Enabled=$($State.RegistryEnabled) but the running state disagrees. Usually an incompatible driver blocking HVCI from starting."
    }

    if ($State.HvciEnabled) {
        Write-Log -Level WARN -Message 'From October 2026, Windows updates begin enabling Memory Integrity on machines where it is off.'
        Write-Log -Level WARN -Message '  Machines where it has been deliberately disabled are NOT re-enabled.'
        Write-Log -Level WARN -Message '  If frame rates drop after an update for no apparent reason, check this before blaming a driver.'
    } else {
        Write-Log 'Memory Integrity is already off. Windows will not re-enable it during the October 2026 rollout.'
    }
}

<#
.SYNOPSIS
    Opt-in only. Trades kernel driver protection for frames.
#>
function Disable-MemoryIntegrity {
    param([Parameter(Mandatory)]$State)

    if (-not $State.HvciEnabled -and $State.RegistryEnabled -ne 1) {
        Write-Log 'Memory Integrity is already off. Nothing to do.'
        return
    }

    Write-Host ''
    Write-Log -Level WARN -Message '================ READ THIS ================'
    Write-Log -Level WARN -Message 'Disabling Memory Integrity removes the check that stops a malicious or'
    Write-Log -Level WARN -Message 'vulnerable kernel driver tampering with Windows. Vulnerable-driver attacks'
    Write-Log -Level WARN -Message 'are a common, actively used technique, not a theoretical one.'
    Write-Log -Level WARN -Message ''
    Write-Log -Level WARN -Message 'You get roughly 3-7% average FPS and up to 15% on 1% lows for it.'
    Write-Log -Level WARN -Message ''
    Write-Log -Level WARN -Message 'Microsoft advise turning it off for a session and back on afterwards,'
    Write-Log -Level WARN -Message 'rather than leaving it off. This script cannot do that for you.'
    Write-Log -Level WARN -Message '=========================================='
    Write-Host ''

    Add-PlannedAction -Kind 'command' -Target 'Disable Memory Integrity (HVCI)' `
        -Detail 'security downgrade, explicitly opted into' `
        -Reversible 'yes - undo script restores it, reboot required' -Tier trade

    # A plain registry write, so the undo ledger covers it like anything else.
    Set-Reg $State.Key 'Enabled' 0 -Because 'Memory Integrity off (opted in)' -Tier trade
    Set-Reg $State.Key 'WasEnabledBy' 0 -Because 'clear the auto-enable marker so Windows does not restore it' -Tier trade

    Write-Log -Level WARN -Message 'Reboot required before this takes effect.'
    Write-Log 'To put it back: run the undo script, or Windows Security > Device security > Core isolation.'
}
