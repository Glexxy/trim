# ---------------------------------------------------------------------------
# Phase: GPU
#
# The settings a graphics driver exposes differ enormously by vendor and by
# generation. A profile curated on one card and applied to another is at best
# useless and at worst a failed import that applies nothing at all - NVIDIA
# Profile Inspector can reject a whole profile over a single setting ID the
# driver has never heard of.
#
# So nothing here is a fixed file. The profile is composed from settings that
# declare which hardware they need, and anything the detected card cannot do is
# simply not emitted.
#
# NVIDIA gets the most, because Profile Inspector exists and drives NVAPI. AMD
# and Intel have no equivalent: their per-application settings live in an
# undocumented driver database that only their own control panel writes. What
# can be done for them honestly is a much shorter list, and this says so rather
# than pretending parity.
# ---------------------------------------------------------------------------

# Pinned by version AND by hash. This program downloads exactly one executable
# and then runs it as administrator, so "whatever is at that URL today" is not
# good enough - a compromised release, or anything sitting between us and
# GitHub, would be running with full rights on somebody else's machine.
#
# The previous value here was 2.4.0.14, which does not exist. Every download
# 404'd and the NVIDIA profile silently never applied on any machine. Verified
# against the releases API on 4 September 2026.
#
# To move to a new release: change the version, download it, and put its real
# SHA256 here. Never relax the check to make an upgrade easier.
$script:NpiVersion = 'v3.0.2.1'
$script:NpiUrl     = "https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/$($script:NpiVersion)/nvidiaProfileInspector.zip"
$script:NpiSha256  = '88DCF3514111E8DE630688467C03C36D8C2A8AD9EBC8073F27C069F82B75BB40'
$script:NpiBytes   = 433354

# ---------------------------------------------------------------------------
#  Capability detection
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Work out what this NVIDIA card can actually do.

.DESCRIPTION
    Feature availability tracks the architecture, and the marketing name is the
    only thing reliably readable without NVAPI:

      GTX 9xx / 10xx      Maxwell, Pascal   - no DLSS at all
      GTX 16xx            Turing, no RT     - no DLSS
      RTX 20xx / 30xx     Turing, Ampere    - DLSS super resolution and ray reconstruction
      RTX 40xx            Ada               - adds frame generation
      RTX 50xx            Blackwell         - adds multi-frame generation

    Unknown or professional cards fall back to the conservative set: everything
    that has existed since Maxwell, and nothing that has not.
#>
function Get-NvidiaCapability {
    param([Parameter(Mandatory)][string[]]$GpuNames)

    $name = @($GpuNames | Where-Object { $_ -match 'NVIDIA|GeForce|Quadro|RTX|GTX' })[0]
    if (-not $name) { return $null }

    $gen = 'unknown'
    if     ($name -match 'RTX\s*50\d\d')            { $gen = 'blackwell' }
    elseif ($name -match 'RTX\s*40\d\d')            { $gen = 'ada' }
    elseif ($name -match 'RTX\s*30\d\d')            { $gen = 'ampere' }
    elseif ($name -match 'RTX\s*20\d\d|RTX\s*T\d')  { $gen = 'turing' }
    elseif ($name -match 'GTX\s*16\d\d')            { $gen = 'turing-nort' }
    elseif ($name -match 'GTX\s*10\d\d')            { $gen = 'pascal' }
    elseif ($name -match 'GTX\s*9\d\d')             { $gen = 'maxwell' }
    elseif ($name -match 'RTX\s*A\d|RTX\s*\d{4}\s*Ada') { $gen = 'ampere' }   # professional boards

    $dlss = $gen -in @('turing','ampere','ada','blackwell')
    return [pscustomobject]@{
        Name          = $name
        Generation    = $gen
        HasDlss       = $dlss
        HasFrameGen   = $gen -in @('ada','blackwell')
        HasMultiFrame = ($gen -eq 'blackwell')
        # Reflex / low latency landed on Maxwell and later, which is every card
        # a current driver still supports.
        HasLowLatency = ($gen -ne 'unknown')
    }
}

