#Requires -Version 5.1
<#
.SYNOPSIS
    Build Trim, stage it, and publish it to trimbloat.com.

.DESCRIPTION
    One command, so there is no way to publish a stale build or a build that
    does not parse. The order is deliberate:

        1. build       - compiles src\ and refuses to emit a broken script
        2. test        - the full local suite; publishing a failing build is
                         not something that should be one typo away
        3. stage       - copies the artefact, its fingerprint and the winutil
                         config into hosting\public
        4. verify      - re-hashes the staged copy and compares it to the
                         sidecar, so what ships is what was measured
        5. deploy      - wrangler

    Nothing is uploaded if any step fails.

.PARAMETER SkipTests
    Publish without running the suite. For a hotfix where the suite is already
    known green - not a habit.

.PARAMETER DryRun
    Build, test, stage and verify, then stop before uploading. Use this first.
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root    = Split-Path $PSScriptRoot -Parent
$public  = Join-Path $PSScriptRoot 'public'
$script  = Join-Path $root 'trim.ps1'

function Step { param([string]$Text) Write-Host "`n== $Text" -ForegroundColor Cyan }
function Fail { param([string]$Text) Write-Host "   $Text" -ForegroundColor Red; exit 1 }
function Good { param([string]$Text) Write-Host "   $Text" -ForegroundColor Green }

# ---- 1. build -------------------------------------------------------------
Step 'Building'
& (Join-Path $root 'build.ps1') | Select-Object -Last 3
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { Fail 'Build failed.' }
if (-not (Test-Path -LiteralPath $script)) { Fail "No artefact at $script" }

# ---- 2. test --------------------------------------------------------------
if ($SkipTests) {
    Write-Host "`n== Tests SKIPPED by request" -ForegroundColor Yellow
} else {
    Step 'Testing'

    $harness = & (Join-Path $root 'test\Invoke-DryRunHarness.ps1') 2>&1
    if ($LASTEXITCODE -ne 0) {
        $harness | Select-String '^FAIL|failure' | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
        Fail 'The dry-run harness failed. Not publishing.'
    }
    Good "dry-run harness: $((@($harness | Select-String '^PASS')).Count) checks passed"

    $undo = & (Join-Path $root 'test\Test-UndoRoundTrip.ps1') 2>&1
    if ($LASTEXITCODE -ne 0) { Fail 'The undo round-trip failed. Not publishing.' }
    Good 'undo round-trip verified'

    # The window has to be built on an STA thread, so it runs in its own host.
    $gui = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
        -File (Join-Path $root 'test\Test-GuiInteraction.ps1') 2>&1
    if ($LASTEXITCODE -ne 0) {
        $gui | Select-String '^FAIL|failure' | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
        Fail 'The window interaction test failed. Not publishing.'
    }
    Good "window interaction: $((@($gui | Select-String '^PASS')).Count) checks passed"
}

# ---- 3. stage -------------------------------------------------------------
Step 'Staging'
if (Test-Path -LiteralPath $public) { Remove-Item -LiteralPath $public -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $public 'config') | Out-Null

Copy-Item -LiteralPath $script                     -Destination (Join-Path $public 'trim.ps1')
Copy-Item -LiteralPath "$script.sha256"            -Destination (Join-Path $public 'trim.ps1.sha256')
Copy-Item -LiteralPath (Join-Path $root 'config\winutil-tweaks.json') `
                                                   -Destination (Join-Path $public 'config\winutil-tweaks.json')

# The landing page and its two assets. Copied rather than generated: the worker
# serves index.html verbatim apart from one substitution, so what is in site\ is
# what ships.
$site = Join-Path $PSScriptRoot 'site'
foreach ($f in @('index.html', 'styles.css', 'app.js', 'favicon.svg')) {
    $from = Join-Path $site $f
    if (-not (Test-Path -LiteralPath $from)) { Fail "Missing site file: $from" }
    Copy-Item -LiteralPath $from -Destination (Join-Path $public $f)
}
Good "staged $([Math]::Round((Get-Item (Join-Path $public 'trim.ps1')).Length / 1KB, 1)) KB + landing page"

# ---- 4. verify ------------------------------------------------------------
Step 'Verifying what is about to ship'
$staged   = (Get-FileHash -LiteralPath (Join-Path $public 'trim.ps1') -Algorithm SHA256).Hash
$declared = ((Get-Content -Raw -LiteralPath (Join-Path $public 'trim.ps1.sha256')).Trim() -split '\s+')[0]

if ($staged -ne $declared) {
    Write-Host "   staged   $staged" -ForegroundColor Red
    Write-Host "   declared $declared" -ForegroundColor Red
    Fail 'The staged script does not match its published fingerprint.'
}
Good "SHA256 $staged"

# The URLs baked into the script have to be the real ones, or an elevated
# relaunch from a piped run re-fetches from nowhere.
$text = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $public 'trim.ps1')
if ($text -match 'REPLACE-ME') { Fail 'The script still contains a REPLACE-ME placeholder URL.' }
foreach ($needed in @('https://trimbloat.com/go', 'https://trimbloat.com/config/winutil-tweaks.json')) {
    if ($text -notmatch [regex]::Escape($needed)) { Fail "The script does not carry the canonical URL: $needed" }
}
Good 'canonical URLs present'

# The page promises a fingerprint and a reproducible build. If the placeholder
# were ever renamed or dropped, the worker would serve the literal token to
# every visitor and the central claim of the page would read as broken.
$page = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $public 'index.html')
if ($page -notmatch '\{\{SHA256\}\}') {
    Fail 'index.html no longer contains the {{SHA256}} placeholder the worker substitutes.'
}
foreach ($ref in @('/styles.css', '/app.js')) {
    if ($page -notmatch [regex]::Escape($ref)) { Fail "index.html does not reference $ref" }
}
# An inline <script> would be blocked by the Content-Security-Policy the worker
# sets, and would fail silently in the browser rather than loudly here.
if ($page -match '(?s)<script(?![^>]*\ssrc=)[^>]*>\s*\S') {
    Fail 'index.html contains an inline <script>, which the CSP blocks. Move it into app.js.'
}
if ($page -match '\son[a-z]+\s*=\s*"') {
    Fail 'index.html contains an inline event handler, which the CSP blocks.'
}
Good 'landing page intact (placeholder, assets, no inline script)'

# ---- 5. deploy ------------------------------------------------------------
if ($DryRun) {
    Write-Host "`n== Dry run - nothing uploaded" -ForegroundColor Yellow
    Write-Host "   Staged in $public" -ForegroundColor DarkGray
    Write-Host "   Publish with: .\hosting\Publish-Trim.ps1" -ForegroundColor DarkGray
    exit 0
}

Step 'Deploying to Cloudflare'
Push-Location $PSScriptRoot
try {
    & npx --yes wrangler@latest deploy
    if ($LASTEXITCODE -ne 0) { Fail 'wrangler deploy failed.' }
} finally { Pop-Location }

Write-Host ''
Good 'Published.'
Write-Host ''
Write-Host '   irm https://trimbloat.com/go | iex' -ForegroundColor Cyan
Write-Host ''
Write-Host "   fingerprint  $staged" -ForegroundColor DarkGray
Write-Host '   landing      https://trimbloat.com' -ForegroundColor DarkGray
Write-Host '   fingerprint  https://trimbloat.com/sha256' -ForegroundColor DarkGray
