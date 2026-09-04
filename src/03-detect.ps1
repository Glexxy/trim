# ---------------------------------------------------------------------------
# Hardware and OS detection.
#
# This script goes on machines we have never seen. Every phase asks this module
# what it is running on rather than assuming a desktop with an NVIDIA card.
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Registry paths for 32-bit application registrations, correct for this OS.

.DESCRIPTION
    64-bit Windows puts 32-bit app registrations under WOW6432Node. 32-bit
    Windows has no such node and puts them directly under SOFTWARE. Windows 10
    still ships in 32-bit, so hardcoding WOW6432Node silently finds nothing
    there - which looks identical to "no games installed".
#>
function Get-SoftwareHivePaths {
    # An empty SubPath is a legitimate question - "what are the hive roots" -
    # and answering it is how callers avoid hardcoding WOW6432Node themselves.
    param([AllowEmptyString()][string]$SubPath = '')

    $suffix = if ($SubPath) { "\$($SubPath.Trim('\'))" } else { '' }
    $paths = @()
    if ([Environment]::Is64BitOperatingSystem) { $paths += "HKLM:\SOFTWARE\WOW6432Node$suffix" }
    $paths += "HKLM:\SOFTWARE$suffix"
    return $paths
}

<#
.SYNOPSIS
    Program Files roots that actually exist on this machine.

.DESCRIPTION
    ${env:ProgramFiles(x86)} is undefined on 32-bit Windows. Joining a path onto
    it throws under StrictMode rather than politely returning nothing.
#>
function Get-ProgramFilesRoots {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)})
    return @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

<#
.SYNOPSIS
    The slow half of the hardware inventory, fetched only when it is looked at.

.DESCRIPTION
    Get-PhysicalDisk, Win32_PhysicalMemory, Win32_BaseBoard and Win32_BIOS
    together cost about two seconds - a sixth of the whole launch - and nothing
    in any phase needs them. Only the specification grid does, and that is one
    click away rather than on the critical path. Cached, so opening it twice is
    free.
#>
$script:HardwareDetail = $null
function Get-HardwareDetail {
    if ($script:HardwareDetail) { return $script:HardwareDetail }

    $cpu = $null
    try { $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0] } catch { }

    $disks = @()
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Model  = "$($_.FriendlyName)".Trim()
                Media  = "$($_.MediaType)"
                Bus    = "$($_.BusType)"
                SizeGB = [Math]::Round($_.Size / 1GB, 0)
            }
        })
    } catch { }

    $ramSticks = @()
    try {
        $ramSticks = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ SizeGB = [Math]::Round($_.Capacity / 1GB, 0); Speed = $_.ConfiguredClockSpeed }
        })
    } catch { }

    $board = $null; $bios = $null
    try { $board = Get-CimInstance Win32_BaseBoard -ErrorAction Stop } catch { }
    try { $bios  = Get-CimInstance Win32_BIOS -ErrorAction Stop } catch { }

    $script:HardwareDetail = [pscustomobject]@{
        CpuName     = if ($cpu) { "$($cpu.Name)".Trim() } else { 'unknown' }
        CpuCores    = if ($cpu) { $cpu.NumberOfCores } else { 0 }
        CpuThreads  = if ($cpu) { $cpu.NumberOfLogicalProcessors } else { 0 }
        Board       = if ($board) { "$($board.Manufacturer) $($board.Product)".Trim() } else { '' }
        BiosVersion = if ($bios) { "$($bios.SMBIOSBIOSVersion)" } else { '' }
        Disks       = $disks
        RamSticks   = $ramSticks
        RamSpeed    = if ($ramSticks.Count) { ($ramSticks | Measure-Object Speed -Maximum).Maximum } else { 0 }
    }
    return $script:HardwareDetail
}

