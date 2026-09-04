# ---------------------------------------------------------------------------
# Phase: Network
#
# Deliberately thin. Most of what circulates as "network optimization" is
# cargo-cult: registry values that were meaningful on Windows XP, are ignored by
# the modern TCP stack, or are already the default. This phase does four things
# that have a measurable effect and nothing that does not.
#
# It also REPORTS on things it will not change, because the most common real
# network problem on a gaming machine is a NIC negotiating below its rated speed,
# and no registry key fixes that.
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    The live physical adapters, fetched once per run.

.DESCRIPTION
    Get-NetAdapter is not cheap and three separate functions here wanted the
    same list.
#>
$script:LiveAdapters = $null
function Get-LiveAdapters {
    if ($null -ne $script:LiveAdapters) { return $script:LiveAdapters }
    try {
        $script:LiveAdapters = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    } catch {
        $script:LiveAdapters = @()
    }
    return $script:LiveAdapters
}

function Invoke-NetworkPhase {
    param([Parameter(Mandatory)]$Facts)
    Write-Phase 'Network'

    Set-MultimediaScheduling
    Disable-NagleAlgorithm
    Set-TcpDefaults
    if (-not $Facts.IsLaptop) { Disable-NicPowerSaving }
    else { Write-Log 'Laptop: leaving NIC power management alone, it is worth real battery life.' }
    Test-NicLinkHealth
}

<#
.SYNOPSIS
    Stop the multimedia class scheduler throttling network throughput.

.DESCRIPTION
    NetworkThrottlingIndex caps non-multimedia packets at ~10 per millisecond
    while any multimedia app is running, which on a machine that games and streams
    at the same time is a real ceiling. SystemResponsiveness is the share of CPU
    reserved for background tasks; 20 is the default, 10 is a reasonable trade,
    0 is what most guides say and is more aggressive than it needs to be.
#>
function Set-MultimediaScheduling {
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    # 0xFFFFFFFF is the documented "disabled" value. PowerShell parses that hex
    # literal as Int32 -1, which writes the same 32 bits - do NOT "fix" this to
    # 4294967295, which overflows a DWord and makes the write fail outright.
    Set-Reg $p 'NetworkThrottlingIndex' 0xFFFFFFFF -Because 'no network throttling under multimedia load (writes 0xFFFFFFFF)'
    Set-Reg $p 'SystemResponsiveness'   10         -Because 'reduce background CPU reservation from 20% to 10%' -Tier op

    Set-Reg "$p\Tasks\Games" 'GPU Priority' 8        -Because 'games: GPU priority'
    Set-Reg "$p\Tasks\Games" 'Priority'     6        -Because 'games: scheduling priority' -Tier op
    Set-Reg "$p\Tasks\Games" 'Scheduling Category' 'High' -Type String -Because 'games: scheduling category' -Tier op
}

<#
.SYNOPSIS
    Disable Nagle's algorithm on every physical interface.

.DESCRIPTION
    Nagle batches small outbound packets to save bandwidth. For games that send a
    steady stream of tiny state updates it adds up to 200ms of avoidable latency.
    The cost is slightly more overhead on bulk transfers, which on a modern link
    is not worth caring about.

    Applied per-interface, and only to interfaces with a real gateway - writing
    this to a VPN tunnel adapter is pointless and occasionally upsets the client.
#>
function Disable-NagleAlgorithm {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    if (-not (Test-Path -LiteralPath $base)) {
        Write-Log -Level WARN -Message 'TCP interface list not found; skipping Nagle.'
        return
    }

    # Only touch adapters that are up, physical, and actually routing traffic.
    $liveGuids = @(Get-LiveAdapters | Select-Object -ExpandProperty InterfaceGuid)

    if ($liveGuids.Count -eq 0) {
        Write-Log -Level WARN -Message 'No physical adapter is up; skipping Nagle.'
        return
    }

    foreach ($guid in $liveGuids) {
        $key = Join-Path $base $guid
        if (-not (Test-Path -LiteralPath $key)) { continue }
        Set-Reg $key 'TcpAckFrequency' 1 -Because 'Nagle off: acknowledge immediately' -Tier op
        Set-Reg $key 'TCPNoDelay'      1 -Because 'Nagle off: do not coalesce small sends' -Tier op
    }
}

<#
.SYNOPSIS
    Put the TCP stack back to its correct defaults.

.DESCRIPTION
    These are already right on a healthy machine. They are here because the single
    most common thing a previous "optimizer" leaves behind is receive window
    autotuning disabled, which quietly caps throughput on any high-latency or
    high-bandwidth link.
