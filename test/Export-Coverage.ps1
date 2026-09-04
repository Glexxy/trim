#Requires -Version 5.1
<#
.SYNOPSIS
    Generates docs\COVERAGE.md from an actual dry run.

.DESCRIPTION
    The coverage document is generated, never hand-written, so it cannot drift
    from what the script does. A dry run records every intended registry change
    and every planned non-registry action into the ledger; this renders that.

    Values shown are what would happen ON THIS MACHINE. Machine-dependent lines
    (discovered games, NIC GUIDs, laptop-only skips) are marked as such.
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\COVERAGE.md')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

Write-Host 'Building...' -ForegroundColor Cyan
& (Join-Path $root 'build.ps1') | Select-Object -Last 1

Write-Host 'Running a full dry run to collect the manifest...' -ForegroundColor Cyan
& (Join-Path $root 'trim.ps1') -DryRun -NoRestorePoint | Out-Null

$ledgerPath = 'C:\ProgramData\Trim\ledger\latest.json'
if (-not (Test-Path $ledgerPath)) { throw "No ledger at $ledgerPath" }
$l = Get-Content -Raw $ledgerPath | ConvertFrom-Json
if (-not $l.DryRun) { throw 'Ledger is from a real run, not a dry run. Refusing to generate from it.' }

$actions = @($l.Actions)

# The ledger holds deltas; AlreadySet holds values checked and found correct.
# "What does this script cover" is the union - listing only deltas understates
# it badly on a machine that has already been partly tuned.
$entries = @(@($l.Entries) + @(@($l.AlreadySet) | ForEach-Object {
    [pscustomobject]@{
        Action = 'set'; Phase = $_.Phase; Path = $_.Path; Name = $_.Name
        NewValue = $_.NewValue; Because = $_.Because
        HadValue = $true; OldValue = $_.NewValue; NoChange = $true
    }
}))

function Esc { param($s) return ("$s" -replace '\|', '\|') }

$sb = [System.Text.StringBuilder]::new()
function W { param($t = '') [void]$sb.AppendLine($t) }

W '# Coverage'
W ''
W '**Generated, not written.** Produced by `test\Export-Coverage.ps1`, which runs a'
W 'full dry run and renders the resulting manifest. If a phase changes, this file'
W 'changes with it.'
W ''
W "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
W ''
W '| | |'
W '|---|---|'
W "| Registry values touched | $($entries.Count) |"
W "| ...of which would change on this machine | $(@($l.Entries).Count) |"
W "| ...already correct here | $(@($l.AlreadySet).Count) |"
W "| Other actions | $($actions.Count) |"
W "| Machine used | $($l.Machine.Manufacturer) $($l.Machine.Model) |"
W "| OS | $($l.Machine.OSCaption) $($l.Machine.DisplayVersion) (build $($l.Machine.OSBuild)) |"
W "| Form factor | $(if ($l.Machine.IsLaptop) { 'Laptop' } else { 'Desktop' }) |"
W "| GPU | $($l.Machine.GpuNames -join ', ') |"
W ''
W '> Counts are for **this** machine. A laptop, a non-NVIDIA box, or a PC with no'
W '> games installed produces a different set - phases skip what does not apply'
W '> rather than writing values that mean nothing.'
W ''
W '---'
W ''

# --- Non-registry actions, grouped by phase --------------------------------
W '## Actions that are not registry writes'
W ''
if ($actions.Count -eq 0) {
    W '_None recorded._'
} else {
    foreach ($phase in ($actions | Select-Object -ExpandProperty Phase -Unique)) {
        $inPhase = @($actions | Where-Object { $_.Phase -eq $phase })
        W "### $phase"
        W ''
        W '| Kind | What | Detail | Reversible |'
        W '|---|---|---|---|'
        foreach ($a in $inPhase) {
            W ("| {0} | `{1}` | {2} | {3} |" -f (Esc $a.Kind), (Esc $a.Target), (Esc $a.Detail), (Esc $a.Reversible))
        }
        W ''
    }
}

W '---'
W ''

# --- Registry changes, grouped by phase ------------------------------------
W '## Registry changes'
W ''
W 'Every one of these is recorded before it is written and reversed by the'
W 'generated undo script. `<absent>` in the *Currently* column means the value'
W 'does not exist yet, and undo will remove it again rather than writing a zero.'
W ''

foreach ($phase in ($entries | Select-Object -ExpandProperty Phase -Unique)) {
    $inPhase = @($entries | Where-Object { $_.Phase -eq $phase })
    W "### $phase  _($($inPhase.Count))_"
    W ''
    W '| Key | Value name | Sets to | Currently | Why |'
    W '|---|---|---|---|---|'
    foreach ($e in $inPhase) {
        $to  = if ($e.Action -eq 'remove') { '_(removed)_' } else { Esc $e.NewValue }
        $now = if ($e.HadValue) { Esc $e.OldValue } else { '`<absent>`' }
        if ("$now" -eq '') { $now = '_(empty)_' }
        $noChange = ($e.PSObject.Properties.Name -contains 'NoChange') -and $e.NoChange
        if ($noChange) { $now = "$now _(already correct)_" }
        W ("| `{0}` | `{1}` | {2} | {3} | {4} |" -f `
            (Esc $e.Path), (Esc $e.Name), $to, $now, (Esc $e.Because))
    }
    W ''
}

W '---'
W ''
W '## What is deliberately left alone'
W ''
W 'These are checked at runtime, not just by convention - the deny list is'
W 'validated against the protected list on every run, and the test suite fails'
W 'the build if they ever collide.'
W ''
W '| | Why |'
W '|---|---|'
W '| Camera, microphone | Needed. Explicitly on the never-touch list. |'
W '| Screenshots, screen recording | Needed. Explicitly on the never-touch list. |'
W '| Documents / Pictures / Videos / Music library access | Denying these breaks Store apps'' access to the user''s own files. |'
W '| Presence sensing | Hardware feature, not telemetry. |'
W '| `Microsoft.VCLibs`, `UI.Xaml`, `NET.Native`, `WindowsAppRuntime` | Frameworks other apps link against. |'
W '| `Microsoft.DesktopAppInstaller` | This *is* winget. |'
W '| `Microsoft.XboxIdentityProvider`, `Xbox.TCUI`, `GamingApp` | How a large number of PC games sign in. |'
W '| `Microsoft.SecHealthUI` | The Windows Security interface. |'
W '| `Microsoft.ScreenSketch` | Snipping Tool. |'
W '| Fan curves, BIOS, undervolting, overclocking | Out of scope by design. |'
W '| AutoLogon | Writes a recoverable password to the registry. Never included. |'
W '| Removing Edge | Breaks WebView2 dependents; Windows Update reinstalls it anyway. |'
W ''

New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
Set-Content -LiteralPath $OutFile -Value $sb.ToString() -Encoding UTF8

Write-Host ''
Write-Host "Wrote $OutFile" -ForegroundColor Green
Write-Host "  $($entries.Count) registry changes, $($actions.Count) other actions" -ForegroundColor DarkGray
