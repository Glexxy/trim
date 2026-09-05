#Requires -Version 5.1
<#
.SYNOPSIS
    Turn the exported window screenshots into the web images the site ships.

.DESCRIPTION
    test\Export-GuiScreenshots.ps1 renders the real window at 2320px wide, which
    is the right size to keep as a source and completely the wrong thing to send
    to a phone - the four PNGs together are nearly a megabyte. This resizes them
    and encodes WebP at the two widths the page actually asks for in its srcset.

    The encoder is whatever is on PATH: cwebp if present, otherwise ffmpeg. If
    neither is installed the script says so and stops without touching anything,
    because the generated files are committed - the site never depends on this
    tool being present at publish time, only on somebody having run it after
    changing the screenshots.

.PARAMETER Source
    Where the full-size PNGs are. Defaults to docs\screenshots.

.PARAMETER OutDir
    Where the web images go. Defaults to hosting\site\img.
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$OutDir,
    [int[]]$Widths = @(1200, 2320),
    [int]$Quality = 82
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Source) { $Source = Join-Path $root 'docs\screenshots' }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'site\img' }

function Find-Tool {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$cwebp  = Find-Tool 'cwebp'
$ffmpeg = Find-Tool 'ffmpeg'

if (-not $cwebp -and -not $ffmpeg) {
    Write-Host 'Neither cwebp nor ffmpeg is on PATH, so no images were rebuilt.' -ForegroundColor Yellow
    Write-Host 'The committed files in hosting\site\img are still valid - this only' -ForegroundColor DarkGray
    Write-Host 'matters if you have just changed the screenshots.' -ForegroundColor DarkGray
    Write-Host '  winget install Google.WebP     (or)     winget install Gyan.FFmpeg' -ForegroundColor DarkGray
    exit 0
}

$files = @(Get-ChildItem -LiteralPath $Source -Filter '*.png' -ErrorAction SilentlyContinue)
if (-not $files.Count) { throw "No PNGs in $Source. Run test\Export-GuiScreenshots.ps1 first." }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host ''
Write-Host "Encoding with $(if ($cwebp) { 'cwebp' } else { 'ffmpeg' })" -ForegroundColor Cyan
Write-Host ''

$total = 0
foreach ($f in $files) {
    foreach ($w in $Widths) {
        $suffix = if ($w -eq $Widths[0]) { '' } else { "@$([Math]::Round($w / $Widths[0]))x" }
        $out = Join-Path $OutDir ("$($f.BaseName)$suffix.webp")

        if ($cwebp) {
            & $cwebp -quiet -q $Quality -resize $w 0 -m 6 $f.FullName -o $out
        } else {
            # -vf scale=w:-2 keeps the aspect ratio and an even height, which
            # some encoders insist on.
            & $ffmpeg -hide_banner -loglevel error -y -i $f.FullName `
                -vf "scale=$($w):-2" -c:v libwebp -quality $Quality -compression_level 6 $out
        }
        if ($LASTEXITCODE -ne 0) { throw "Encoding failed for $($f.Name) at ${w}px" }

        $kb = [Math]::Round((Get-Item $out).Length / 1KB)
        $total += $kb
        Write-Host ("  {0,-24} {1,5}px  {2,5} KB" -f (Split-Path $out -Leaf), $w, $kb) -ForegroundColor Green
    }
}

# Record which screenshots these were encoded from.
#
# The site holds a second copy of every screenshot, in WebP. Regenerating the
# PNGs does not regenerate these, so the two drifted twenty hours and five
# window changes apart, and trimbloat.com spent a day showing a version of the
# window that no longer existed - old checkboxes, the old scroll bar, and an
# uninstall pane from before it had icons or real application names. On a site
# whose argument is "look at exactly what it does before you run it".
#
# PNGs are marked binary in .gitattributes, so their bytes survive a clone
# intact and hashing them raw is the right comparison here.
$stamp = Join-Path $OutDir 'generated-from.txt'
$lines = @(
    '# The screenshots these WebP images were encoded from.',
    '# Rebuild with hosting\Build-SiteAssets.ps1 when this stops matching.'
)
foreach ($f in ($files | Sort-Object Name)) {
    $lines += "$($f.Name) $((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash)"
}
Set-Content -LiteralPath $stamp -Encoding UTF8 -Value $lines
Write-Host "  stamped generated-from.txt" -ForegroundColor DarkGray

Write-Host ''
Write-Host "$($files.Count) screenshot(s), $($Widths.Count) width(s), $total KB total" -ForegroundColor Cyan
Write-Host ''
