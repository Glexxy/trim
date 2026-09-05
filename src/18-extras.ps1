# ---------------------------------------------------------------------------
# Phase: More options
#
# Everything here is deliberately NOT part of Recommended.
#
# The three presets only mean something if there is real ground between them.
# Before this file, Safe and Caution together were the entire catalogue, so
# Recommended ticked every box and the tiers did no work at all. These are the
# changes worth offering and wrong to assume: real trade-offs, hardware-specific
# wins, and preferences people genuinely disagree about.
#
# Several are gated on the machine actually being able to benefit. Turning off
# SysMain is defensible on an SSD and a serious regression on a hard disk, so it
# is only offered when the system drive is solid state. Turning off the print
# spooler is sensible with no printer attached and infuriating with one.
# ---------------------------------------------------------------------------

function Invoke-ExtrasPhase {
    param([Parameter(Mandatory)]$Facts)
    Write-Phase 'More options'

    Set-ExplorerPreferences
    Set-ShellExtras
    Set-PrivacyExtras
    Set-ServiceExtras     -Facts $Facts
    Set-NetworkExtras
    Set-UpdateBehaviour
    Remove-EdgeBrowser
}

<#
.SYNOPSIS
    File Explorer preferences people actually have opinions about.
#>
function Set-ExplorerPreferences {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    # The one genuinely safe item here, and a security improvement: hiding
    # extensions is how "invoice.pdf.exe" gets opened.
    Set-Reg $adv 'HideFileExt' 0 -Because 'Explorer: always show file extensions'

    Set-Reg $adv 'Hidden' 1 -Because 'Explorer: show hidden files' -Tier op
    Set-Reg $adv 'ShowSuperHidden' 0 -Because 'Explorer: keep protected system files hidden' -Tier op

    # 1 = This PC, 2 = Home, 3 = Downloads.
    Set-Reg $adv 'LaunchTo' 1 -Because 'Explorer: open on This PC rather than Home' -Tier op
    Set-Reg $adv 'UseCompactMode' 1 -Because 'Explorer: compact spacing' -Tier op

    Set-Reg $adv 'Start_TrackDocs' 1 -Because 'Explorer: keep recent files in Quick access'

    # The Gallery and Home entries in the navigation pane.
    Set-Reg 'HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}' `
        'System.IsPinnedToNameSpaceTree' 0 -Because 'Explorer: hide Gallery from the sidebar' -Tier op
}

<#
.SYNOPSIS
    Shell behaviour: snapping, suggested actions, transparency, the Copilot key.
#>
function Set-ShellExtras {
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    Set-Reg $adv 'SnapAssist' 0 -Because 'no Snap Assist suggestions after snapping a window' -Tier op
    # The flyout on the maximise button arrived with Windows 11; Snap Assist
    # itself goes back to Windows 10 and stays ungated.
    Set-Reg $adv 'EnableSnapAssistFlyout' 0 -MinBuild 22000 `
        -Because 'no snap layouts flyout on the maximise button' -Tier op

    # The pop-up offering to call a number or convert a date after a copy.
    Set-Reg 'HKCU:\Software\Microsoft\Windows\Shell\SuggestedActions' 'Enabled' 0 `
        -Because 'no suggested actions after copying text' -Tier op

    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
        'EnableTransparency' 0 -Because 'no transparency effects' -Tier op

    # Local clipboard history and its cloud sync are separate decisions. History
    # is a genuinely useful feature; syncing it to an account is not the same
    # thing, and most debloat scripts kill both without saying so.
    Set-Reg 'HKCU:\Software\Microsoft\Clipboard' 'EnableClipboardHistory' 1 `
        -Because 'keep local clipboard history (Win+V)'
    Set-Reg 'HKCU:\Software\Microsoft\Clipboard' 'CloudClipboardAutomaticUpload' 0 `
        -Because 'do not sync the clipboard to your Microsoft account' -Tier op
}

function Set-PrivacyExtras {
    # Windows Recall, belt and braces alongside winutil's AI tweak.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 `
        -Because 'Recall: no screen snapshot analysis'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0 `
        -Because 'Recall: cannot be switched on later'

    # Reporting the results of a malware scan back to Microsoft.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\MRT' 'DontReportInfectionInformation' 1 `
        -Because 'do not report malware removal results'

    # Activity history / Timeline.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0 `
        -Because 'no activity history' -Tier op
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0 `
        -Because 'do not upload activity history' -Tier op

    # Error reporting. Real cost: the diagnostic trail disappears too.
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 `
        -Because 'Windows Error Reporting off - also removes your own crash trail' -Tier op
}

