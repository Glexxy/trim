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
& "$work\test\Invoke-VmVerification.ps1" -ScriptPath "$work\trim.ps1"
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
Write-Host "Results copied to the host at test\results\. This window stays open." -ForegroundColor Yellow
