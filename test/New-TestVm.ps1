#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a disposable Hyper-V Windows 11 VM for full-run testing, with a
    checkpoint taken before the optimizer is applied.

.DESCRIPTION
    Windows Sandbox covers the registry work, but three things need a real VM:
      * system restore points (Sandbox has System Protection disabled)
      * reboots (Sandbox is a single session)
      * the full consumer AppX set (Sandbox ships a reduced one)

    This builds that VM from a Windows 11 ISO plus the autounattend beside this
    file, so the install is hands-off. It takes a checkpoint immediately after
    install, which is what makes repeated test passes cheap: revert, re-run,
    revert again.

.PARAMETER IsoPath
    Path to a Windows 11 ISO. Get one from
    https://www.microsoft.com/software-download/windows11 (Download disk image).

.PARAMETER VmPath
    Where to put the VM. Defaults to whatever this host has Hyper-V configured
    to use, which is the setting the machine's owner already chose. A 64 GB
    dynamic VHDX plus a checkpoint wants room, so point it at a roomy volume if
    the Hyper-V default sits on a small system drive.

.EXAMPLE
    .\New-TestVm.ps1 -IsoPath 'D:\ISO\Win11_25H2.iso'

.EXAMPLE
    # Roll back to the clean checkpoint between test passes
    Restore-VMCheckpoint -VMName OPT-TEST -Name 'clean-install' -Confirm:$false
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [string]$VmName    = 'OPT-TEST',
    [string]$VmPath,
    [int]$MemoryGB     = 8,
    [int]$DiskGB       = 64,
    [int]$Cpu          = 4,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Say { param($m, $c = 'Gray') Write-Host $m -ForegroundColor $c }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say 'Hyper-V management needs an elevated session.' Red
    exit 1
}
if (-not (Get-Module -ListAvailable Hyper-V)) {
    Say 'The Hyper-V PowerShell module is not present. Run Enable-VirtualisationFeatures.ps1 and reboot.' Red
    exit 1
}
# Resolved after the module check, not in the param block: asking Hyper-V where
# it keeps its VMs needs the module loaded, and hardcoding a drive letter is how
# this script used to be tied to one particular machine.
if (-not $VmPath) {
    $VmPath = (Get-VMHost).VirtualMachinePath
    if (-not $VmPath) { $VmPath = Join-Path $env:SystemDrive 'HyperV' }
    Say "VM path: $VmPath (Hyper-V default; override with -VmPath)" DarkGray
}

if (-not (Test-Path -LiteralPath $IsoPath)) {
    Say "ISO not found: $IsoPath" Red
    Say 'Download one from https://www.microsoft.com/software-download/windows11 (Download disk image / ISO).' DarkGray
    exit 1
}

$existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($existing) {
    if (-not $Force) {
        Say "VM '$VmName' already exists. Re-run with -Force to destroy and rebuild it." Yellow
        Say "Or revert it: Restore-VMCheckpoint -VMName $VmName -Name 'clean-install' -Confirm:`$false" DarkGray
        exit 1
    }
    Say "Removing existing VM '$VmName'..." Yellow
    if ($existing.State -ne 'Off') { Stop-VM -Name $VmName -TurnOff -Force }
    $disks = @(Get-VMHardDiskDrive -VMName $VmName | Select-Object -ExpandProperty Path)
    Remove-VM -Name $VmName -Force
    foreach ($d in $disks) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
}

New-Item -ItemType Directory -Force -Path $VmPath | Out-Null
$vhd = Join-Path $VmPath "$VmName\$VmName.vhdx"
New-Item -ItemType Directory -Force -Path (Split-Path $vhd) | Out-Null

# --- Build an ISO carrying autounattend.xml -------------------------------
# Setup only reads autounattend.xml from the root of a mounted volume, so the
# unattend file has to travel on media of its own. A tiny second ISO is far
# simpler and less fragile than rebuilding the Windows ISO.
$unattendSrc = Join-Path $PSScriptRoot 'autounattend.xml'
if (-not (Test-Path $unattendSrc)) { Say "Missing $unattendSrc" Red; exit 1 }

