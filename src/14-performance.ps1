# ---------------------------------------------------------------------------
# Phase: Performance
#
# The largest real wins on a modern machine are not registry folklore - they are
# the power plan and Fast Startup. Most of what circulates as "ultimate
# optimization" is either already the default, ignored by the modern kernel, or
# actively harmful.
#
# What is deliberately absent, and why, because the absence is the useful part:
#
#   bcdedit disabledynamictick / useplatformtick
#       In every guide. Modern Windows manages timer resolution per process;
#       forcing these measurably hurts on current hardware and causes stutter.
#
#   MSI mode / forced interrupt affinity for the GPU
#       Real latency gains on some hardware, and a documented cause of
#       unbootable systems on hardware that does not support it. Not something
#       to do unattended on a machine you will never see.
#
#   Disabling SysMain / Superfetch and Prefetch
#       Roughly neutral on an SSD; a serious regression on a hard disk, and
#       plenty of target machines still have one.
#
#   Disabling the pagefile, or clearing it at shutdown
#       Breaks applications that expect committed memory, and adds minutes to
#       shutdown for a benefit nobody in this audience needs.
# ---------------------------------------------------------------------------

function Invoke-PerformancePhase {
    param([Parameter(Mandatory)]$Facts)
    Write-Phase 'Performance'

    Set-PowerPlan          -Facts $Facts
    Disable-FastStartup
    Set-HibernationState   -Facts $Facts
    Set-ForegroundPriority
    Set-StartupResponsiveness
    Set-GraphicsScheduling -Facts $Facts
    Block-DriverReplacement
    Set-VisualEffects
}

<#
.SYNOPSIS
    The single largest uncontested win: stop the CPU idling down under load.

.DESCRIPTION
    Ultimate Performance is hidden by default and has to be cloned from its
    well-known scheme GUID before it can be selected. It removes core parking
    and the last of the clock ramping. On a laptop it is just heat and a flat
    battery, so laptops get High Performance at most, and only when asked.
