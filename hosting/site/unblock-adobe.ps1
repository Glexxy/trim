#Requires -Version 5.1
# Undo "Block Adobe Networking".
# In an Administrator PowerShell, run:
#     irm https://trimbloat.com/unblock-adobe | iex
# Removes the Adobe entries that were written to the Windows hosts file, so Adobe
# products install and activate again. The original hosts file is backed up first.
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'This needs administrator rights.' -ForegroundColor Yellow
    Write-Host 'Open PowerShell as administrator (right-click Start, then "Terminal (Admin)") and run:' -ForegroundColor Yellow
    Write-Host '    irm https://trimbloat.com/unblock-adobe | iex' -ForegroundColor Cyan
    return
}

$hostsFile = Join-Path $env:WinDir 'System32\drivers\etc\hosts'
$lines = Get-Content -LiteralPath $hostsFile
# Keep every line that is NOT an Adobe host mapped to a blackhole address.
$keep = $lines | Where-Object {
    ($_ -split '#', 2)[0].Trim() -notmatch '^(0\.0\.0\.0|127\.0\.0\.1|::1)\s+\S*adobe\S*'
}
$removed = $lines.Count - $keep.Count

if ($removed -le 0) {
    Write-Host 'No Adobe-blocking entries were found in the hosts file - nothing to undo.' -ForegroundColor Yellow
    return
}

$backup = "$hostsFile.trim-backup-" + (Get-Date -Format 'yyyyMMdd_HHmmss')
Copy-Item -LiteralPath $hostsFile -Destination $backup -Force
Set-Content -LiteralPath $hostsFile -Value $keep -Encoding ASCII
cmd /c 'ipconfig /flushdns' | Out-Null
Write-Host ("Removed {0} Adobe-blocking line(s) from the hosts file." -f $removed) -ForegroundColor Green
Write-Host ("Backup of the original saved to: {0}" -f $backup) -ForegroundColor DarkGray
Write-Host 'Adobe installs and activation should work now. If an installer is open, restart it (or reboot).' -ForegroundColor Green
