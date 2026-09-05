#Requires -Version 5.1
<#
.SYNOPSIS
    Drives the window without a human: presets, navigation, and checkbox clicks.

.DESCRIPTION
    The first build of the interface crashed the moment anything was clicked,
    and a screenshot could not have caught that. This builds the real window,
    fires the real event handlers, and asserts the state afterwards - without
    ever showing it.

    Host-safe: nothing is applied, the window is never displayed, and the whole
    run happens against a dry-run manifest.

    Must run STA:
        powershell.exe -STA -File test\Test-GuiInteraction.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'Re-run with -STA. WPF cannot be constructed on an MTA thread.' -ForegroundColor Red
    exit 2
}

$root = Split-Path $PSScriptRoot -Parent

$DryRun = $true; $Skip = @(); $Only = @(); $NoRestorePoint = $true; $Aggressive = $false
$WinUtilConfigUrl = Join-Path $root 'config\winutil-tweaks.json'
$NvidiaProfile = ''; $DisableMemoryIntegrity = $false; $Gui = $false; $ApplySelection = ''; $NoRestartPrompt = $true
$Cleanup = $false; $IncludeDuplicates = $false; $CleanupSelection = ''

foreach ($f in (Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1' | Sort-Object Name)) {
    if ($f.Name -in @('01-header.ps1','99-main.ps1')) { continue }
    . $f.FullName
}
# The NVIDIA profile is composed per card in 11-gpu.ps1; there is no asset.

$failures = [System.Collections.Generic.List[string]]::new()
function Check {
    param([string]$What, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS  $What" -ForegroundColor Green
    } catch {
        Write-Host "FAIL  $What" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add($What) | Out-Null
    }
}

Write-Host ''
Write-Host 'Trim - window interaction test' -ForegroundColor Cyan
Write-Host ''

# Build a real manifest, exactly as -Gui does.
$facts = Get-MachineFacts
Invoke-GamingPhase -Facts $facts
Invoke-PrivacyPhase
Invoke-AppxPhase
Invoke-NetworkPhase -Facts $facts
Invoke-PersonalisationPhase
$items = Get-GuiItems -Ledger $script:Ledger -Actions $script:Actions

# Force a trade-off into the set so the tier logic is exercised even on a
# machine that has nothing to trade off.
$items = @($items) + @([pscustomobject]@{
    Key = 'act|command|Disable Memory Integrity (HVCI)'; Kind = 'command'
    Phase = 'Security'; Title = 'Disable Memory Integrity (HVCI)'
    Detail = 'synthetic, for the test'; Tier = 'trade'; Selected = $false
})
Write-Host "manifest: $($items.Count) items across $((@($items | Select-Object -ExpandProperty Phase -Unique)).Count) phases"

Check 'window builds' {
    $w = Initialize-TrimWindow -Items $items -Facts $facts -AlreadyCorrect 39
    $script:GuiScanning = $false
    if (-not $w) { throw 'Initialize-TrimWindow returned nothing' }
    if ($script:GuiCurrent -ne 'Overview') { throw "opened on '$($script:GuiCurrent)', expected Overview" }
}

Check 'opens on Recommended, not everything ticked' {
    if ($script:GuiPreset -ne 'recommended') { throw "preset is '$($script:GuiPreset)'" }
    $notSafe = @($script:GuiItems | Where-Object { $_.Selected -and $_.Tier -ne 'safe' }).Count
    if ($notSafe) { throw "$notSafe item(s) that are not Safe were ticked on open" }
    $safeOff = @($script:GuiItems | Where-Object { $_.Tier -eq 'safe' -and -not $_.Selected }).Count
    if ($safeOff) { throw "$safeOff safe item(s) were NOT ticked on open" }
}

Check 'every preset applies without throwing' {
    foreach ($p in @('recommended','advanced','everything','none')) {
        Set-GuiPreset $p
        $on = @($script:GuiItems | Where-Object { $_.Selected }).Count
        switch ($p) {
            'advanced' {
                $bad = @($script:GuiItems | Where-Object { $_.Selected -and $_.Tier -eq 'trade' }).Count
                if ($bad) { throw "Advanced selected $bad risky item(s)" }
            }
            'none' { if ($on -ne 0) { throw "Clear left $on selected" } }
            'recommended' {
                $bad = @($script:GuiItems | Where-Object { $_.Selected -and $_.Tier -ne 'safe' }).Count
                if ($bad) { throw "Recommended selected $bad item(s) that are not Safe" }
            }
            'everything' {
                $missed = @($script:GuiItems | Where-Object { -not $_.Selected }).Count
                if ($missed) { throw "Everything left $missed item(s) unselected" }
            }
        }
    }
    Set-GuiPreset 'recommended'
}

Check 'Apply button disables when nothing is selected' {
    Set-GuiPreset 'none'
    if ($script:GuiUi.BtnApply.IsEnabled) { throw 'Apply still enabled with nothing selected' }
    Set-GuiPreset 'recommended'
    if (-not $script:GuiUi.BtnApply.IsEnabled) { throw 'Apply disabled with items selected' }
}

Check 'navigating to every phase renders' {
    foreach ($p in (@('Overview') + $script:GuiPhases + @('Disk cleanup','Startup apps','Uninstall apps'))) {
        Set-GuiPhase $p
        if ($script:GuiCurrent -ne $p) { throw "phase did not change to '$p'" }
        if ($script:GuiUi.PanelItems.Children.Count -eq 0) { throw "'$p' rendered no rows" }
    }
}

# The exact thing that crashed: clicking a checkbox inside the list.
Check 'clicking a checkbox does not tear down the list' {
    $phase = @($script:GuiPhases | Where-Object { $_ -ne 'Security' })[0]
    Set-GuiPhase $phase
    $rows = @($script:GuiUi.PanelItems.Children)
    if ($rows.Count -eq 0) { throw 'no rows to click' }

    # Found by walking the row rather than by position. The checkbox used to be
    # the first child of the row's grid; it is now nested one level deeper,
    # inside a wrapper that also holds the tier edge. Asserting a position makes
    # the test fail on a layout change that broke nothing.
    function Find-CheckBox {
        param($Element)
        if ($Element -is [Windows.Controls.CheckBox]) { return $Element }
        $kids = $null
        if ($Element -is [Windows.Controls.Panel])          { $kids = $Element.Children }
        elseif ($Element -is [Windows.Controls.Decorator])  { $kids = @($Element.Child) }
        elseif ($Element -is [Windows.Controls.ContentControl]) { $kids = @($Element.Content) }
        foreach ($k in @($kids)) {
            if ($null -eq $k) { continue }
            $hit = Find-CheckBox -Element $k
            if ($hit) { return $hit }
        }
        return $null
    }

    $before = @($script:GuiItems | Where-Object { $_.Selected }).Count
    for ($n = 0; $n -lt [Math]::Min(6, $rows.Count); $n++) {
        $cb = Find-CheckBox -Element $rows[$n]
        if ($null -eq $cb) { throw "row $n contains no checkbox" }
        $cb.IsChecked = -not $cb.IsChecked
        # Fire the real handler the same way a click does.
        $cb.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        if ($script:GuiUi.PanelItems.Children.Count -ne $rows.Count) {
            throw 'the list was rebuilt from inside a checkbox handler'
        }
    }
    $after = @($script:GuiItems | Where-Object { $_.Selected }).Count
    if ($after -eq $before) { throw 'ticking boxes changed no state' }
}

Check 'trade-off banner appears only when one is selected' {
    Set-GuiPreset 'recommended'
    if ($script:GuiUi.BannerBox.Visibility -ne 'Collapsed') { throw 'banner visible with no trade-off selected' }
    $t = @($script:GuiItems | Where-Object { $_.Tier -eq 'trade' })[0]
    $t.Selected = $true
    Update-GuiCounts
    if ($script:GuiUi.BannerBox.Visibility -ne 'Visible') { throw 'banner hidden with a trade-off selected' }
    $t.Selected = $false
    Update-GuiCounts
}

Check 'sidebar counts track the selection' {
    Set-GuiPreset 'none'
    Set-GuiPhase 'Overview'
    foreach ($child in $script:GuiUi.PanelPhases.Children) {
        # Overview and Disk cleanup are not part of the preset flow, so they
        # correctly carry no selected/total count.
        if (-not $child.Tag -or $child.Tag -in @('Overview','Disk cleanup','Startup apps','Uninstall apps')) { continue }
        $txt = $child.Content.Children[1].Text
        if ($txt -notmatch '^0/\d+$') { throw "'$($child.Tag)' shows '$txt' after Clear" }
    }
    Set-GuiPreset 'recommended'
}

# Cleanup must never be reachable through the preset flow - a preset that
# deletes files is exactly what this tool promises not to be.
Check 'presets never select anything in the cleanup pane' {
    foreach ($p in @('recommended','advanced','everything')) {
        Set-GuiPreset $p
        $leaked = @($script:GuiItems | Where-Object { $_.Key -like 'clean|*' -or $_.Key -like 'dupe|*' }).Count
        if ($leaked) { throw "preset '$p' reached $leaked cleanup item(s)" }
    }
    Set-GuiPreset 'recommended'
}

Check 'cleanup pane opens without having scanned' {
    Set-GuiPhase 'Disk cleanup'
    if ($script:GuiCleanScanned) { throw 'the pane scanned on its own; it must wait to be asked' }
    if ($script:GuiUi.PanelItems.Children.Count -eq 0) { throw 'the cleanup pane rendered nothing' }
}

Check 'machine spec grid renders and copies' {
    Set-GuiPhase 'Overview'
    $rows = Get-MachineSpecRows -Facts $facts
    foreach ($required in @('Operating system','Form factor','Model','Memory','Graphics')) {
        if (-not $rows.Contains($required)) { throw "the spec grid has no '$required' row" }
        if (-not "$($rows[$required])".Trim()) { throw "'$required' is empty" }
    }
    # The clipboard text has to be readable on its own, away from the window.
    $width = ($rows.Keys | Measure-Object -Property Length -Maximum).Maximum
    $lines = foreach ($k in $rows.Keys) { "{0}  {1}" -f $k.PadRight($width), ("$($rows[$k])" -split [Environment]::NewLine)[0] }
    if (@($lines).Count -lt 5) { throw 'the copied specification is suspiciously short' }
    if (($lines -join "`n") -notmatch 'Windows') { throw 'the copied specification does not name the OS' }
}

Check 'tier labels read as instructions, not opinions' {
    if ($script:GuiTierName['op'] -eq 'OPINIONATED') { throw 'the middle tier is still called Opinionated' }
    foreach ($k in @('safe','op','trade')) {
        if (-not $script:GuiTierName[$k]) { throw "tier '$k' has no label" }
        if (-not $script:GuiTierWhy[$k])  { throw "tier '$k' has no explanation" }
        if ($script:GuiTierName[$k].Length -gt 10) { throw "tier label '$($script:GuiTierName[$k])' is too long for the chip" }
    }
}

Check 'progress window builds and reports' {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [xml]$px = $script:ProgXaml
    $pw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $px))
    foreach ($n in @('ProgBar','ProgStatus','ProgCount','ProgClose','ProgTitle','ProgSub')) {
        if (-not $pw.FindName($n)) { throw "the progress window has no '$n'" }
    }

    # The hook is what turns a registry write into a line somebody can read.
    $seen = [System.Collections.Generic.List[object]]::new()
    $script:ProgressHook = { param($pct, $text) $seen.Add(@{ Pct = $pct; Text = $text }) | Out-Null }
    Set-ProgressTotal -Total 4
    Step-Progress -Status 'Game Bar off'
    Step-Progress -Status 'Captures off'
    $script:ProgressHook = $null

    if ($seen.Count -ne 2)        { throw "hook fired $($seen.Count) time(s), expected 2" }
    if ($seen[0].Pct -ne 25)      { throw "first step reported $($seen[0].Pct)%, expected 25" }
    if ($seen[1].Pct -ne 50)      { throw "second step reported $($seen[1].Pct)%, expected 50" }
    if ($seen[1].Text -ne 'Captures off') { throw "status was '$($seen[1].Text)'" }
    # A status line naming a registry path is a leak of the implementation.
    foreach ($e in $seen) { if ($e.Text -match 'HK(CU|LM):') { throw "status line shows a registry path: $($e.Text)" } }
    # The Close button must not look pressable while work is still running.
    $pc = $pw.FindName('ProgClose')
    if ($pc.IsEnabled) { throw 'the progress window opens with Close already enabled' }
    $pw.Close()
}

