#Requires -Version 5.1
<#
.SYNOPSIS
    Render the real window to PNG files, for the site and the README.

.DESCRIPTION
    Builds the genuine window - the same Initialize-TrimWindow the app uses,
    driven by a real dry-run manifest - and renders each pane straight out of
    WPF with RenderTargetBitmap. Nothing is mocked up, so a screenshot cannot
    quietly stop matching the product.

    It renders at 2x so the images stay sharp on a high-DPI display, and it
    positions the window off-screen rather than hiding it: WPF has to actually
    lay a window out before it will draw, but nobody needs to watch it happen.

.PARAMETER Real
    Render this machine's own data. The default is a representative demo
    machine instead, because the Overview pane prints the motherboard, BIOS
    version, disk models, volume labels and free space of whatever PC generated
    it, and the phase panes list the full path of every installed game. That is
    fine locally and wrong on a public web page, so publishing screenshots uses
    the demo machine and a marketing site never leaks somebody's drive layout.

.PARAMETER OutDir
    Where to write the PNGs. Defaults to docs\screenshots.

.EXAMPLE
    powershell.exe -NoProfile -STA -File test\Export-GuiScreenshots.ps1
#>
[CmdletBinding()]
param(
    [switch]$Real,
    # Resolved below, not here: $PSScriptRoot is not reliably populated while a
    # param block's defaults are being evaluated under Windows PowerShell.
    [string]$OutDir,
    [int]$Scale = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $OutDir) { $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\screenshots' }

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'Re-run with -STA. WPF cannot be constructed on an MTA thread.' -ForegroundColor Red
    exit 2
}

$root = Split-Path $PSScriptRoot -Parent

# The same parameter surface the compiled script exposes, so the modules can be
# dot-sourced without 01-header.ps1 (which would try to elevate) or 99-main.ps1
# (which would try to run).
$DryRun = $true; $Skip = @(); $Only = @(); $NoRestorePoint = $true; $Aggressive = $false
$WinUtilConfigUrl = Join-Path $root 'config\winutil-tweaks.json'
$NvidiaProfile = ''; $DisableMemoryIntegrity = $false; $Gui = $false; $ApplySelection = ''
$NoRestartPrompt = $true; $Cleanup = $false; $IncludeDuplicates = $false; $CleanupSelection = ''

