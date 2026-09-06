#Requires -Version 5.1
<#
.SYNOPSIS
    Draw the Open Graph card and the touch icon.

.DESCRIPTION
    The social card is the first thing anyone sees when the link is pasted into
    Discord, Reddit or a group chat, which for a tool distributed by word of
    mouth is most of the first impressions it will ever make. Generated rather
    than hand-made so it can be regenerated when the wording changes, and so it
    is never quietly out of date with the site.

    Drawn with GDI+ and system fonts - no external tooling, no network, and the
    same output on any Windows machine.
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'site\img' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName System.Drawing

$void  = [System.Drawing.ColorTranslator]::FromHtml('#080B0C')
$panel = [System.Drawing.ColorTranslator]::FromHtml('#0D1213')
$rule  = [System.Drawing.ColorTranslator]::FromHtml('#2B3937')
$ink   = [System.Drawing.ColorTranslator]::FromHtml('#ECF2F0')
$soft  = [System.Drawing.ColorTranslator]::FromHtml('#9AA8A4')
$mint  = [System.Drawing.ColorTranslator]::FromHtml('#4FE0B0')

function New-Canvas {
    param([int]$W, [int]$H)
    $bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode   = 'HighQuality'
    return @{ Bmp = $bmp; G = $g }
}

function Add-RoundedPath {
    param($Path, [float]$X, [float]$Y, [float]$W, [float]$H, [float]$R)
    $d = $R * 2
    $Path.AddArc($X,           $Y,           $d, $d, 180, 90)
    $Path.AddArc($X + $W - $d, $Y,           $d, $d, 270, 90)
    $Path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d,   0, 90)
    $Path.AddArc($X,           $Y + $H - $d, $d, $d,  90, 90)
    $Path.CloseFigure()
}

function Draw-Bars {
    # The mark: three bars, each shorter than the last. Trimming, in three
    # strokes - the same shape the app and the favicon use.
    param($G, [float]$X, [float]$Y, [float]$Unit)
    $widths = @(1.0, 0.625, 0.333)
    $alphas = @(255, 158, 87)
    for ($i = 0; $i -lt 3; $i++) {
        $c = [System.Drawing.Color]::FromArgb($alphas[$i], $mint)
        $b = New-Object System.Drawing.SolidBrush($c)
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $h = $Unit * 0.1875
        Add-RoundedPath $p $X ($Y + $i * $Unit * 0.3125) ($Unit * $widths[$i]) $h ($h / 2)
        $G.FillPath($b, $p)
        $p.Dispose(); $b.Dispose()
    }
}

# ---- the Open Graph card, 1200 x 630 --------------------------------------

$c = New-Canvas 1200 630
$g = $c.G
$g.Clear($void)

# A soft light behind the headline, drawn as concentric rings rather than a
# gradient brush so it stays smooth at this size without banding.
for ($r = 620; $r -gt 0; $r -= 10) {
    $a = [int](16 * (1 - $r / 620.0))
    if ($a -le 0) { continue }
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, $mint))
    $g.FillEllipse($b, (60 - $r), (-140 - $r / 2), ($r * 2), $r)
    $b.Dispose()
}

# Measured grid, top-left quadrant only.
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(14, $soft), 1)
for ($x = 0; $x -le 1200; $x += 72) { $g.DrawLine($pen, $x, 0, $x, 630) }
for ($y = 0; $y -le 630; $y += 72) { $g.DrawLine($pen, 0, $y, 1200, $y) }
$pen.Dispose()

Draw-Bars $g 72 68 64

$fBrand = New-Object System.Drawing.Font('Segoe UI', 25, [System.Drawing.FontStyle]::Bold, 'Pixel')
$fHead  = New-Object System.Drawing.Font('Segoe UI', 62, [System.Drawing.FontStyle]::Bold, 'Pixel')
$fSub   = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Regular, 'Pixel')
$fMono  = New-Object System.Drawing.Font('Consolas', 22, [System.Drawing.FontStyle]::Regular, 'Pixel')
$fTag   = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Regular, 'Pixel')

$bInk  = New-Object System.Drawing.SolidBrush($ink)
$bSoft = New-Object System.Drawing.SolidBrush($soft)
$bMint = New-Object System.Drawing.SolidBrush($mint)
$bVoid = New-Object System.Drawing.SolidBrush($void)

$g.DrawString('trim', $fBrand, $bInk, 156, 74)

$g.DrawString('Debloat Windows',      $fHead, $bInk, 66, 168)
$g.DrawString('without breaking it.', $fHead, $bInk, 66, 250)

$g.DrawString('Removes the junk, tunes the rest for games, and hands you', $fSub, $bSoft, 72, 356)
$g.DrawString('a script that puts every setting back.',                   $fSub, $bSoft, 72, 392)

# The command, in its own frame.
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
Add-RoundedPath $path 72 456 660 68 10
$bPanel = New-Object System.Drawing.SolidBrush($panel)
$g.FillPath($bPanel, $path)
$penR = New-Object System.Drawing.Pen($rule, 1)
$g.DrawPath($penR, $path)
$g.FillRectangle($bMint, 72, 466, 2, 48)
$g.DrawString('PS>', $fMono, $bMint, 92, 476)
$g.DrawString('irm https://trimbloat.com/go | iex', $fMono, $bInk, 152, 476)
$path.Dispose(); $bPanel.Dispose(); $penR.Dispose()

# Footing tags.
$tags = @('Free', 'Open source', 'Windows 10 & 11', 'Fully reversible')
$x = 74.0
foreach ($t in $tags) {
    $w = $g.MeasureString($t, $fTag).Width
    $g.FillEllipse($bMint, $x, 566, 6, 6)
    $g.DrawString($t, $fTag, $bSoft, ($x + 14), 556)
    $x += $w + 44
}

$bmp = $c.Bmp
$og = Join-Path $OutDir 'og.png'
$bmp.Save($og, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

# ---- the touch icon, 180 x 180 --------------------------------------------

$c2 = New-Canvas 180 180
$g2 = $c2.G
$g2.Clear([System.Drawing.Color]::Transparent)

$p2 = New-Object System.Drawing.Drawing2D.GraphicsPath
Add-RoundedPath $p2 0 0 180 180 40
$g2.FillPath($bVoid, $p2)
$p2.Dispose()

Draw-Bars $g2 34 46 112

$bmp2 = $c2.Bmp
$icon = Join-Path $OutDir 'icon-180.png'
$bmp2.Save($icon, [System.Drawing.Imaging.ImageFormat]::Png)
$g2.Dispose(); $bmp2.Dispose()

foreach ($f in @($fBrand, $fHead, $fSub, $fMono, $fTag)) { $f.Dispose() }
foreach ($b in @($bInk, $bSoft, $bMint, $bVoid)) { $b.Dispose() }

Write-Host ''
foreach ($p in @($og, $icon)) {
    $i = Get-Item $p
    Write-Host ("  {0,-16} {1,6} KB" -f $i.Name, [Math]::Round($i.Length / 1KB)) -ForegroundColor Green
}
Write-Host ''