# The window has to be usable before the scan finishes, or the point of opening
# it first is lost.
Check 'scanning state renders without a plan' {
    $script:GuiScanning = $true
    $keptItems = $script:GuiItems
    $script:GuiItems = @()
    Set-GuiPhase 'Overview'
    if ($script:GuiUi.PanelItems.Children.Count -eq 0) { throw 'the scanning state rendered nothing' }
    $script:GuiScanning = $false
    $script:GuiItems = $keptItems
    Set-GuiPhase 'Overview'
}

Check 'uninstall pane opens without listing anything' {
    Set-GuiPhase 'Uninstall apps'
    if ($script:GuiAppsLoaded) { throw 'the pane enumerated applications on its own; it must wait to be asked' }
    if ($script:GuiUninstallStage -ne 'list') { throw "the pane opened in stage '$($script:GuiUninstallStage)'" }
    if ($script:GuiUi.PanelItems.Children.Count -eq 0) { throw 'the uninstall pane rendered nothing' }
}

Check 'startup pane opens without reading anything' {
    Set-GuiPhase 'Startup apps'
    if ($script:GuiStartupLoaded) { throw 'the pane enumerated startup items on its own; it must wait to be asked' }
    if ($script:GuiUi.PanelItems.Children.Count -eq 0) { throw 'the startup pane rendered nothing' }
}