<#
.SYNOPSIS
    The NVIDIA settings worth applying, each declaring what it needs.

.DESCRIPTION
    Id is the NVAPI setting id Profile Inspector writes. Needs is checked against
    the detected capability; a setting whose requirement is not met is never
    emitted, which is what stops an unknown id failing the whole import.
#>
function Get-NvidiaSettings {
    param([Parameter(Mandatory)]$Cap, [Parameter(Mandatory)]$Facts, [int]$FrameLimit = 0)

    $s = [System.Collections.Generic.List[object]]::new()
    function Add-S {
        param([int]$Id, [string]$Name, $Value, [string]$Needs = 'always')
        $s.Add([pscustomobject]@{ Id = $Id; Name = $Name; Value = $Value; Needs = $Needs }) | Out-Null
    }

    # --- Universal: every NVIDIA card a current driver supports -------------
    Add-S 13510289  'Texture filtering - Quality'                          10
    Add-S 1686376   'Texture filtering - Negative LOD bias'                0
    Add-S 3066610   'Texture filtering - Trilinear optimization'           0
    Add-S 8703344   'Texture filtering - Anisotropic filter optimization'  1
    Add-S 15151633  'Texture filtering - Anisotropic sample optimization'  1
    Add-S 270426537 'Anisotropic filtering setting'                        1
    Add-S 282245910 'Anisotropic filtering mode'                           1
    Add-S 276757595 'Antialiasing - Mode'                                  1
    Add-S 282555346 'Antialiasing - Setting'                               0
    Add-S 282364549 'Antialiasing - Transparency Supersampling'            0
    Add-S 276089202 'Enable FXAA'                                          0
    Add-S 10011052  'Enable sample interleaving (MFAA)'                    0
    Add-S 6714153   'Ambient Occlusion'                                    0
    Add-S 11041231  'Vertical Sync'                                        138504007
    Add-S 5912412   'Vertical Sync Tear Control'                           2525368439
    Add-S 553505273 'Triple buffering'                                     0
    Add-S 6600001   'Preferred refresh rate'                               1
    Add-S 8102046   'Maximum pre-rendered frames'                          0
    Add-S 11306135  'Shader disk cache maximum size'                       16384
    Add-S 283962569 'CUDA Sysmem Fallback Policy'                          0
    Add-S 543959236 'Enable overlay'                                       0
    Add-S 272979126 'Application Profile Notification Popup Timeout'       0
    Add-S 5867816   'Sharpening Filter'                                    0
    Add-S 3070157   'Sharpening Value'                                     50
    Add-S 3070158   'Sharpening - Denoising Factor'                        17
    Add-S 549528094 'Threaded optimization'                                2

    # Variable refresh rate. Harmless to assert on a card without a G-SYNC
    # display: the driver ignores it.
    Add-S 278196567 'Toggle the VRR global feature'                        1
    Add-S 278196727 'VRR requested state'                                  1
    Add-S 279476686 'Variable refresh Rate'                                1
    Add-S 294973784 'Enable G-SYNC globally'                               2

    # --- Desktop only: pinning clocks high is a battery decision -----------
    if (-not $Facts.IsLaptop) {
        Add-S 274197361 'Power management mode' 1
    }

    # --- Frame limiter, derived from this display --------------------------
    if ($FrameLimit -gt 0) {
        Add-S 277041154 'Frame Rate Limiter'          $FrameLimit
        Add-S 277041162 'Frame Rate Limiter for NVCPL' $FrameLimit
        Add-S 277041150 'Platform Boost'               1
    }

    # --- Low latency -------------------------------------------------------
    if ($Cap.HasLowLatency) {
        Add-S 390467    'Low Latency Mode' 0 'lowlatency'
    }

    # --- DLSS: Turing and later only ---------------------------------------
    if ($Cap.HasDlss) {
        Add-S 283385345 'Enable DLSS-SR override'            1            'dlss'
        Add-S 283385346 'Enable DLSS-RR override'            1            'dlss'
        Add-S 283385350 'Enable Streamline override'         1            'dlss'
        Add-S 283385331 'Override DLSS-SR presets'           16777215     'dlss'
        Add-S 283385335 'Override DLSS-RR preset'            16777215     'dlss'
        Add-S 279951208 'Override DLSS-SR performance mode'  3            'dlss'
        Add-S 280859683 'Override DLSS-RR performance mode'  3            'dlss'
        Add-S 6505105   'DLSS Model Preset Profile'          1            'dlss'
    }

    # --- Frame Generation: Ada and later -----------------------------------
    if ($Cap.HasFrameGen) {
        Add-S 283385347 'Enable DLSS-FG override' 1        'framegen'
        Add-S 283385329 'Override DLSS-FG preset' 16777214 'framegen'
    }

    # --- Multi-Frame Generation: Blackwell ---------------------------------
    if ($Cap.HasMultiFrame) {
        Add-S 273507943 'Override DLSSG multi-frame count' 0 'multiframe'
    }

    return @($s)
}

