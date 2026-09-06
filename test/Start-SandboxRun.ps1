#Requires -Version 5.1
<#
.SYNOPSIS
    Runs inside Windows Sandbox on logon. Do not run this on a real machine.

.DESCRIPTION
    Copies the project out of the read-only mapped folder (the optimizer writes
    beside itself in places, and a read-only source produces confusing failures),
    runs the verification, and tees everything to the writable results folder so
    the host can read the outcome after the sandbox is gone.
#>
$ErrorActionPreference = 'Continue'

$stamp   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$results = 'C:\results'
$log     = Join-Path $results "sandbox-run_$stamp.log"
New-Item -ItemType Directory -Force -Path $results | Out-Null

Start-Transcript -Path $log -Append | Out-Null

Write-Host ''
Write-Host '=========================================' -ForegroundColor Cyan
Write-Host ' trim - Windows Sandbox run'    -ForegroundColor Cyan
Write-Host "  $stamp"                                  -ForegroundColor DarkGray
Write-Host '=========================================' -ForegroundColor Cyan

Write-Host ''
Write-Host "User        : $env:USERNAME"
Write-Host "OS          : $((Get-CimInstance Win32_OperatingSystem).Caption) build $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
Write-Host "Elevated    : $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
Write-Host "AppX count  : $(@(Get-AppxPackage -ErrorAction SilentlyContinue).Count)"

# Work from a local copy: C:\opt is read-only, and the optimizer resolves its
# default config relative to its own location.
$work = 'C:\work'
Write-Host ''
Write-Host "Copying project to $work ..." -ForegroundColor DarkGray
Copy-Item -Path 'C:\opt' -Destination $work -Recurse -Force
Write-Host 'Copied.' -ForegroundColor DarkGray

Write-Host ''
Write-Host '--- Stage 1: dry run (should change nothing) ---' -ForegroundColor Cyan
& "$work\trim.ps1" -DryRun -NoRestorePoint

Write-Host ''
Write-Host '--- Stage 2: apply, verify, undo, verify ---' -ForegroundColor Cyan
# -ThirdParty is signalled the same way -KeepOpen is: a flag in the mapped
# folder, because the guest is started by a LogonCommand and cannot be passed
# arguments from the host.
$vmArgs = @{ ScriptPath = "$work\trim.ps1" }
if (Test-Path (Join-Path $results 'thirdparty.flag')) { $vmArgs['ThirdParty'] = $true }
& "$work\test\Invoke-VmVerification.ps1" @vmArgs
# A terminating error leaves $LASTEXITCODE unset, and an exit code that is never
# written looks identical to a sandbox that is still running - which is how the
# host harness ended up waiting on a container that had already given up.
$code = if ($null -eq $LASTEXITCODE) { 99 } else { $LASTEXITCODE }

# Copy the optimizer's own artefacts out so they survive the sandbox.
foreach ($d in @('logs','undo','ledger')) {
    $src = "C:\ProgramData\Trim\$d"
    if (Test-Path $src) {
        Copy-Item $src -Destination (Join-Path $results $d) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host "VERIFICATION EXIT CODE: $code" -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Red' })
Set-Content -LiteralPath (Join-Path $results 'exitcode.txt') -Value $code

Stop-Transcript | Out-Null
Write-Host ''

# Shut the guest down from inside, which is the only clean way to end this.
#
# Closing the sandbox window asks the user to confirm, so it cannot be
# automated. Killing the host-side session processes ends the window and
# strands the VM: vmmemWindowsSandbox stays alive holding its whole memory
# allocation, owned by the Hyper-V Host Compute Service and refusing
# Stop-Process with "Access is denied". Reclaiming it then takes a service
# restart. One run left 1.7 GB stranded exactly that way.
#
# Everything worth keeping is already on the host - the results folder is a
# mapped host directory, written above, not something that leaves with the VM.
if (Test-Path (Join-Path $results 'keepopen.flag')) {
    Write-Host "Results copied to the host at test\results\. This window stays open (-KeepOpen)." -ForegroundColor Yellow
} else {
    Write-Host "Results copied to the host at test\results\. Shutting down." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    shutdown.exe /s /t 0
}