Check 'startup pane renders a row per item once asked' {
    # Drive the real render with a known list rather than whatever this machine
    # happens to run at logon, so the assertion means the same thing anywhere.
    $script:GuiStartupItems = @(
        [pscustomobject]@{ Name='Enabled thing'; Command='C:\a.exe'; Publisher='Contoso'
                           Source='Registry'; Scope='You'; Location='HKCU:\x'; Approved='HKCU:\y'
                           State='Enabled'; CanChange=$true },
        [pscustomobject]@{ Name='Disabled thing'; Command='C:\b.exe'; Publisher=''
                           Source='Startup folder'; Scope='You'; Location='C:\s'; Approved=''
                           State='Disabled'; CanChange=$true },
        [pscustomobject]@{ Name='A task'; Command='C:\c.exe'; Publisher=''
                           Source='Scheduled task'; Scope='All users'; Location='\T'; Approved=''
                           State='Enabled'; CanChange=$false }
    )
    $script:GuiStartupLoaded = $true
    Set-GuiPhase 'Startup apps'

    if ($script:GuiUi.PanelItems.Children.Count -ne 3) {
        throw "expected 3 rows, rendered $($script:GuiUi.PanelItems.Children.Count)"
    }
    if ($script:GuiUi.TxtPhaseSub.Text -ne '2 of 3 enabled') {
        throw "counter reads '$($script:GuiUi.TxtPhaseSub.Text)'"
    }

    # The scheduled task must not offer a button that cannot work.
    $rows = @($script:GuiUi.PanelItems.Children)
    $buttons = @($rows | ForEach-Object { @($_.Child.Children | Where-Object { $_ -is [Windows.Controls.Button] }) })
    if ($buttons.Count -ne 2) { throw "expected 2 toggle buttons, found $($buttons.Count)" }

    $script:GuiStartupLoaded = $false
    $script:GuiStartupItems  = @()
}