foreach ($f in (Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1' | Sort-Object Name)) {
    if ($f.Name -in @('01-header.ps1','99-main.ps1')) { continue }
    . $f.FullName
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Write-Host ''
Write-Host 'Trim - window screenshot export' -ForegroundColor Cyan
Write-Host ''

# --- the manifest ----------------------------------------------------------

$facts = Get-MachineFacts
Invoke-GamingPhase -Facts $facts
Invoke-PrivacyPhase
Invoke-AppxPhase
Invoke-NetworkPhase -Facts $facts
Invoke-PersonalisationPhase
$items = @(Get-GuiItems -Ledger $script:Ledger -Actions $script:Actions)

if (-not $Real) {
    # A representative desktop. Chosen to look like a machine somebody might
    # actually own rather than to flatter the tool.
    $facts = [pscustomobject]@{
        OSCaption = 'Microsoft Windows 11 Pro'; DisplayVersion = '24H2'; OSBuild = 26100
        IsLaptop  = $false; Manufacturer = 'ASUS'; Model = 'ROG STRIX B650E-F GAMING WIFI'
        RamGB     = 32; GpuNames = @('NVIDIA GeForce RTX 4070'); RefreshRate = 165
        IsManaged = $false
    }

    # Get-MachineSpecRows calls these two directly, so they are replaced rather
    # than filtered afterwards - a screenshot must not depend on remembering to
    # scrub a field that somebody adds to the grid later.
    function Get-HardwareDetail {
        [pscustomobject]@{
            Board = 'ASUS ROG STRIX B650E-F GAMING WIFI'; BiosVersion = '2611'
            CpuName = 'AMD Ryzen 7 7800X3D 8-Core Processor'; CpuCores = 8; CpuThreads = 16
            RamSticks = @([pscustomobject]@{ SizeGB = 16 }, [pscustomobject]@{ SizeGB = 16 })
            RamSpeed = 6000
            Disks = @(
                [pscustomobject]@{ Model = 'Samsung SSD 990 PRO 2TB'; SizeGB = 1863; Media = 'SSD'; Bus = 'NVMe' },
                [pscustomobject]@{ Model = 'WDC WD40EZAZ-00SF3B0';    SizeGB = 3726; Media = 'HDD'; Bus = 'SATA' }
            )
        }
    }
    function Get-StorageInventory {
        @(
            [pscustomobject]@{ Letter = 'C'; FreeGB = 612; SizeGB = 1862; Label = 'Windows' },
            [pscustomobject]@{ Letter = 'D'; FreeGB = 988; SizeGB = 3725; Label = 'Games' }
        )
    }

    # Every discovered game carries the full path it was found at. Rewritten to
    # a generic library so the images do not publish anyone's drive layout.
    $sample = @{
        0 = 'D:\Steam\steamapps\common\Counter-Strike Global Offensive\game\bin\win64\cs2.exe'
        1 = 'D:\Steam\steamapps\common\Cyberpunk 2077\bin\x64\Cyberpunk2077.exe'
        2 = 'D:\Steam\steamapps\common\Baldurs Gate 3\bin\bg3.exe'
        3 = 'D:\Epic Games\Fortnite\FortniteGame\Binaries\Win64\FortniteClient-Win64-Shipping.exe'
        4 = 'D:\Steam\steamapps\common\Helldivers 2\bin\helldivers2.exe'
    }
    $n = 0
    foreach ($i in $items) {
        if ($i.Detail -match '^[A-Za-z]:\\' -or $i.Title -match '^[A-Za-z]:\\') {
            $path = $sample[($n % $sample.Count)]; $n++
            if ($i.Title  -match '^[A-Za-z]:\\') { $i.Title  = $path }
            if ($i.Detail -match '^[A-Za-z]:\\') { $i.Detail = $path }
        }
    }
    # The startup list is a software inventory of whoever ran this - Discord,
    # work tools, whatever they happen to have installed. Representative
    # entries instead, for the same reason the machine is a demo machine.
    $runHkcu  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $appHkcu  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    $runHklm  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    $appHklm  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'

    $script:GuiStartupItems = @(
        [pscustomobject]@{ Name='Discord'; Command='Update.exe --processStart Discord.exe'
                           Publisher='Discord Inc.'; Source='Registry'; Scope='You'
                           Location=$runHkcu; Approved=$appHkcu; State='Enabled'; CanChange=$true },
        [pscustomobject]@{ Name='EpicGamesLauncher'; Command='EpicGamesLauncher.exe -silent'
                           Publisher='Epic Games, Inc.'; Source='Registry'; Scope='You'
                           Location=$runHkcu; Approved=$appHkcu; State='Disabled'; CanChange=$true },
        [pscustomobject]@{ Name='Steam'; Command='steam.exe -silent'
                           Publisher='Valve Corporation'; Source='Registry'; Scope='You'
                           Location=$runHkcu; Approved=$appHkcu; State='Enabled'; CanChange=$true },
        [pscustomobject]@{ Name='RtkAudUService'; Command='RtkAudUService64.exe -background'
                           Publisher='Realtek Semiconductor'; Source='Registry'; Scope='All users'
                           Location=$runHklm; Approved=$appHklm; State='Enabled'; CanChange=$true },
        [pscustomobject]@{ Name='Corsair iCUE'; Command='iCUE.exe --autorun'
                           Publisher='Corsair Memory, Inc.'; Source='Registry'; Scope='All users'
                           Location=$runHklm; Approved=$appHklm; State='Enabled'; CanChange=$true },
        [pscustomobject]@{ Name='OneDrive'; Command='OneDrive.exe /background'
                           Publisher='Microsoft Corporation'; Source='Startup folder'; Scope='You'
                           Location='Startup'; Approved=''; State='Enabled'; CanChange=$true },
        [pscustomobject]@{ Name='NvTmRep_CrashReport1'; Command='NvTmRep.exe'
                           Publisher=''; Source='Scheduled task'; Scope='All users'
                           Location='\NvTmRep_CrashReport1'; Approved=''; State='Enabled'; CanChange=$false }
    )
    $script:GuiStartupLoaded = $true

    # The uninstall list is a software inventory too, and the same rule applies.
    # The exception is the apps Windows ships: they are byte-identical on every
    # installation, so their names and icons say nothing about whoever ran this,
    # and they are exactly what the pane is for. Strict allow-list, matched on
    # the whole name, and no fallback - a short list is fine, a leaked one is
    # not.
    # The names Windows itself shows for these, which is what the pane now
    # displays.
    $inbox = @(
        'Microsoft Edge', 'Xbox', 'Xbox Game Bar', 'Media Player', 'Movies & TV',
        'Photos', 'Snipping Tool', 'Paint', 'Notepad', 'Calculator', 'Clock',
        'Sound Recorder', 'Phone Link', 'Terminal', 'Sticky Notes', 'Weather',
        'News', 'Clipchamp', 'Solitaire Collection', 'Microsoft To Do', 'People',
        'Feedback Hub', 'Get Help', 'Tips', 'Cortana', 'Maps', 'Quick Assist',
        'Windows Web Experience Pack', 'Microsoft Family', 'Camera', 'Mail',
        'Calendar', 'Voice Recorder', 'Your Phone', 'Office', 'OneNote'
    )
    $picked = @(Get-InstalledApplications |
                Where-Object { $inbox -contains "$($_.DisplayName)".Trim() } |
                Sort-Object { "$($_.DisplayName)" } |
                Select-Object -First 9)

    # If the allow-list ever stops being one, the images stop being publishable.
    foreach ($p in $picked) {
        if ($inbox -notcontains "$($p.DisplayName)".Trim()) {
            throw "'$($p.DisplayName)' is not an app Windows ships, and would be published in a screenshot."
        }
    }
    if ($picked.Count) {
        $script:GuiApps = $picked
        $script:GuiAppsLoaded = $true
        Write-Host "  uninstall pane: $($picked.Count) app(s) Windows ships" -ForegroundColor DarkGray
    } else {
        Write-Host '  uninstall pane: none of the allow-listed apps are installed, showing the intro' -ForegroundColor DarkGray
    }

    Write-Host '  using the demo machine (pass -Real for this PC)' -ForegroundColor DarkGray
}

# Force one risky item in so the tier legend is fully represented.
if (-not @($items | Where-Object { $_.Tier -eq 'trade' }).Count) {
    $items += [pscustomobject]@{
        Key = 'act|command|Disable Memory Integrity (HVCI)'; Kind = 'command'
        Phase = 'Security'; Title = 'Disable Memory Integrity (HVCI)'
        Detail = 'Costs a little security for a little latency.'; Tier = 'trade'; Selected = $false
    }
}

Write-Host "  manifest: $($items.Count) items" -ForegroundColor DarkGray

# --- the window ------------------------------------------------------------

$win = Initialize-TrimWindow -Items $items -Facts $facts -AlreadyCorrect 38
$script:GuiScanning = $false

# Off-screen, not hidden: WPF will not render a window it has never laid out.
$win.WindowStartupLocation = 'Manual'
$win.Left = -4000
$win.Top  = -4000
$win.Width = 1160
$win.Height = 770
$win.ShowInTaskbar = $false
$win.Show()

function Sync-Ui {
    # Two passes. The first lets bindings and layout settle, the second lets
    # anything they triggered settle in turn - one pass leaves half-measured
    # panels in the image.
    $win.Dispatcher.Invoke([action]{}, 'Render') | Out-Null
    $win.Dispatcher.Invoke([action]{}, 'Loaded') | Out-Null
    $win.UpdateLayout()
    $win.Dispatcher.Invoke([action]{}, 'Render') | Out-Null
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Save-Pane {
    param([string]$Pane, [string]$File)

    Set-GuiPhase $Pane
    Sync-Ui

    $w = [int]$win.ActualWidth
    $h = [int]$win.ActualHeight
    if ($w -le 0 -or $h -le 0) { throw "Window measured $w x $h - nothing to render." }

    $dpi = 96 * $Scale
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap(
        ($w * $Scale), ($h * $Scale), $dpi, $dpi, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($win)

    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb)) | Out-Null

    $path = Join-Path $OutDir $File
    $fs = [System.IO.File]::Create($path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }

    $kb = [Math]::Round((Get-Item $path).Length / 1KB)
    Write-Host ("  {0,-22} {1,5} x {2,-5} {3,5} KB" -f $File, ($w * $Scale), ($h * $Scale), $kb) -ForegroundColor Green
}

Write-Host ''
try {
    Save-Pane 'Overview'       'overview.png'
    Set-GuiPreset 'recommended'

    # Whichever phase actually has the most to show on this machine, so the
    # image is never a screenshot of an empty list.
    $busiest = @($items | Group-Object Phase | Sort-Object Count -Descending |
                 Select-Object -First 1 -ExpandProperty Name)
    Save-Pane $busiest         'changes.png'

    Save-Pane 'Disk cleanup'   'cleanup.png'
    Save-Pane 'Startup apps'   'startup.png'
    Save-Pane 'Uninstall apps' 'uninstall.png'
} finally {
    $win.Close()
    $win.Dispatcher.Invoke([action]{}, 'Background') | Out-Null
}

# Record which window these are pictures of.
#
# The README shows them, so when the window changes and nobody regenerates
# them, the README quietly starts describing software that no longer exists.
# That happened twice in one day and was caught both times by somebody
# remembering, which is not a mechanism. The harness compares this stamp
# against the current source and says so.
#
# -Real renders this machine's own data and is never what gets committed, so
# it must not claim the committed images are current.
if (-not $Real) {
    . (Join-Path $PSScriptRoot 'Get-GuiFingerprint.ps1')
    $guiSrc = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\13-gui.ps1'
    $stamp  = Join-Path $OutDir 'generated-from.txt'
    Set-Content -LiteralPath $stamp -Encoding UTF8 -Value @(
        '# The window these screenshots were taken of.',
        '# Regenerate them with test\Export-GuiScreenshots.ps1 when this stops matching.',
        '# Line-ending normalised, so a fresh clone and a working copy agree.',
        "13-gui.ps1 $(Get-GuiFingerprint -Path $guiSrc)"
    )
    Write-Host "  stamped generated-from.txt" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host "Written to $OutDir" -ForegroundColor Cyan
Write-Host ''