function ConvertTo-NipXml {
    param([Parameter(Mandatory)]$Settings)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<?xml version="1.0" encoding="utf-16"?>')
    [void]$sb.AppendLine('<ArrayOfProfile>')
    [void]$sb.AppendLine('  <Profile>')
    [void]$sb.AppendLine('    <ProfileName>Base Profile</ProfileName>')
    [void]$sb.AppendLine('    <Executeables />')
    [void]$sb.AppendLine('    <Settings>')
    foreach ($s in $Settings) {
        [void]$sb.AppendLine('      <ProfileSetting>')
        [void]$sb.AppendLine("        <SettingNameInfo>$([Security.SecurityElement]::Escape($s.Name))</SettingNameInfo>")
        [void]$sb.AppendLine("        <SettingID>$($s.Id)</SettingID>")
        [void]$sb.AppendLine("        <SettingValue>$($s.Value)</SettingValue>")
        [void]$sb.AppendLine('        <ValueType>Dword</ValueType>')
        [void]$sb.AppendLine('      </ProfileSetting>')
    }
    [void]$sb.AppendLine('    </Settings>')
    [void]$sb.AppendLine('  </Profile>')
    [void]$sb.AppendLine('</ArrayOfProfile>')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
#  Phase entry
# ---------------------------------------------------------------------------

function Invoke-GpuPhase {
    param(
        [Parameter(Mandatory)]$Facts,
        [string]$ProfileOverride = ''
    )
    Write-Phase 'Graphics'

    if (@($Facts.GpuVendors).Count -eq 0) {
        Write-Log "No recognised graphics vendor in: $($Facts.GpuNames -join ', '). Skipping."
        return
    }

    if ($Facts.GpuVendors -contains 'NVIDIA') { Invoke-NvidiaTuning -Facts $Facts -ProfileOverride $ProfileOverride }
    if ($Facts.GpuVendors -contains 'AMD')    { Invoke-AmdTuning    -Facts $Facts }
    if ($Facts.GpuVendors -contains 'Intel')  { Invoke-IntelTuning  -Facts $Facts }
}

function Invoke-NvidiaTuning {
    param([Parameter(Mandatory)]$Facts, [string]$ProfileOverride = '')

    $cap = Get-NvidiaCapability -GpuNames $Facts.GpuNames
    if (-not $cap) { return }

    Write-Log "NVIDIA: $($cap.Name)"
    Write-Log "  Architecture      : $($cap.Generation)"
    Write-Log "  DLSS              : $(if ($cap.HasDlss) { 'yes' } else { 'no - those settings are omitted' })"
    Write-Log "  Frame Generation  : $(if ($cap.HasFrameGen) { 'yes' } else { 'no' })"
    Write-Log "  Multi-Frame Gen   : $(if ($cap.HasMultiFrame) { 'yes' } else { 'no' })"
    if ($cap.Generation -eq 'unknown') {
        Write-Log -Level WARN -Message '  Card not recognised. Using only settings that have existed since Maxwell.'
    }

    Install-NvidiaControlPanel

    $limit = 0
    if ($Facts.RefreshRate -ge 30) {
        $limit = [Math]::Max(30, $Facts.RefreshRate - 3)
        Write-Log "  Frame limiter     : $limit fps (display reports $($Facts.RefreshRate) Hz)"
    } else {
        Write-Log -Level WARN -Message '  Could not read a refresh rate; leaving the frame limiter off.'
    }

    $xml = $null
    if ($ProfileOverride) {
        try {
            $xml = if ($ProfileOverride -match '^https?://') {
                (Invoke-WebRequest -Uri $ProfileOverride -UseBasicParsing).Content
            } else { Get-Content -Raw -LiteralPath $ProfileOverride }
            Write-Log "  Using the supplied profile: $ProfileOverride"
        } catch {
            Write-Log -Level FAIL -Message "Could not read '$ProfileOverride': $($_.Exception.Message)"
            return
        }
    } else {
        $settings = Get-NvidiaSettings -Cap $cap -Facts $Facts -FrameLimit $limit
        Write-Log "  Composing a profile of $($settings.Count) setting(s) for this card."
        $xml = ConvertTo-NipXml -Settings $settings
    }

    Add-PlannedAction -Kind 'external' -Target 'NVIDIA global profile import' `
        -Detail "$($cap.Generation) profile via nvidiaProfileInspector; previous settings exported first" `
        -Reversible 'yes - previous profile exported first' -Tier op

    if (-not (Test-SelectedChange 'act|external|NVIDIA global profile import')) {
        Write-Log '  Profile import not selected. Skipping.'
        return
    }

    $out = Join-Path $script:RunRoot "nvidia\profile_$($script:RunStamp).nip"
    if ($DryRun) {
        Write-Log -Level DRY -Message "would write $out and import it"
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
    # Profile Inspector expects UTF-16 to match the declaration.
    [System.IO.File]::WriteAllText($out, $xml, [System.Text.Encoding]::Unicode)
    Write-Log -Level OK -Message "NVIDIA profile written: $out"
    Import-NvidiaProfile -NipPath $out
}

<#
.SYNOPSIS
    What can honestly be done for a Radeon card.

.DESCRIPTION
    AMD has no Profile Inspector. Per-application settings live in a driver
    database that only Adrenalin writes, with no documented format and no CLI,
    so there is no equivalent of the NVIDIA profile import and pretending
    otherwise would be worse than saying so.

    What is reachable is the driver's own class key, plus the Radeon Software
    telemetry and nag settings. Everything that changes power behaviour is
    desktop-only and opinionated, because on a laptop it costs battery.
#>
function Invoke-AmdTuning {
    param([Parameter(Mandatory)]$Facts)

    $key = Get-GpuClassKey -Match 'Radeon|AMD'
    Write-Log "AMD: $((@($Facts.GpuNames | Where-Object { $_ -match 'Radeon|AMD' })) -join ', ')"

    # Radeon Software's own telemetry and upsell, which are plain registry values.
    Set-Reg 'HKLM:\SOFTWARE\AMD\CN' 'AllowSubscription' 0 -Because 'Radeon Software: no subscription prompts'
    Set-Reg 'HKLM:\SOFTWARE\AMD\CN' 'AutoUpdateTriggered' 0 -Because 'Radeon Software: no automatic update prompts'
    Set-Reg 'HKLM:\SOFTWARE\AMD\CN' 'ShowToastNotifications' 0 -Because 'Radeon Software: no toast notifications'
    Set-Reg 'HKLM:\SOFTWARE\AMD\CN' 'SkipMandatoryUpdates' 0 -Because 'Radeon Software: leave mandatory updates alone'

    if (-not $key) {
        Write-Log -Level WARN -Message '  Could not find the Radeon driver class key. Skipping driver-level settings.'
    } elseif ($Facts.IsLaptop) {
        Write-Log '  Laptop: leaving the driver power settings alone. They are worth real battery life.'
    } else {
        # ULPS parks the card in a very low power state. On a desktop it buys
        # almost nothing and is a long-standing cause of stutter on wake, but it
        # is a power setting, so it is opinionated rather than safe.
        Set-Reg $key 'EnableUlps' 0 -Because 'AMD: no ultra low power state on a desktop' -Tier op
        Set-Reg $key 'PP_SclkDeepSleepDisable' 1 -Because 'AMD: no shader clock deep sleep on a desktop' -Tier op
    }

    Write-Log '  Per-game settings must be set in AMD Software: Adrenalin Edition.'
    Write-Log '  There is no supported way to write them from a script, and Trim will not guess at the format.'
}

function Invoke-IntelTuning {
    param([Parameter(Mandatory)]$Facts)
    $names = @($Facts.GpuNames | Where-Object { $_ -match 'Intel|Arc|UHD|Iris' })
    Write-Log "Intel: $($names -join ', ')"
    Write-Log '  No supported command line exists for Intel Graphics Software settings.'
    Write-Log '  The Windows-level graphics work (per-application GPU preference, hardware'
    Write-Log '  scheduling, windowed optimisations) applies to this card and is done elsewhere.'
}

<#
.SYNOPSIS
    The display adapter's driver registry key.

.DESCRIPTION
    Adapters live under the display class GUID numbered 0000, 0001 and so on.
    On a hybrid machine the wrong one is a real possibility, so the DriverDesc
    is matched rather than assuming 0000.
#>
function Get-GpuClassKey {
    param([Parameter(Mandatory)][string]$Match)
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    foreach ($sub in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
                      Where-Object { $_.PSChildName -match '^\d{4}$' })) {
        try {
            $desc = (Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop).DriverDesc
            if ("$desc" -match $Match) { return $sub.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE', 'HKLM:' }
        } catch { }
    }
    return $null
}

function Install-NvidiaControlPanel {
    $present = @(Get-AppxPackage -Name 'NVIDIACorp.NVIDIAControlPanel' -ErrorAction SilentlyContinue)
    if ($present.Count -gt 0) { Write-Log '  Control Panel already installed.'; return }

    Add-PlannedAction -Kind 'feature' -Target 'NVIDIA Control Panel (winget msstore 9NF8H0H7WMLT)' `
        -Detail 'only when missing' -Reversible 'uninstall via Settings'
    if ($DryRun) { Write-Log -Level DRY -Message '  would install NVIDIA Control Panel via winget'; return }
    if (-not (Test-SelectedChange 'act|feature|NVIDIA Control Panel (winget msstore 9NF8H0H7WMLT)')) { return }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log -Level WARN -Message '  Control Panel missing and winget unavailable. Install it from the Store.'
        return
    }
    try {
        & (Get-SystemTool 'winget.exe') install --id 9NF8H0H7WMLT --source msstore --accept-package-agreements --accept-source-agreements --silent 2>&1 |
            ForEach-Object { Write-Log $_ }
        Write-Log -Level OK -Message '  Control Panel install attempted.'
    } catch {
        Write-Log -Level WARN -Message "  Control Panel install failed: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Run Profile Inspector, and give up on it if it will not come back.

.DESCRIPTION
    Both calls to this tool used to block with no bound - one through the call
    operator, one through Start-Process -Wait. That is fine while the driver
    answers. It is not fine when the machine only looks like it has an NVIDIA
    card.

    Windows Sandbox passes the host's adapter name straight through, so this
    ran on a machine reporting an RTX 5070 Ti with no working NVAPI behind it.
    The export took two minutes and failed; the import never returned at all.
    The run was still sitting there fourteen minutes later, and nothing would
    ever have ended it.

    The same shape exists outside a sandbox: a GPU-P virtual machine, a remote
    desktop session, safe mode, or a driver update caught half way through. A
    stranger who ran the one-liner in any of those would watch it hang with no
    indication of why.

    A profile that cannot be applied is a disappointment. A run that never
    finishes is somebody force-killing a program that is midway through
    changing their machine.
#>
function Invoke-ProfileInspector {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 120
    )

    $p = $null
    try {
        $p = Start-Process -FilePath $Tool -ArgumentList $Arguments -PassThru -WindowStyle Hidden -ErrorAction Stop
    } catch {
        Write-Log -Level WARN -Message "  Could not start Profile Inspector: $($_.Exception.Message)"
        return $null
    }

    if ($p.WaitForExit($TimeoutSeconds * 1000)) { return $p.ExitCode }

    Write-Log -Level WARN -Message "  Profile Inspector did not respond within $TimeoutSeconds s. The graphics driver is not answering."
    Write-Log -Level WARN -Message '  Stopping it and carrying on. No NVIDIA settings were changed.'
    try { $p.Kill(); $p.WaitForExit(5000) | Out-Null } catch { }
    return $null
}

function Import-NvidiaProfile {
    param([Parameter(Mandatory)][string]$NipPath)

    $tool = Get-ProfileInspector
    if (-not $tool) { return }

    try {
        $backup = Join-Path $script:RunRoot "nvidia\before_$($script:RunStamp).nip"
        $null = Invoke-ProfileInspector -Tool $tool -Arguments @('-exportCustomized')
        $exported = Get-ChildItem -LiteralPath (Split-Path $tool) -Filter '*.nip' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($exported) {
            Move-Item -LiteralPath $exported.FullName -Destination $backup -Force
            Write-Log -Level OK -Message "  Previous NVIDIA settings saved to: $backup"
            Write-Log "  Restore them with: `"$tool`" -silentImport `"$backup`""
        } else {
            Write-Log -Level WARN -Message '  Could not export the existing profile. Importing without a profile-level backup.'
        }
    } catch {
        Write-Log -Level WARN -Message "  Profile backup failed: $($_.Exception.Message)"
    }

    try {
        $code = Invoke-ProfileInspector -Tool $tool -Arguments @('-silentImport', "`"$NipPath`"")
        if ($null -eq $code)      { }   # already reported: it was stopped, nothing was changed
        elseif ($code -eq 0)      { Write-Log -Level OK -Message '  NVIDIA profile imported.' }
        else                      { Write-Log -Level WARN -Message "  Profile Inspector exited with code $code." }
    } catch {
        Write-Log -Level FAIL -Message "  Profile import failed: $($_.Exception.Message)"
    }
}

function Get-ProfileInspector {
    $dir = Join-Path $script:RunRoot 'tools\nvidiaProfileInspector'
    $exe = Join-Path $dir 'nvidiaProfileInspector.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
    if ($DryRun) {
        Write-Log -Level DRY -Message "  would download NVIDIA Profile Inspector $($script:NpiVersion) from $($script:NpiUrl)"
        return $null
    }

    Write-Log "  Downloading NVIDIA Profile Inspector $($script:NpiVersion) from $($script:NpiUrl)"
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $zip = Join-Path $dir 'npi.zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $script:NpiUrl -OutFile $zip -UseBasicParsing -ErrorAction Stop

        # Verify before extracting, never after. An archive that does not match
        # is not unpacked, not run, and not kept.
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        $size   = (Get-Item -LiteralPath $zip).Length
        if ($actual -ne $script:NpiSha256 -or $size -ne $script:NpiBytes) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Write-Log -Level FAIL -Message 'The downloaded NVIDIA Profile Inspector does not match its expected fingerprint.'
            Write-Log -Level FAIL -Message "  expected SHA256 $($script:NpiSha256) ($($script:NpiBytes) bytes)"
            Write-Log -Level FAIL -Message "  received SHA256 $actual ($size bytes)"
            Write-Log -Level FAIL -Message '  Refusing to run it. The NVIDIA profile will not be applied.'
            return $null
        }
        Write-Log -Level OK -Message '  Download verified against its pinned SHA256.'

        Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $exe) { return $exe }
        $found = Get-ChildItem -LiteralPath $dir -Filter 'nvidiaProfileInspector.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
        Write-Log -Level FAIL -Message '  Profile Inspector executable not found after extraction.'
        return $null
    } catch {
        Write-Log -Level FAIL -Message "  Could not obtain Profile Inspector: $($_.Exception.Message)"
        return $null
    }
}
