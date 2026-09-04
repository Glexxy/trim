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
    Save-Pane 'Uninstall apps' 'uninstall.png'
} finally {
    $win.Close()
    $win.Dispatcher.Invoke([action]{}, 'Background') | Out-Null
}

Write-Host ''
Write-Host "Written to $OutDir" -ForegroundColor Cyan
Write-Host ''
