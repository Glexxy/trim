# ---------------------------------------------------------------------------
# Phase: Appx
#
# "Remove all the bloatware" is not a safe instruction to take literally. Some
# AppX packages are load-bearing:
#   * Microsoft.VCLibs / UI.Xaml / NET.Native / WindowsAppRuntime are frameworks
#     other apps link against. Removing one breaks every app that depends on it.
#   * DesktopAppInstaller IS winget. Remove it and package management stops.
#   * XboxIdentityProvider is how a large number of PC games sign in. Removing it
#     produces game launch failures that look nothing like an AppX problem.
#   * SecHealthUI is the Windows Security interface.
#   * ScreenSketch is Snipping Tool - screenshots were explicitly to be kept.
#
# So this works from a named removal list, not a wildcard sweep, and refuses to
# touch anything on the protected list even if it is named.
# ---------------------------------------------------------------------------

$script:AppxProtected = @(
    'Microsoft.VCLibs','Microsoft.UI.Xaml','Microsoft.NET.Native','Microsoft.WindowsAppRuntime',
    'Microsoft.DesktopAppInstaller','Microsoft.WindowsStore','Microsoft.StorePurchaseApp',
    'Microsoft.SecHealthUI','Microsoft.ScreenSketch','Microsoft.WindowsNotepad','Microsoft.Paint',
    'Microsoft.WindowsCalculator','Microsoft.WindowsTerminal','Microsoft.Windows.Photos',
    'Microsoft.XboxIdentityProvider','Microsoft.Xbox.TCUI','Microsoft.GamingApp',
    'Microsoft.AAD.BrokerPlugin','Microsoft.AccountsControl','Microsoft.CredDialogHost',
    'Microsoft.LockApp','Microsoft.Win32WebViewHost','Microsoft.ECApp',
    # Named individually, NOT as the 'MicrosoftWindows.Client' prefix: that prefix
    # also covers MicrosoftWindows.Client.Copilot, so protecting it wholesale
    # silently made the Copilot removal a no-op.
    'MicrosoftWindows.Client.CBS','MicrosoftWindows.Client.Core',
    'MicrosoftWindows.Client.FileExp','MicrosoftWindows.Client.OOBE',
    'MicrosoftWindows.Client.Photon','MicrosoftWindows.Client.LKG',
    'Microsoft.Windows.ShellExperienceHost',
    'Microsoft.Windows.StartMenuExperienceHost','Microsoft.Windows.SecureAssessmentBrowser',
    'Microsoft.Windows.CloudExperienceHost','Microsoft.Windows.ContentDeliveryManager',
    'Microsoft.Windows.PeopleExperienceHost','Microsoft.Windows.Search',
    'Microsoft.MicrosoftEdge','Microsoft.WebpImageExtension','Microsoft.HEIFImageExtension',
    'Microsoft.VP9VideoExtensions','Microsoft.AV1VideoExtension','Microsoft.RawImageExtension',
    'Microsoft.HEVCVideoExtension','Microsoft.WindowsCamera'
)

# Safe on any machine. These are advertising surfaces and dead Microsoft products.
$script:AppxRemoveStandard = @(
    'Microsoft.3DBuilder','Microsoft.Microsoft3DViewer','Microsoft.Print3D',
    'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.BingFinance','Microsoft.BingSports',
    'Microsoft.News',
    'Microsoft.549981C3F5F10',                      # Cortana
    'Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.WindowsFeedbackHub',
    'Microsoft.Messaging','Microsoft.OneConnect','Microsoft.People','Microsoft.Wallet',
    'Microsoft.MicrosoftOfficeHub','Microsoft.Office.Lens','Microsoft.Office.Sway',
    'Microsoft.SkypeApp','Microsoft.MixedReality.Portal','Microsoft.NetworkSpeedTest',
    'Microsoft.WindowsMaps','Microsoft.WindowsAlarms','Microsoft.WindowsSoundRecorder',
    'Microsoft.MicrosoftSolitaireCollection','Microsoft.Whiteboard',
    'Microsoft.XboxApp','Microsoft.XboxGameOverlay','Microsoft.XboxGamingOverlay',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.YourPhone',
    'Microsoft.Copilot','MicrosoftWindows.Client.Copilot',
    'Microsoft.Windows.DevHome','Clipchamp.Clipchamp'
)

# Opinionated. Real products some people use, so they need -Aggressive.
$script:AppxRemoveAggressive = @(
    'Microsoft.Todos','Microsoft.Office.OneNote','Microsoft.MicrosoftStickyNotes',
    'MicrosoftTeams','MSTeams','Microsoft.OutlookForWindows',
    'Microsoft.PowerAutomateDesktop','Microsoft.MicrosoftJournal','Microsoft.Family',

    # Held back from the standard list because each has a real failure mode:
    #   BingSearch          - on some 24H2/25H2 builds removing it degrades the
    #                         Start menu search box, not just its web results.
    #                         DisableSearchBoxSuggestions already kills the web
    #                         results without touching the package.
    #   RealtekAudioControl - genuine OEM bloat, but on many boards it is the only
    #                         interface to the onboard audio's EQ and jack config.
    'Microsoft.BingSearch','RealtekSemiconductorCorp.RealtekAudioControl'
)

