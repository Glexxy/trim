#Requires -Version 5.1
<#
.SYNOPSIS
    Enables Hyper-V and Windows Sandbox so the optimizer can be tested in a VM.

.DESCRIPTION
    Both features need a reboot. This script does NOT reboot - it enables them and
    reports, leaving the restart to whoever is at the keyboard.

    Worth knowing before running it: this machine already has the hypervisor
    running for VBS / Core Isolation, so enabling Hyper-V does not add the
    hypervisor performance overhead people worry about. That cost is already paid.
#>
[CmdletBinding()]
param([switch]$Disable)

$ErrorActionPreference = 'Stop'
$out = 'C:\ProgramData\Trim\logs\enable-virtualisation.log'
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null

function Say { param($m) Write-Host $m; Add-Content -LiteralPath $out -Value "$(Get-Date -Format 'HH:mm:ss') $m" }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say 'Must run elevated.'
    exit 1
}

$features = @(
    'Microsoft-Hyper-V-All',        # the hypervisor, management tools and PowerShell module
    'Containers-DisposableClientVM' # Windows Sandbox
)

$needsReboot = $false
foreach ($f in $features) {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $f).State
    Say "$f is currently: $state"

    if ($Disable) {
        if ($state -eq 'Enabled') {
            $r = Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart
            if ($r.RestartNeeded) { $needsReboot = $true }
            Say "  disabled $f"
        }
        continue
    }

    if ($state -eq 'Enabled') { Say "  already enabled, nothing to do"; continue }

    try {
        $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
        if ($r.RestartNeeded) { $needsReboot = $true }
        Say "  enabled $f"
    } catch {
        Say "  FAILED to enable $f : $($_.Exception.Message)"
    }
}

Say ''
foreach ($f in $features) {
    Say "final: $f = $((Get-WindowsOptionalFeature -Online -FeatureName $f).State)"
}

if ($needsReboot) {
    Say ''
    Say 'RESTART REQUIRED. Nothing takes effect until you reboot.'
    Say 'Not rebooting automatically - that is your call.'
}
Say "Log: $out"
