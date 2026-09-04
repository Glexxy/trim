# ---------------------------------------------------------------------------
# Phase: Privacy
#
# Explicitly NEVER touched, because they are things people actually need and
# silently breaking them is how a "privacy script" earns a reputation:
#     webcam                          - camera
#     microphone                      - microphone
#     graphicsCaptureProgrammatic     - screenshots
#     graphicsCaptureWithoutBorder    - screen recording
#     documentsLibrary / picturesLibrary / videosLibrary / broadFileSystemAccess
#         - denying these breaks Store apps' access to the user's own files
#     humanPresence                   - presence sensing / wake on approach
# ---------------------------------------------------------------------------

$script:ConsentNeverTouch = @(
    'webcam','microphone','graphicsCaptureProgrammatic','graphicsCaptureWithoutBorder',
    'documentsLibrary','picturesLibrary','videosLibrary','musicLibrary',
    'broadFileSystemAccess','humanPresence','downloadsFolder'
)

# App permissions with no plausible use on a machine being tuned for a desktop
# user. Each of these has a visible toggle in Settings > Privacy & security.
$script:ConsentDeny = @(
    'appointments','contacts','chat','email','phoneCall','phoneCallHistory',
    'userDataTasks','radios','bluetoothSync','cellularData',
    'userAccountInformation','activity','sensors.custom'
)

function Invoke-PrivacyPhase {
    Write-Phase 'Privacy'

    Disable-AdvertisingAndTracking
    Disable-SuggestedContent
    Disable-InkingAndSpeech
    Disable-FeedbackRequests
    Set-AppPermissions
}

function Disable-AdvertisingAndTracking {
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 `
        -Because 'no advertising ID'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1 `
        -Because 'no advertising ID, machine-wide'

    Set-Reg 'HKCU:\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1 `
        -Because 'do not hand websites the language list'

    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' `
        'TailoredExperiencesWithDiagnosticDataEnabled' 0 -Because 'no tailored experiences'

    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'AllowOnlineTips' 0 `
        -Because 'no online tips in Settings'

    # Search: stop shipping local queries to Bing and the connected account.
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsMSACloudSearchEnabled'  0 -Because 'no cloud content search'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsAADCloudSearchEnabled'  0 -Because 'no cloud content search'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDeviceSearchHistoryEnabled' 0 -Because 'no search history'
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1 -Because 'no Bing results in Start search'
}

function Disable-SuggestedContent {
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

    # These numbered keys are how Windows addresses each individual suggestion
    # surface. There is no friendly name for them; the numbers are the API.
    $surfaces = @{
        'SubscribedContent-338389Enabled' = 'tips and suggestions'
        'SubscribedContent-338393Enabled' = 'suggestions in Settings'
        'SubscribedContent-353694Enabled' = 'suggestions in Settings'
        'SubscribedContent-353696Enabled' = 'suggestions in Settings'
        'SubscribedContent-338388Enabled' = 'occasional Start suggestions'
        'SubscribedContent-310093Enabled' = 'Windows welcome experience'
    }
    foreach ($k in $surfaces.Keys) { Set-Reg $cdm $k 0 -Because $surfaces[$k] }

    Set-Reg $cdm 'SystemPaneSuggestionsEnabled'    0 -Because 'no Start suggestions'
    Set-Reg $cdm 'SilentInstalledAppsEnabled'      0 -Because 'stop silently installing promoted apps'
    Set-Reg $cdm 'PreInstalledAppsEnabled'         0 -Because 'stop reinstalling preinstalled apps'
    Set-Reg $cdm 'OemPreInstalledAppsEnabled'      0 -Because 'stop reinstalling OEM apps'
    Set-Reg $cdm 'SoftLandingEnabled'              0 -Because 'no tips'
    Set-Reg $cdm 'RotatingLockScreenOverlayEnabled' 0 -Because 'no lock screen ads'
    Set-Reg $cdm 'ContentDeliveryAllowed'          0 -Because 'no content delivery'
    Set-Reg $cdm 'FeatureManagementEnabled'        0 -Because 'no feature nagging'
}

function Disable-InkingAndSpeech {
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection'  1 -Because 'no inking personalisation'
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1 -Because 'no typing personalisation'
    Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0 -Because 'do not harvest contacts for autocorrect'
    Set-Reg 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0 -Because 'no personalisation data collection'

    # Online speech recognition. Local dictation still works.
    Set-Reg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0 -Because 'no online speech recognition'
}

function Disable-FeedbackRequests {
    Set-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0 -Because 'never ask for feedback'
    Remove-Reg 'HKCU:\Software\Microsoft\Siuf\Rules' 'PeriodInNanoSeconds' -Because 'never ask for feedback'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1 -Because 'never ask for feedback'
}

function Set-AppPermissions {
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'

    foreach ($cap in $script:ConsentDeny) {
        if ($script:ConsentNeverTouch -contains $cap) {
            # Belt and braces: a typo in $ConsentDeny should not be able to turn
            # off someone's camera.
            Write-Log -Level WARN -Message "refusing to deny protected capability '$cap'"
            continue
        }
        Set-Reg "$root\$cap" 'Value' 'Deny' -Type String -Because "app permission: $cap off" -Tier op
    }

    foreach ($cap in $script:ConsentNeverTouch) {
        Write-Log "left alone: $cap"
    }
}