# OEM preloads. Matched as prefixes because vendors version the package family.
$script:AppxRemoveOem = @(
    'AcerIncorporated','ASUSTeKCOMPUTERINC','DellInc','HPInc','LenovoCorporation',
    'Lenovo.Lenovo','E046963F.LenovoCompanion','B9ECED6F.ASUSPCAssistant',
    'Nvidia.GeForceNow',
    'Disney.37853FC22B2CE','SpotifyAB.SpotifyMusic','5319275A.WhatsAppDesktop',
    'AmazonVideo.PrimeVideo','BytedancePte.Ltd.TikTok','Facebook.Facebook',
    'king.com.CandyCrush','king.com.CandyCrushSaga','king.com.CandyCrushSodaSaga',
    'Netflix.Netflix','PricelinePartnerNetwork','ClearChannelRadioDigital.iHeartRadio'
)

function Invoke-AppxPhase {
    Write-Phase 'AppX removal'

    $targets = @($script:AppxRemoveStandard + $script:AppxRemoveOem)
    if ($Aggressive) {
        $targets += $script:AppxRemoveAggressive
        Write-Log -Level WARN -Message '-Aggressive: also removing Teams, OneNote, To Do, Sticky Notes and friends.'
    }

    # -AllUsers needs administrator and throws a terminating "Access is denied"
    # rather than honouring -ErrorAction, so it needs a real fallback: without one
    # the whole phase dies instead of doing what it can for the current user.
    $installed = @()
    try {
        $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
    } catch {
        Write-Log -Level WARN -Message "Could not enumerate packages for all users ($($_.Exception.Message.Trim())). Falling back to the current user only."
        try {
            $installed = @(Get-AppxPackage -ErrorAction Stop)
        } catch {
            Write-Log -Level FAIL -Message "Could not enumerate AppX packages at all: $($_.Exception.Message.Trim()). Skipping phase."
            return
        }
    }
    if ($installed.Count -eq 0) {
        Write-Log -Level WARN -Message 'No AppX packages returned. Skipping phase.'
        return
    }
    Write-Log "$($installed.Count) AppX package(s) installed."

    $removed = 0
    foreach ($target in ($targets | Select-Object -Unique)) {

        if (Test-AppxProtected $target) {
            Write-Log -Level WARN -Message "refusing to remove protected package '$target'"
            continue
        }

        # Not $matches - that is an automatic variable populated by -match, and
        # shadowing it makes every regex in scope behave unpredictably.
        $hits = @($installed | Where-Object { $_.Name -like "$target*" })
        foreach ($pkg in $hits) {

            # Re-check the resolved name: a prefix in the removal list must not be
            # able to sweep up a protected package that happens to start with it.
            if (Test-AppxProtected $pkg.Name) {
                Write-Log -Level WARN -Message "skipping '$($pkg.Name)': matched '$target' but is protected"
                continue
            }

            $tier = if ($script:AppxRemoveAggressive -contains $target -or
                        $script:AppxRemoveOem -contains $target) { 'op' } else { 'safe' }
            Add-PlannedAction -Kind 'appx' -Target $pkg.Name `
                -Detail 'removed for current users and deprovisioned' `
                -Reversible 'reinstall from the Store' -Tier $tier
            if (-not (Test-SelectedChange "act|appx|$($pkg.Name)")) { continue }
            if ($DryRun) {
                Write-Log -Level DRY -Message "would remove AppX: $($pkg.Name)"
                continue
            }

            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
                Write-Log -Level OK -Message "removed AppX: $($pkg.Name)"
                $removed++
            } catch {
                # Some packages refuse -AllUsers but come out fine for the current
                # user. Worth the second attempt before reporting a failure.
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                    Write-Log -Level OK -Message "removed AppX (current user): $($pkg.Name)"
                    $removed++
                } catch {
                    Write-Log -Level WARN -Message "could not remove $($pkg.Name): $($_.Exception.Message.Trim())"
                }
            }
        }

        # Also drop the provisioned copy, or it reinstalls for the next new user
        # and after some feature updates.
        if (-not $DryRun) {
            try {
                $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                          Where-Object { $_.DisplayName -like "$target*" -and -not (Test-AppxProtected $_.DisplayName) })
                foreach ($p in $prov) {
                    Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                    Write-Log -Level OK -Message "deprovisioned: $($p.DisplayName)"
                }
            } catch { }
        }
    }

    Write-Log "AppX phase complete. $removed package(s) removed."
    Write-Log -Level WARN -Message 'AppX removals are NOT reversible by the undo script. Reinstall from the Store if something is missed.'
}

function Test-AppxProtected {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($p in $script:AppxProtected) {
        if ($Name -like "$p*") { return $true }
    }
    return $false
}