#>
function Set-TcpDefaults {
    foreach ($n in @('autotuninglevel=normal','rss=enabled','ecncapability=disabled')) {
        Add-PlannedAction -Kind 'command' -Target "netsh int tcp set global $n" `
            -Detail 'restores a TCP default' -Reversible 'manually, see README'
    }
    if ($DryRun) {
        Write-Log -Level DRY -Message 'would ensure: autotuninglevel=normal, rss=enabled, ecncapability=disabled'
        return
    }
    if (-not (Test-SelectedChange 'act|command|netsh int tcp set global autotuninglevel=normal')) {
        Write-Log 'TCP defaults not selected. Skipping.'
        return
    }
    foreach ($cmd in @(
        @('autotuninglevel','normal'),
        @('rss','enabled'),
        @('ecncapability','disabled')
    )) {
        try {
            $out = & (Get-SystemTool 'netsh.exe') int tcp set global "$($cmd[0])=$($cmd[1])" 2>&1
            Write-Log -Level OK -Message "netsh: $($cmd[0]) = $($cmd[1])"
        } catch {
            Write-Log -Level WARN -Message "netsh $($cmd[0]) failed: $($_.Exception.Message)"
        }
    }
    Write-Log -Level WARN -Message 'netsh changes are NOT covered by the undo script. Reverse with: netsh int tcp set global autotuninglevel=normal'
}

function Disable-NicPowerSaving {
    Add-PlannedAction -Kind 'command' -Target 'Set-NetAdapterPowerManagement -SelectiveSuspend Disabled' `
        -Detail 'desktop only; skipped on laptops' -Reversible 'yes, re-enable in Device Manager'
    if ($DryRun) { Write-Log -Level DRY -Message 'would disable NIC selective suspend / power-down on desktop adapters'; return }
    if (-not (Test-SelectedChange 'act|command|Set-NetAdapterPowerManagement -SelectiveSuspend Disabled')) { return }
    try {
        $adapters = @(Get-LiveAdapters)
        foreach ($a in $adapters) {
            try {
                # Not every driver exposes this; a missing property is normal and
                # not worth reporting as a failure.
                Set-NetAdapterPowerManagement -Name $a.Name -SelectiveSuspend Disabled -ErrorAction Stop
                Write-Log -Level OK -Message "power saving disabled on '$($a.Name)'"
            } catch {
                Write-Log "adapter '$($a.Name)' does not expose selective suspend; left alone"
            }
        }
    } catch {
        Write-Log -Level WARN -Message "NIC power management unavailable: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Report adapters linked below their rated speed, or with a forced link mode.

.DESCRIPTION
    Reports only - fixing this means changing a driver property that can drop the
    link entirely on a bad cable or an unmanaged switch, which is not something to
    do unattended on someone else's machine.
#>
function Test-NicLinkHealth {
    $adapters = @(Get-LiveAdapters)

    foreach ($a in $adapters) {
        # Match on RegistryKeyword, never DisplayName. DisplayName and
        # DisplayValue are translated - "Speed & Duplex" is "Geschwindigkeit und
        # Duplex" on a German install - so matching them means this diagnostic
        # silently finds nothing on most of the world's machines.
        $props = @()
        try { $props = @(Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue) } catch { }

        $forced = @($props | Where-Object { $_.RegistryKeyword -eq '*SpeedDuplex' })[0]
        # RegistryValue 0 is auto-negotiate on every NDIS driver; anything else
        # is a forced link mode. The value is invariant, the label is not.
        if ($forced -and "$($forced.RegistryValue)" -notmatch '^\{?0\}?$') {
            Write-Log -Level WARN -Message "'$($a.Name)' has Speed & Duplex forced to '$($forced.DisplayValue)' but is linked at $($a.LinkSpeed)."
            Write-Log -Level WARN -Message "  A forced link mode that does not match the switch is the usual cause of a 2.5GbE card sitting at 1 Gbps."
            Write-Log -Level WARN -Message "  Fix by hand: Device Manager > $($a.InterfaceDescription) > Advanced > Speed & Duplex > Auto Negotiation."
        }

        # Power-saving link features, again by invariant keyword. RegistryValue
        # 1 means on. DisplayName is only used to say something readable.
        $savers = @($props | Where-Object {
            $_.RegistryKeyword -in @('GigaLite','EnableGreenEthernet','*EEE','AdvancedEEE') -and
            "$($_.RegistryValue)" -match '^\{?1\}?$'
        })
        foreach ($l in $savers) {
            Write-Log -Level WARN -Message "'$($a.Name)': '$($l.DisplayName)' ($($l.RegistryKeyword)) is enabled. This can cap or destabilise the link on 2.5GbE parts."
        }
    }
}