#>
function Set-PowerPlan {
    param([Parameter(Mandatory)]$Facts)

    if ($Facts.IsLaptop) {
        Write-Log 'Laptop: leaving the power plan alone. Balanced is the right default on battery.'
        return
    }

    $ultimateGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    Add-PlannedAction -Kind 'command' -Target 'Power plan: Ultimate Performance' `
        -Detail 'stops core parking and clock ramping; desktop only' `
        -Reversible 'yes - powercfg /setactive on the previous scheme'

    if (-not (Test-SelectedChange 'act|command|Power plan: Ultimate Performance')) { return }
    if ($DryRun) {
        Write-Log -Level DRY -Message 'would enable and select the Ultimate Performance power plan'
        return
    }

    try {
        $powercfg = Get-SystemTool 'powercfg.exe'
        if (-not $powercfg) { return }
        $before = (& $powercfg /getactivescheme) -join ' '
        Write-Log "Current plan: $before"

        # Cloning an already-cloned scheme is harmless; it just returns the
        # existing one on most builds.
        & $powercfg -duplicatescheme $ultimateGuid 2>&1 | Out-Null
        $out = & $powercfg /setactive $ultimateGuid 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log -Level OK -Message 'Ultimate Performance plan active.'
        } else {
            Write-Log -Level WARN -Message "Could not select Ultimate Performance ($out). Trying High Performance."
            & $powercfg /setactive '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' 2>&1 | Out-Null
        }
    } catch {
        Write-Log -Level WARN -Message "Power plan change failed: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Make "shut down" mean shut down.

.DESCRIPTION
    Fast Startup turns a shutdown into a partial hibernate. It is why a machine
    that misbehaves is fixed by Restart but not by Shut Down, it carries stale
    driver state across boots, and it breaks dual boot by leaving the filesystem
    mounted. On an SSD it saves a couple of seconds.
#>
function Disable-FastStartup {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0 `
        -Because 'Fast Startup off, so shutdown means shutdown'
}

<#
.SYNOPSIS
    Reclaim the hibernation file on a desktop that will never hibernate.
#>
function Set-HibernationState {
    param([Parameter(Mandatory)]$Facts)

    if ($Facts.IsLaptop) {
        Write-Log 'Laptop: keeping hibernation. It is worth having on battery.'
        return
    }

    $hiberfil = Join-Path $env:SystemDrive 'hiberfil.sys'
    $sizeGb = 0
    try { if (Test-Path -LiteralPath $hiberfil) { $sizeGb = [Math]::Round((Get-Item -Force $hiberfil).Length / 1GB, 1) } } catch { }
    if ($sizeGb -eq 0) { Write-Log 'Hibernation already off.'; return }

    Add-PlannedAction -Kind 'command' -Target 'Disable hibernation' `
        -Detail "reclaims about $sizeGb GB on $env:SystemDrive; desktop only" `
        -Reversible 'yes - powercfg /h on' -Tier op

    if (-not (Test-SelectedChange 'act|command|Disable hibernation')) { return }
    if ($DryRun) { Write-Log -Level DRY -Message "would run powercfg /h off, reclaiming about $sizeGb GB"; return }

    try {
        $powercfg = Get-SystemTool 'powercfg.exe'
        if (-not $powercfg) { return }
        & $powercfg /h off 2>&1 | Out-Null
        Write-Log -Level OK -Message "Hibernation off. About $sizeGb GB reclaimed."
    } catch {
        Write-Log -Level WARN -Message "powercfg /h off failed: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Give the focused window longer, more frequent time slices.

.DESCRIPTION
    26 is short, variable-length quanta with a 3:1 foreground boost. Real and
    measurable for games; mildly worse for background encodes and compiles,
    which is exactly why it is opinionated rather than safe.
#>
function Set-ForegroundPriority {
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 26 `
        -Because 'foreground boost for the focused window' -Tier op
}

function Set-StartupResponsiveness {
    # Windows deliberately holds logon startup items for about ten seconds. On
    # an SSD that delay buys nothing.
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0 `
        -Because 'no artificial delay before startup apps run'

    # 400 ms of nothing on every menu.
    Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0' -Type String `
        -Because 'menus open immediately'
}

<#
.SYNOPSIS
    Hardware-accelerated GPU scheduling.

.DESCRIPTION
    Lets the GPU manage its own memory and command scheduling instead of the
    kernel doing it. Generally a small win on modern hardware and a requirement
    for frame generation, but it needs a reboot, and a handful of older cards
    and capture tools misbehave with it - so it is offered, not assumed.
#>
function Set-GraphicsScheduling {
    param([Parameter(Mandatory)]$Facts)

    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    $supported = Get-RegValueOrAbsent -Path $key -Name 'HwSchMode'
    if (-not $supported.Exists) {
        Write-Log 'Hardware GPU scheduling is not exposed on this machine. Skipping.'
        return
    }
    Set-Reg $key 'HwSchMode' 2 -Because 'hardware-accelerated GPU scheduling on (reboot required)' -Tier op
}

<#
.SYNOPSIS
    Stop Windows Update quietly replacing the graphics driver.

.DESCRIPTION
    A common and genuinely confusing cause of "my frame rate dropped and I
    changed nothing". The cost is that driver updates become the owner's job.
#>
function Block-DriverReplacement {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0 `
        -Because 'do not fetch drivers from Windows Update automatically' -Tier op
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1 `
        -Because 'do not ship drivers inside quality updates' -Tier op
}

<#
.SYNOPSIS
    Performance Options: everything off except the five worth keeping.

.DESCRIPTION
    This is the "Adjust the appearance and performance of Windows" dialog. The
    stock "Adjust for best performance" preset turns off all seventeen items,
    including font smoothing - which on a modern high-DPI display does not read
    as a tuning choice, it reads as a broken display.

    So: apply the documented best-performance state, then put back the five that
    cost nothing and whose absence is obvious.

        Enable Peek
        Show thumbnails instead of icons
        Show window contents while dragging
        Smooth edges of screen fonts
        Use drop shadows for icon labels on the desktop

    UserPreferencesMask is a bitfield covering the animation and fade effects.
    0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00 is the value Windows itself writes
    for best performance. The prior bytes go through the ledger like any other
    change, so undo restores the mask exactly.
#>
function Set-VisualEffects {
    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $desktop  = 'HKCU:\Control Panel\Desktop'

    # 3 = Custom. Without this the dialog shows a preset and ignores the detail.
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
        'VisualFXSetting' 3 -Because 'appearance: custom, not a blanket preset' -Tier op

    # Every animation and fade off, in one bitfield.
    Set-Reg $desktop 'UserPreferencesMask' ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) `
        -Type Binary -Because 'appearance: animations, fades and shadows off' -Tier op

    # --- the ones that are their own value, turned off -------------------
    Set-Reg "$desktop\WindowMetrics" 'MinAnimate' '0' -Type String `
        -Because 'appearance: no minimise and maximise animation' -Tier op
    Set-Reg $advanced 'TaskbarAnimations'   0 -Because 'appearance: no taskbar animations' -Tier op
    Set-Reg $advanced 'ListviewAlphaSelect' 0 -Because 'appearance: no translucent selection rectangle' -Tier op
    Set-Reg $advanced 'TaskbarSli'          0 -Because 'appearance: no taskbar thumbnail previews saved' -Tier op

    # --- the five that stay on -------------------------------------------
    Set-Reg $advanced 'EnableAeroPeek'  1 -Because 'appearance: KEEP Enable Peek'
    Set-Reg $advanced 'IconsOnly'       0 -Because 'appearance: KEEP thumbnails instead of icons'
    Set-Reg $advanced 'ListviewShadow'  1 -Because 'appearance: KEEP drop shadows for desktop icon labels'
    Set-Reg $desktop  'DragFullWindows' '1' -Type String `
        -Because 'appearance: KEEP window contents visible while dragging'
    Set-Reg $desktop  'FontSmoothing'     '2' -Type String -Because 'appearance: KEEP smooth screen font edges'
    Set-Reg $desktop  'FontSmoothingType' 2   -Because 'appearance: KEEP ClearType specifically'

    Write-Log 'Appearance: everything off except Peek, thumbnails, drag contents, font smoothing and icon-label shadows.'
}
