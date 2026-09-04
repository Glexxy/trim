# ---------------------------------------------------------------------------
# Phase: Personalisation
#
# Settings > Personalisation: Start, Taskbar, Background.
# ---------------------------------------------------------------------------

$script:Advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

function Invoke-PersonalisationPhase {
    Write-Phase 'Personalisation'

    Set-StartMenu
    Set-Taskbar
    Set-BackgroundToPicture
    Restart-Explorer
}

<#
.SYNOPSIS
    Start: everything on except "Show recommendations for tips, shortcuts, new apps".

.DESCRIPTION
    "Show the most used apps" is greyed out in Settings unless app launch tracking
    is on, so this turns that on. That is the one place where the requested Start
    layout and the privacy phase pull in opposite directions - the explicit Start
    instruction wins, and it is called out in the README.
#>
function Set-StartMenu {
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecentlyAddedApps' 0 `
        -Because 'Start: show recently added apps'

    Set-Reg $script:Advanced 'Start_TrackDocs'  1 -Because 'Start: show recommended and recent files'
    Set-Reg $script:Advanced 'Start_TrackProgs' 1 -Because 'Start: show most used apps (requires launch tracking)' -Tier op

    # Windows 11 only. Windows 10's Start menu has no recommendation strip, so
    # this value would sit in the registry doing nothing.
    Set-Reg $script:Advanced 'Start_IrisRecommendations' 0 -MinBuild 22000 `
        -Because 'Start: no recommendations for tips, shortcuts, new apps'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
        'SubscribedContent-338381Enabled' 0 -Because 'Start: no recommendation feed'

    Set-Reg $script:Advanced 'Start_AccountNotifications' 1 -Because 'Start: account notifications on'
}

function Set-Taskbar {
    # Search box: 0 hide, 1 icon only, 2 icon + box, 3 icon + label
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0 `
        -Because 'taskbar: search hidden'

    Set-Reg $script:Advanced 'ShowTaskViewButton' 0 -Because 'taskbar: task view off'

    # Widgets is the Windows 11 name for what Windows 10 called News and
    # Interests. Same idea, different key and different policy, so each build
    # gets the one that actually exists on it.
    Set-Reg $script:Advanced 'TaskbarDa' 0 -MinBuild 22000 -Because 'taskbar: widgets off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 -MinBuild 22000 `
        -Because 'taskbar: widgets off, machine-wide'

    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2 -MaxBuild 21999 `
        -Because 'taskbar: News and Interests off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0 -MaxBuild 21999 `
        -Because 'taskbar: News and Interests off, machine-wide'
}

<#
.SYNOPSIS
    Personalisation > Background > Picture.

.DESCRIPTION
    "Background type" is not a single toggle - Windows Spotlight is implemented as
    a content-delivery provider that keeps overwriting the wallpaper. Setting the
    type without disabling Spotlight leaves the user back on rotating stock photos
    within the hour.
#>
function Set-BackgroundToPicture {
    # 0 = Picture, 1 = Solid colour, 2 = Slideshow, 3 = Spotlight
    # The Wallpapers key is a Windows 11 addition. On Windows 10 the Spotlight
    # removal below is the part that matters, and it works on both.
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers' 'BackgroundType' 0 -MinBuild 22000 `
        -Because 'background: picture'

    Remove-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NewWallpaper' 'Enabled' `
        -Because 'stop Spotlight overwriting the wallpaper'

    # Keep whatever image is already set. Only fall back to the stock wallpaper
    # if there is genuinely nothing there - replacing someone's chosen background
    # is not an optimisation.
    $current = Get-RegValueOrAbsent -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper'
    if (-not $current.Exists -or [string]::IsNullOrWhiteSpace([string]$current.Value)) {
        $fallback = Join-Path $env:WinDir 'Web\Wallpaper\Windows\img0.jpg'
        if (Test-Path -LiteralPath $fallback) {
            Set-Reg 'HKCU:\Control Panel\Desktop' 'Wallpaper' $fallback -Type String `
                -Because 'background: no wallpaper was set, using the stock image'
        }
    } else {
        Write-Log "background: keeping the existing wallpaper ($($current.Value))"
    }
}

function Restart-Explorer {
    if ($DryRun) { Write-Log -Level DRY -Message 'would restart Explorer to apply shell changes'; return }
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        Write-Log -Level OK -Message 'Explorer restarted; shell changes are live.'
    } catch {
        Write-Log -Level WARN -Message 'Could not restart Explorer. Sign out and back in to see the taskbar and Start changes.'
    }
}