<#
.SYNOPSIS
    Services worth turning off, each gated on the machine not needing it.

.DESCRIPTION
    None of these are blanket recommendations. Every one asks the machine a
    question first: is there a printer, is there a Bluetooth radio, is the
    system drive solid state. A tweak that is correct on one PC and destructive
    on another has no business being applied without checking which it is.
#>
function Set-ServiceExtras {
    param([Parameter(Mandatory)]$Facts)

    # SysMain. Roughly neutral on an SSD, a serious regression on a hard disk -
    # so it is only offered when the system drive is solid state.
    if ($Facts.SystemDriveSSD) {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\SysMain' 'Start' 4 `
            -Because 'SysMain off (system drive is an SSD, where it buys little)' -Tier op
    } else {
        Write-Log 'System drive is not an SSD. Leaving SysMain alone - disabling it on a hard disk is a real regression.'
    }

    # Print Spooler, only when nothing is installed to print to. It is also a
    # long-running source of remote code execution advisories.
    $printers = @()
    try { $printers = @(Get-Printer -ErrorAction Stop | Where-Object { $_.Type -eq 'Local' -and $_.Name -notmatch 'Microsoft|OneNote|Fax|PDF|XPS' }) } catch { }
    if ($printers.Count -eq 0) {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Spooler' 'Start' 4 `
            -Because 'Print Spooler off (no physical printer is installed)' -Tier op
    } else {
        Write-Log "Printer found ($($printers[0].Name)). Leaving the Print Spooler running."
    }

    # Bluetooth, only when the machine has no radio.
    $bt = @()
    try { $bt = @(Get-PnpDevice -Class Bluetooth -Status OK -ErrorAction Stop) } catch { }
    if ($bt.Count -eq 0) {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\bthserv' 'Start' 4 `
            -Because 'Bluetooth support off (no Bluetooth radio present)' -Tier op
    } else {
        Write-Log "Bluetooth radio present. Leaving the service alone."
    }

    # Fax. There is no gate worth writing for this one.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Fax' 'Start' 4 -Because 'Fax service off' -Tier op

    # Windows Search indexing. A real trade: search across documents gets much
    # slower, and on a fast SSD the index buys less than it used to.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch' 'Start' 4 `
        -Because 'Windows Search indexing off - file content search becomes much slower' -Tier trade

    # Memory compression. Trades RAM for CPU; on a machine with plenty of RAM
    # some people prefer the CPU back. On a machine without, this hurts.
    if ($Facts.RamGB -ge 32) {
        Add-PlannedAction -Kind 'command' -Target 'Disable memory compression' `
            -Detail "trades RAM for CPU; offered because this machine has $($Facts.RamGB) GB" `
            -Reversible 'yes - Enable-MMAgent -mc' -Tier trade
        if ((Test-SelectedChange 'act|command|Disable memory compression') -and -not $DryRun) {
            try { Disable-MMAgent -MemoryCompression -ErrorAction Stop; Write-Log -Level OK -Message 'Memory compression off.' }
            catch { Write-Log -Level WARN -Message "could not disable memory compression: $($_.Exception.Message.Trim())" }
        }
    }
}

function Set-NetworkExtras {
    # Teredo: IPv6 tunnelling almost nothing uses any more.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 1 `
        -Because 'Teredo IPv6 tunnelling off (native IPv6 still works)' -Tier op

    # NetBIOS over TCP/IP: a 1990s name resolution protocol and a standing
    # credential-relay risk on any shared network.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters' 'NodeType' 2 `
        -Because 'NetBIOS: peer-to-peer node type, no broadcast name resolution' -Tier op

    # LLMNR, same family, same reason.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0 `
        -Because 'LLMNR off - a well-known credential relay vector' -Tier op
}