$answerIso = Join-Path $VmPath "$VmName-answer.iso"
$staging   = Join-Path $env:TEMP "optvm-answer-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Copy-Item $unattendSrc (Join-Path $staging 'autounattend.xml')

$oscdimg = @(
    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "$env:ProgramFiles\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($oscdimg) {
    & $oscdimg -n -m "$staging" "$answerIso" | Out-Null
    Say "Answer ISO built: $answerIso" DarkGray
} else {
    # No ADK. Fall back to IMAPI2, which every Windows box has.
    try {
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
        $fsi.VolumeName = 'UNATTEND'
        $fsi.Root.AddTree($staging, $false)
        $res = $fsi.CreateResultImage()
        $stream = $res.ImageStream
        $bytes = New-Object byte[] $res.TotalBlocks * $res.BlockSize
        $adapter = New-Object -ComObject ADODB.Stream
        $adapter.Open(); $adapter.Type = 1
        $adapter.Write($stream); $adapter.SaveToFile($answerIso, 2); $adapter.Close()
        Say "Answer ISO built via IMAPI2: $answerIso" DarkGray
    } catch {
        Say "Could not build the answer ISO: $($_.Exception.Message)" Red
        Say 'Install the Windows ADK Deployment Tools, or attach autounattend.xml manually.' DarkGray
        exit 1
    }
}
Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue

# --- Create the VM --------------------------------------------------------
Say "Creating VM '$VmName' ($MemoryGB GB RAM, $Cpu vCPU, $DiskGB GB disk)..." Cyan

New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) `
       -NewVHDPath $vhd -NewVHDSizeBytes ($DiskGB * 1GB) -Path $VmPath | Out-Null

Set-VM -Name $VmName -ProcessorCount $Cpu -CheckpointType Standard `
       -AutomaticCheckpointsEnabled $false
Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false

# A vTPM keeps the install on the supported path rather than relying on the
# LabConfig bypasses, and lets the VM take Windows Updates normally.
try {
    Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
    Enable-VMTPM -VMName $VmName
    Say 'vTPM enabled.' DarkGray
} catch {
    Say "vTPM unavailable ($($_.Exception.Message.Trim())). The autounattend bypasses cover it." Yellow
}

Add-VMDvdDrive -VMName $VmName -Path $IsoPath
Add-VMDvdDrive -VMName $VmName -Path $answerIso

# Boot from the Windows ISO, not the disk or the answer media.
$dvd = @(Get-VMDvdDrive -VMName $VmName | Where-Object { $_.Path -eq $IsoPath })[0]
Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd -EnableSecureBoot On `
               -SecureBootTemplate 'MicrosoftWindows'

$sw = @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue)[0]
if (-not $sw) { $sw = @(Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Default' })[0] }
if ($sw) {
    Connect-VMNetworkAdapter -VMName $VmName -SwitchName $sw.Name
    Say "Network: $($sw.Name)" DarkGray
} else {
    Say 'No virtual switch found. The VM has no network - winutil will fail. Create one in Hyper-V Manager.' Yellow
}

Start-VM -Name $VmName
Say ''
Say "VM '$VmName' created and starting." Green
Say ''
Say 'Windows will install unattended. It reboots a few times and lands on a' DarkGray
Say 'desktop logged in as test/test. That takes roughly 15-20 minutes.' DarkGray
Say ''
Say 'Watch it:' Cyan
Say "    vmconnect.exe localhost $VmName"
Say ''
Say 'Once it is at the desktop, take the clean checkpoint:' Cyan
Say "    Checkpoint-VM -Name $VmName -SnapshotName 'clean-install'"
Say ''
Say 'Then copy the project in and run the verification inside the VM:' Cyan
Say "    Copy-VMFile -Name $VmName -SourcePath '$(Split-Path $PSScriptRoot -Parent)' -DestinationPath 'C:\opt' -FileSource Host -CreateFullPath -Recurse"
Say "    # in the VM:  C:\opt\test\Invoke-VmVerification.ps1 -Full"
Say ''
Say 'Between passes, revert instead of rebuilding:' Cyan
Say "    Restore-VMCheckpoint -VMName $VmName -Name 'clean-install' -Confirm:`$false"