function Get-MachineFacts {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
    $gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
             Where-Object { $_.PNPDeviceID -notmatch '^ROOT\\' })   # drop the Basic Display adapter

    # PCSystemType: 1 Desktop, 2 Mobile, 3 Workstation, 4 Enterprise Server...
    # Chassis type is the more reliable signal on mini-PCs and AIOs, and a
    # battery is the tiebreaker: no OEM ships a desktop with one.
    $chassis = @()
    try { $chassis = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes) } catch { }
    $laptopChassis  = @(8,9,10,11,12,14,18,21,30,31,32)
    $desktopChassis = @(3,4,5,6,7,15,16,17,23,24)
    $hasLaptopChassis  = (@($chassis | Where-Object { $laptopChassis  -contains $_ }).Count -gt 0)
    $hasDesktopChassis = (@($chassis | Where-Object { $desktopChassis -contains $_ }).Count -gt 0)

    # A battery alone must not decide this. A desktop on a UPS reports a
    # Win32_Battery, and treating it as a laptop silently skips every
    # desktop-only tweak on a machine that wanted them. Chassis and
    # PCSystemType are the reliable signals; the battery only breaks a tie.
    $isLaptop = ($cs.PCSystemType -eq 2) -or
                $hasLaptopChassis -or
                ($bat.Count -gt 0 -and -not $hasDesktopChassis -and $cs.PCSystemType -ne 1)

    $vendors = @()
    foreach ($g in $gpu) {
        if ($g.Name -match 'NVIDIA|GeForce|Quadro|RTX|GTX') { $vendors += 'NVIDIA' }
        elseif ($g.Name -match 'Radeon|AMD|FirePro')         { $vendors += 'AMD' }
        elseif ($g.Name -match 'Intel|Arc|UHD|Iris')         { $vendors += 'Intel' }
    }

    $refresh = 0
    try {
        $refresh = [int](($gpu | Where-Object { $_.CurrentRefreshRate -gt 0 } |
                         Measure-Object CurrentRefreshRate -Maximum).Maximum)
    } catch { }

    # A managed machine's settings can be overwritten by policy minutes later,
    # and writing Policies keys on one may conflict with what an administrator
    # has deliberately configured.
    $managed = $false
    try {
        $managed = ($cs.PartOfDomain -eq $true)
        if (-not $managed) {
            $enrol = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
            if (Test-Path -LiteralPath $enrol) {
                $managed = (@(Get-ChildItem -LiteralPath $enrol -ErrorAction SilentlyContinue |
                    Where-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).EnrollmentState -eq 1 }).Count -gt 0)
            }
        }
    } catch { }

    return [pscustomobject]@{
        IsManaged      = $managed
        Manufacturer   = $cs.Manufacturer
        Model          = $cs.Model
        IsLaptop       = $isLaptop
        RamGB          = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
        OSCaption      = $os.Caption
        OSBuild        = [int]$os.BuildNumber
        DisplayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
        GpuNames       = @($gpu | Select-Object -ExpandProperty Name)
        GpuVendors     = @($vendors | Select-Object -Unique)
        HasNvidia      = ($vendors -contains 'NVIDIA')
        RefreshRate    = $refresh
        SystemDriveSSD = Test-SystemDriveIsSSD
    }
}

function Test-SystemDriveIsSSD {
    try {
        $letter = $env:SystemDrive.TrimEnd(':')
        $part   = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $disk   = Get-PhysicalDisk -ErrorAction Stop |
                  Where-Object { $_.DeviceId -eq $part.DiskNumber }
        return ($disk.MediaType -eq 'SSD')
    } catch { return $true }   # assume SSD; the only thing this gates is defrag advice
}

function Show-MachineFacts {
    param([Parameter(Mandatory)]$Facts)
    Write-Phase 'Detected machine'
    Write-Log "Model        : $($Facts.Manufacturer) $($Facts.Model)"
    Write-Log "Form factor  : $(if ($Facts.IsLaptop) { 'Laptop' } else { 'Desktop' })"
    Write-Log "OS           : $($Facts.OSCaption) $($Facts.DisplayVersion) (build $($Facts.OSBuild))"
    Write-Log "Memory       : $($Facts.RamGB) GB"
    Write-Log "GPU          : $($Facts.GpuNames -join ', ')"
    Write-Log "Refresh rate : $(if ($Facts.RefreshRate) { "$($Facts.RefreshRate) Hz" } else { 'unknown' })"

    if ($Facts.OSBuild -lt 22000) {
        Write-Log -Level WARN -Message 'This is not Windows 11. Several phases will be skipped or behave differently.'
    }
    if ($Facts.IsLaptop) {
        Write-Log -Level WARN -Message 'Laptop detected. Power-hungry settings (max performance GPU mode, disabled NIC power saving) will be skipped.'
    }
    if ($Facts.IsManaged) {
        Write-Log -Level WARN -Message 'This machine is domain-joined or MDM-enrolled.'
        Write-Log -Level WARN -Message '  Group Policy may revert these changes at the next refresh, and some of them'
        Write-Log -Level WARN -Message '  may contradict what your administrator has deliberately configured.'
        Write-Log -Level WARN -Message '  Check with whoever manages it before applying.'
    }
}
