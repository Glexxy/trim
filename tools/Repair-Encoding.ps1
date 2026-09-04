#Requires -Version 5.1
<#
.SYNOPSIS
    Ensure every PowerShell source file is UTF-8 with a byte order mark.

.DESCRIPTION
    Windows PowerShell 5.1 reads a file with no BOM using the system ANSI code
    page, not UTF-8. Any non-ASCII character in such a file is therefore
    corrupted on read - by Get-Content, by the parser, and by the engine that
    executes it.

    That is not a cosmetic problem. It broke three separate things here:

      * build.ps1 read the sources with Get-Content and produced a compiled
        script whose banner was mojibake and which then failed to parse
      * the test harness called Parser::ParseFile, which has no encoding
        parameter at all, and got a function body it could not compile
      * anyone running the shipped script under Windows PowerShell would have
        hit the same corruption

    None of it reproduced under PowerShell 7, which assumes UTF-8. Developing on
    7 and shipping to 5.1 is exactly how this stayed hidden.

    A BOM removes the ambiguity for every consumer at once, which is why it is
    the fix rather than adding an -Encoding argument at each call site.

.PARAMETER Check
    Report offenders and exit non-zero without changing anything. For CI and for
    the build's own guard.
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$targets = @(
    (Join-Path $root 'src\*.ps1'),
    (Join-Path $root 'test\*.ps1'),
    (Join-Path $root 'tools\*.ps1'),
    (Join-Path $root 'hosting\*.ps1'),
    (Join-Path $root 'build.ps1')
)

$utf8Bom = New-Object System.Text.UTF8Encoding $true
$offenders = [System.Collections.Generic.List[string]]::new()
$fixed = 0

foreach ($file in (Get-ChildItem -Path $targets -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -eq 0) { continue }

    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $nonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii = $true; break } }

    # ASCII-only files are read identically under every encoding, so they need
    # nothing. Only a file that actually contains non-ASCII is ambiguous.
    if (-not $nonAscii -or $hasBom) { continue }

    $offenders.Add($file.FullName.Substring($root.Length + 1)) | Out-Null
    if ($Check) { continue }

    # Decoded explicitly as UTF-8 - which is what these files actually are -
    # and written back with a BOM so nothing has to guess again.
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    [System.IO.File]::WriteAllText($file.FullName, $text, $utf8Bom)
    $fixed++
}

if ($Check) {
    if ($offenders.Count -eq 0) {
        Write-Host 'Encoding: every source file is ASCII or carries a UTF-8 BOM.' -ForegroundColor Green
        exit 0
    }
    Write-Host 'Encoding: these files contain non-ASCII with no BOM, and will be corrupted by Windows PowerShell 5.1:' -ForegroundColor Red
    foreach ($o in $offenders) { Write-Host "  $o" -ForegroundColor Red }
    Write-Host 'Run tools\Repair-Encoding.ps1 to fix them.' -ForegroundColor Yellow
    exit 1
}

if ($fixed -eq 0) {
    Write-Host 'Nothing to repair.' -ForegroundColor Green
} else {
    Write-Host "Repaired $fixed file(s):" -ForegroundColor Green
    foreach ($o in $offenders) { Write-Host "  $o" -ForegroundColor DarkGray }
}