<#
.SYNOPSIS
    Stop Windows Update rebooting the machine out from under someone.
#>
function Set-UpdateBehaviour {
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    Set-Reg $wu 'NoAutoRebootWithLoggedOnUsers' 1 `
        -Because 'never restart automatically while someone is signed in' -Tier op
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' 'IsExpedited' 0 `
        -Because 'no expedited update installs' -Tier op

    # Automatic Store app updates. Convenient, and also how a working setup
    # changes without anybody asking for it.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2 `
        -Because 'Store apps do not update themselves' -Tier trade
}

<#
.SYNOPSIS
    Uninstall Microsoft Edge, keeping WebView2.

.DESCRIPTION
    Risky tier, never selected by default.

    The usual objection to removing Edge is that WebView2 goes with it, and
    WebView2 is what Widgets, parts of Teams and Office, and a long tail of
    desktop applications render their interfaces with. That is avoidable: Edge
    and the WebView2 runtime are separate products that share an installer, and
    `--msedge` tells it to remove the browser only.

    What remains true regardless: on most builds Windows Update reinstates Edge
    at some later point, and outside the EEA Windows refuses the uninstall
    outright. Both are Microsoft's behaviour, and both are reported rather than
    worked around.
#>
function Remove-EdgeBrowser {
    # Two layouts, because Edge moved. Current builds keep the browser under
    # Microsoft\EdgeCore\<version>\; Microsoft\Edge\Application\<version>\ holds
    # only a manifest and pwahelper.exe. Older builds are the other way round.
    # Looking in one place found nothing on a machine that plainly had Edge.
    $setups = @()
    foreach ($pfRoot in (Get-ProgramFilesRoots)) {
        foreach ($layout in @('Microsoft\EdgeCore', 'Microsoft\Edge\Application')) {
            $base = Join-Path $pfRoot $layout
            try { if (-not (Test-Path -LiteralPath $base -ErrorAction Stop)) { continue } } catch { continue }
            foreach ($dir in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
                $candidate = Join-Path $dir.FullName 'Installer\setup.exe'
                if (Test-Path -LiteralPath $candidate) {
                    $setups += [pscustomobject]@{ Path = $candidate; Version = $dir.Name }
                }
            }
        }
    }

    if (-not $setups.Count) {
        Write-Log 'Edge: no installer found, nothing to remove.'
        return
    }

    # Newest first, in case several versions are staged side by side.
    $setup = @($setups | Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending)[0]

    Add-PlannedAction -Kind 'command' -Target 'Uninstall Microsoft Edge' `
        -Detail 'removes the browser only - WebView2 stays, so apps that render with it keep working. Windows Update may reinstall Edge later.' `
        -Reversible 'no - reinstall from microsoft.com/edge' -Tier trade

    if (-not (Test-SelectedChange 'act|command|Uninstall Microsoft Edge')) { return }

    if ($DryRun) {
        Write-Log -Level DRY -Message "would uninstall Edge $($setup.Version) using $($setup.Path)"
        return
    }

    Write-Log -Level WARN -Message "Uninstalling Edge $($setup.Version). WebView2 is deliberately left in place."
    try {
        $proc = Start-Process -FilePath $setup.Path -PassThru -Wait -WindowStyle Hidden `
            -ArgumentList '--uninstall', '--msedge', '--system-level', '--verbose-logging', '--force-uninstall'
        if ($proc.ExitCode -eq 0) {
            Write-Log -Level OK -Message 'Edge uninstalled. WebView2 left installed.'
        } else {
            Write-Log -Level WARN -Message "Edge uninstaller returned $($proc.ExitCode); nothing was changed."
            Write-Log -Level WARN -Message '  Windows blocks removal on builds outside the EEA. That is Microsoft policy, not a fault here.'
        }
    } catch {
        Write-Log -Level FAIL -Message "Could not run the Edge uninstaller: $($_.Exception.Message)"
    }
}