Check 'presets never reach uninstall or cleanup items' {
    foreach ($p in @('recommended','advanced','everything')) {
        Set-GuiPreset $p
        $leaked = @($script:GuiItems | Where-Object {
            $_.Key -like 'clean|*' -or $_.Key -like 'dupe|*' -or $_.Key -like 'left|*' }).Count
        if ($leaked) { throw "preset '$p' reached $leaked destructive item(s)" }
    }
    Set-GuiPreset 'recommended'
}

Check 'the three presets select three different sets' {
    # They used to overlap into uselessness: Recommended ticked everything there
    # was, and Aggressive matched it exactly.
    Set-GuiPreset 'recommended'; $rec = @($script:GuiItems | Where-Object { $_.Selected }).Count
    Set-GuiPreset 'advanced';    $adv = @($script:GuiItems | Where-Object { $_.Selected }).Count
    Set-GuiPreset 'everything';  $all = @($script:GuiItems | Where-Object { $_.Selected }).Count

    if ($rec -ge $adv) { throw "Recommended ($rec) is not a strict subset of Advanced ($adv)" }
    if ($adv -ge $all) { throw "Advanced ($adv) is not a strict subset of Everything ($all)" }
    if ($all -ne $script:GuiItems.Count) { throw 'Everything did not select everything' }

    Set-GuiPreset 'recommended'
    $notSafe = @($script:GuiItems | Where-Object { $_.Selected -and $_.Tier -ne 'safe' }).Count
    if ($notSafe) { throw "Recommended selected $notSafe item(s) that are not Safe" }
}

Check 'window icon renders' {
    if (-not $script:GuiWin.Icon) { throw 'no icon set' }
    if ($script:GuiWin.Icon.PixelWidth -ne 64) { throw "icon is $($script:GuiWin.Icon.PixelWidth)px" }
}

$script:GuiWin.Close()

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'Window drives correctly under every interaction.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failures.Count) failure(s):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
