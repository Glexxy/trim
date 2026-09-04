# ---------------------------------------------------------------------------
# Phase: Background
#
# Scheduled tasks, services, and the trace sessions everyone forgets.
#
# The forgotten part matters. Disabling the DiagTrack service stops the service,
# but AutoLogger-Diagtrack-Listener and SQMLogger are Event Tracing sessions
# started by the kernel at boot, independently of it. Most debloat scripts leave
# them running, which is why telemetry files keep reappearing on a machine
# somebody has already "disabled telemetry" on.
#
# Nothing here removes a service. Disabling one is reversible from the same
# undo script as everything else; deleting one is not.
# ---------------------------------------------------------------------------

# Safe: pure telemetry and compatibility reporting. Nothing depends on these.
$script:TelemetryTasks = @(
    @{ Path = '\Microsoft\Windows\Application Experience\';           Name = 'Microsoft Compatibility Appraiser'; Why = 'compatibility telemetry; a recurring cause of unexplained disk and CPU spikes' }
    @{ Path = '\Microsoft\Windows\Application Experience\';           Name = 'ProgramDataUpdater';                Why = 'compatibility telemetry' }
    @{ Path = '\Microsoft\Windows\Application Experience\';           Name = 'StartupAppTask';                    Why = 'startup app telemetry' }
    @{ Path = '\Microsoft\Windows\Application Experience\';           Name = 'PcaPatchDbTask';                    Why = 'compatibility telemetry' }
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator';               Why = 'Customer Experience Improvement Program' }
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip';                    Why = 'USB telemetry' }
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'KernelCeipTask';             Why = 'kernel telemetry' }
    @{ Path = '\Microsoft\Windows\Autochk\';                          Name = 'Proxy';                             Why = 'uploads autochk data' }
    @{ Path = '\Microsoft\Windows\Feedback\Siuf\';                    Name = 'DmClient';                          Why = 'feedback prompts' }
    @{ Path = '\Microsoft\Windows\Feedback\Siuf\';                    Name = 'DmClientOnScenarioDownload';        Why = 'feedback prompts' }
)

# Opinionated: real features, just ones most people are not using.
$script:OptionalTasks = @(
    @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting'; Why = 'uploads crash reports; also removes the trail you would want if something crashes repeatedly' }
    @{ Path = '\Microsoft\Windows\Maps\';                    Name = 'MapsToastTask';  Why = 'offline maps notifications' }
    @{ Path = '\Microsoft\Windows\Maps\';                    Name = 'MapsUpdateTask'; Why = 'offline maps updates' }
    @{ Path = '\Microsoft\Windows\Retail Demo\';             Name = 'CleanupOfflineContent'; Why = 'shop demo mode content' }
)

$script:TelemetryServices = @(
    @{ Name = 'DiagTrack';         Why = 'Connected User Experiences and Telemetry - the telemetry pipe itself'; Tier = 'safe' }
    @{ Name = 'dmwappushservice';  Why = 'WAP push message routing, used for device management telemetry';      Tier = 'safe' }
    @{ Name = 'diagnosticshub.standardcollector.service'; Why = 'diagnostics hub collector';                     Tier = 'safe' }
    @{ Name = 'RetailDemo';        Why = 'shop demonstration mode';                                             Tier = 'op' }
    @{ Name = 'MapsBroker';        Why = 'downloads offline maps in the background';                             Tier = 'op' }
    @{ Name = 'WalletService';     Why = 'Microsoft Wallet';                                                     Tier = 'op' }
)

# Event Tracing sessions started at boot, independently of any service.
$script:AutoLoggers = @(
    @{ Name = 'AutoLogger-Diagtrack-Listener'; Why = 'the trace session telemetry writes to, even with DiagTrack stopped' }
    @{ Name = 'SQMLogger';                     Why = 'Software Quality Metrics trace session' }
)

function Invoke-BackgroundPhase {
    Write-Phase 'Background'

    Disable-TelemetryTasks
    Disable-TelemetryServices
    Disable-AutoLoggers
}

function Disable-TelemetryTasks {
    $all = @()
    foreach ($t in $script:TelemetryTasks) { $all += ($t + @{ Tier = 'safe' }) }
    foreach ($t in $script:OptionalTasks)  { $all += ($t + @{ Tier = 'op' }) }

    # One enumeration, then a lookup. Calling Get-ScheduledTask per task cost
    # roughly 400 ms each - nearly six seconds of the launch, for fourteen tasks.
    $known = @{}
    try {
        foreach ($t in (Get-ScheduledTask -ErrorAction Stop)) {
            $known["$($t.TaskPath)$($t.TaskName)"] = $t
        }
    } catch {
        Write-Log -Level WARN -Message "Could not enumerate scheduled tasks: $($_.Exception.Message.Trim())"
        return
    }

    $present = 0
    foreach ($t in $all) {
        $task = $known["$($t.Path)$($t.Name)"]
        # Absent on this build or edition. Not a problem, and not worth a warning.
        if (-not $task) { continue }
        if ($task.State -eq 'Disabled') { $script:Skipped++; continue }
        $present++

        $key = "$($t.Path)$($t.Name)"
        Add-PlannedAction -Kind 'command' -Target "Disable scheduled task: $key" `
            -Detail $t.Why -Reversible 'yes - Enable-ScheduledTask' -Tier $t.Tier
        if (-not (Test-SelectedChange "act|command|Disable scheduled task: $key")) { continue }

        if ($DryRun) { Write-Log -Level DRY -Message "would disable scheduled task: $key"; continue }
        try {
            Disable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null
            Write-Log -Level OK -Message "disabled task: $key"
            $script:Applied++
        } catch {
            Write-Log -Level WARN -Message "could not disable '$key': $($_.Exception.Message.Trim())"
        }
    }
    Write-Log "Scheduled tasks: $present enabled telemetry task(s) found."
}

<#
.SYNOPSIS
    Set a service to Disabled, not merely stop it.

.DESCRIPTION
    A stopped service starts again at next boot. The start type is a registry
    value, so it goes through the ledger and the undo script restores it like
    anything else.
#>
function Disable-TelemetryServices {
    foreach ($svc in $script:TelemetryServices) {
        $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if (-not $s) { continue }

        # 4 = Disabled. Written through Set-Reg so it lands in the undo script.
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)"
        Set-Reg $key 'Start' 4 -Because "service off: $($svc.Name) - $($svc.Why)" -Tier $svc.Tier

        if ($DryRun -or $s.Status -ne 'Running') { continue }
        if (-not (Test-SelectedChange "reg|$key|Start")) { continue }
        try {
            Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            Write-Log -Level OK -Message "stopped service: $($svc.Name)"
        } catch {
            Write-Log "service '$($svc.Name)' could not be stopped now; the disabled start type takes effect at reboot"
        }
    }
}

function Disable-AutoLoggers {
    foreach ($l in $script:AutoLoggers) {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\$($l.Name)"
        if (-not (Test-Path -LiteralPath $key)) { continue }
        Set-Reg $key 'Start' 0 -Because "trace session off: $($l.Name) - $($l.Why)"
    }
}
