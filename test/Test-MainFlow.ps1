#Requires -Version 5.1
<#
.SYNOPSIS
    Runs Invoke-Main itself, in every way the script can be invoked.

.DESCRIPTION
    Nothing else executes Invoke-Main. The dry-run harness calls the phases
    directly and the window test drives the window - both start after the
    decision about what kind of run this is has already been made. That
    decision is the thing that shipped wrong: with no arguments the script fell
    past the window branch and applied every change unattended.

    So this replaces the six functions that touch the machine with recorders,
    calls the real Invoke-Main, and asserts what it did and in what order.
    Every branch runs; none of them reach anything that writes.

    Host-safe. No registry write, no restore point, no window, no elevation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path $PSScriptRoot -Parent

# The parameter surface, as the compiled script's param block would leave it.
$DryRun = $false; $Apply = $false; $Gui = $false
$Skip = @(); $Only = @(); $NoRestorePoint = $true; $Aggressive = $false
$WinUtilConfigUrl = Join-Path $root 'config\winutil-tweaks.json'
$NvidiaProfile = ''; $DisableMemoryIntegrity = $false; $ApplySelection = ''
$NoRestartPrompt = $true; $Cleanup = $false; $IncludeDuplicates = $false
$CleanupSelection = ''; $ElevationHash = ''; $LargeFiles = $false

# Invoke-Selection branches on this: elevated, it flips the run out of dry mode
# and hands back to the caller; unelevated, it relaunches itself as admin. Only
# the first branch is exercised here - the second starts a process.
$isAdmin = $true

foreach ($f in (Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1' | Sort-Object Name)) {
    if ($f.Name -in @('01-header.ps1','99-main.ps1')) { continue }
    . $f.FullName
}

# 99-main.ps1 ends by calling Invoke-Main. Load its function definitions and
# leave that call behind, so the entry point can be driven rather than run.
$errs = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Join-Path $root 'src') '99-main.ps1'), [ref]$null, [ref]$errs)
if ($errs) { throw "99-main.ps1 does not parse: $($errs[0].Message)" }
$defs = @($mainAst.EndBlock.Statements |
          Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
if ($defs.Count -lt 5) { throw "expected the entry point's functions, found $($defs.Count)" }
. ([scriptblock]::Create(($defs | ForEach-Object { $_.Extent.Text }) -join "`n"))

if (-not (Get-Command Invoke-Main -ErrorAction SilentlyContinue)) {
    throw 'Invoke-Main was not loaded'
}

# ---------------------------------------------------------------------------
# Recorders. Everything that would touch the machine, or block on a window.
# ---------------------------------------------------------------------------
$script:Trace      = [System.Collections.Generic.List[string]]::new()
$script:CanShowGui = $true
$script:WindowGives = $null      # what Show-TrimWindow hands back

function Note { param([string]$What) $script:Trace.Add($What) | Out-Null }

function Show-TrimBanner            { }
function Show-MachineFacts          { param($Facts) }
function Test-SingleUserAssumption  { }
function Write-LedgerJson           { }
function Get-MachineFacts           { [pscustomobject]@{ OSBuild = 26100; GpuNames = @(); IsLaptop = $false } }

function New-SafetyRestorePoint     { Note 'restore-point' }
function Write-UndoScript           { Note 'undo-script' }
function Show-Summary               { param($Facts, $Started) Note 'summary' }
function Request-Restart            { Note 'restart-prompt' }
function Invoke-CleanupPhase        { param($IncludeDuplicates, $ReportLargeFiles) Note 'cleanup' }

# The one that matters. Records whether the run was still dry when it reached
# here, because that is the difference between showing a plan and applying it.
function Invoke-AllPhases {
    param($Facts)
    Note $(if ($DryRun) { 'phases(dry)' } else { 'phases(APPLY)' })
}

function Test-CanShowGui { $script:CanShowGui }
function Get-GuiItems    { param($Ledger, $Actions) @() }
function Invoke-WithProgress { param($Total, $Work) Note 'progress-window'; & $Work }

# Invoke-Selection is deliberately NOT stubbed. It is the function that takes
# the run out of dry mode once a selection exists, so a stub standing in for it
# makes the window's Apply look like it changes nothing - which is what the
# first version of this file reported. It writes a selection file and sets the
# filter; neither touches the machine.

function Show-TrimWindow {
    param($Facts, $BuildPlan)
    Note 'window-shown'
    # The real window calls this to fill itself in, and the plan it builds must
    # be a dry one.
    $null = & $BuildPlan
    return $script:WindowGives
}

# ---------------------------------------------------------------------------
$failures = [System.Collections.Generic.List[string]]::new()

function Case {
    param([string]$What, [hashtable]$Params, [scriptblock]$Assert)

    # Reset the whole parameter surface: Invoke-Main writes back to some of
    # these, so a case must not inherit the last one's decisions.
    $script:DryRun = $false; $script:Apply = $false; $script:Gui = $false
    $script:Cleanup = $false; $script:LargeFiles = $false
    $script:ApplySelection = ''; $script:CleanupSelection = ''
    $script:CanShowGui = $true; $script:WindowGives = $null
    foreach ($k in $Params.Keys) { Set-Variable -Name $k -Value $Params[$k] -Scope Script }

    $script:Trace = [System.Collections.Generic.List[string]]::new()
    try {
        Invoke-Main
        $trace = @($script:Trace)
        & $Assert $trace
        Write-Host "PASS  $What" -ForegroundColor Green
        Write-Host "      $($trace -join ' -> ')" -ForegroundColor DarkGray
    } catch {
        Write-Host "FAIL  $What" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "      trace: $(@($script:Trace) -join ' -> ')" -ForegroundColor DarkGray
        $failures.Add($What) | Out-Null
    }
}

Write-Host ''
Write-Host 'Trim - entry point flow' -ForegroundColor Cyan
Write-Host ''

# The one that shipped wrong. `irm https://trimbloat.com/go | iex` passes no
# parameters at all, and this is what that run must do.
Case 'no arguments shows the window and changes nothing' @{} {
    param($t)
    if ($t -notcontains 'window-shown')   { throw 'the window was never shown' }
    if ($t -contains 'phases(APPLY)')     { throw 'a bare run applied changes' }
    if ($t -contains 'restore-point')     { throw 'a bare run took a restore point before the window' }
    if ($t -notcontains 'phases(dry)')    { throw 'the window was given no plan to show' }
}

Case 'no arguments on a host with no window prints the plan, it does not apply it' @{ CanShowGui = $false } {
    param($t)
    if ($t -contains 'phases(APPLY)') { throw 'a host that cannot show a window applied changes instead' }
    if ($t -notcontains 'phases(dry)') { throw 'nothing was reported at all' }
}

Case '-Apply applies, and takes the restore point first' @{ Apply = $true } {
    param($t)
    if ($t -notcontains 'phases(APPLY)') { throw '-Apply did not apply anything' }
    if ($t -notcontains 'restore-point') { throw '-Apply changed the machine with no restore point' }
    if ([Array]::IndexOf($t, 'restore-point') -gt [Array]::IndexOf($t, 'phases(APPLY)')) {
        throw 'the restore point was taken after the changes it is meant to protect'
    }
    if ($t -contains 'window-shown')   { throw '-Apply opened a window' }
    if ($t -notcontains 'undo-script') { throw '-Apply wrote no undo script' }
}

Case '-DryRun changes nothing' @{ DryRun = $true } {
    param($t)
    if ($t -contains 'phases(APPLY)')  { throw '-DryRun applied changes' }
    if ($t -notcontains 'phases(dry)') { throw '-DryRun produced no plan' }
    if ($t -contains 'window-shown')   { throw '-DryRun opened a window' }
}

Case 'closing the window applies nothing' @{ Gui = $true } {
    param($t)
    if ($t -contains 'phases(APPLY)') { throw 'closing the window still applied changes' }
    if ($t -contains 'restore-point') { throw 'closing the window still took a restore point' }
    if ($t -contains 'undo-script')   { throw 'an undo script was written for a run that changed nothing' }
}

Case 'Apply in the window: restore point, then changes, then the undo script' `
     @{ Gui = $true; WindowGives = @([pscustomobject]@{
            Key = 'reg|HKCU:\Software\Trim\FlowTest|Value'; Kind = 'reg'
            Phase = 'Privacy'; Title = 'a ticked change'; Tier = 'safe' }) } {
    param($t)
    foreach ($step in @('window-shown','progress-window','restore-point','phases(APPLY)','undo-script','summary')) {
        if ($t -notcontains $step) { throw "'$step' never happened" }
    }
    # What was ticked has to reach the filter the phases read, or Apply would
    # run every change rather than the chosen ones.
    if (-not $script:SelectionFilter -or $script:SelectionFilter.Count -ne 1) {
        throw 'the selection never reached the filter the phases read'
    }
    if ([Array]::IndexOf($t, 'restore-point') -gt [Array]::IndexOf($t, 'phases(APPLY)')) {
        throw 'the restore point was taken after the changes'
    }
    if ([Array]::IndexOf($t, 'undo-script') -lt [Array]::IndexOf($t, 'phases(APPLY)')) {
        throw 'the undo script was written before the changes it reverses'
    }
    # The window builds its plan dry, then the real pass applies. Both must
    # have happened, in that order.
    if ($t -notcontains 'phases(dry)') { throw 'the window was never given a dry plan' }
    if ([Array]::IndexOf($t, 'phases(dry)') -gt [Array]::IndexOf($t, 'phases(APPLY)')) {
        throw 'the plan was built after it was applied'
    }
}

# -ApplySelection is how the window applies when it started unelevated: the
# window writes what was ticked, then hands the file to an elevated process.
# That process reads it as untrusted input, because a less privileged one wrote
# it. Nothing else exercises this path.
$selDir = Join-Path ([IO.Path]::GetTempPath()) 'trim-flow-test'
New-Item -ItemType Directory -Force -Path $selDir | Out-Null
$goodSel = Join-Path $selDir 'good.json'
$badSel  = Join-Path $selDir 'rubbish.json'
$emptySel = Join-Path $selDir 'empty.json'
@([pscustomobject]@{ Key='reg|HKCU:\Software\Trim\FlowTest|Value'; Kind='reg'
                     Phase='Privacy'; Title='t'; Tier='safe' }) |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $goodSel -Encoding UTF8
@([pscustomobject]@{ Key='not a valid key at all'; Kind='reg'
                     Phase='Privacy'; Title='t'; Tier='safe' }) |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $badSel -Encoding UTF8
'[]' | Set-Content -LiteralPath $emptySel -Encoding UTF8

Case '-ApplySelection applies what the window saved' @{ ApplySelection = $goodSel } {
    param($t)
    if ($t -notcontains 'phases(APPLY)') { throw 'the saved selection was never applied' }
    if ($t -notcontains 'restore-point') { throw 'no restore point before an elevated apply' }
    if ([Array]::IndexOf($t, 'restore-point') -gt [Array]::IndexOf($t, 'phases(APPLY)')) {
        throw 'the restore point was taken after the changes'
    }
    if ($t -notcontains 'undo-script') { throw 'no undo script for an elevated apply' }
    if ($script:SelectionFilter.Count -ne 1) { throw 'the saved selection did not reach the filter' }
}

Case '-ApplySelection refuses a file full of malformed keys' @{ ApplySelection = $badSel } {
    param($t)
    if ($t -contains 'phases(APPLY)') { throw 'a file with no valid keys still applied changes' }
    if ($t -contains 'restore-point') { throw 'a rejected selection still took a restore point' }
}

Case '-ApplySelection refuses an empty file' @{ ApplySelection = $emptySel } {
    param($t)
    if ($t -contains 'phases(APPLY)') { throw 'an empty selection still applied changes' }
}

Case '-ApplySelection refuses a file that is not there' @{ ApplySelection = (Join-Path $selDir 'absent.json') } {
    param($t)
    if ($t.Count) { throw "a missing selection file still did: $($t -join ', ')" }
}

Case '-Cleanup runs the sweep and nothing else' @{ Cleanup = $true } {
    param($t)
    if ($t -notcontains 'cleanup')    { throw '-Cleanup did not run the sweep' }
    if ($t -contains 'phases(APPLY)') { throw '-Cleanup applied the tweak phases as well' }
    if ($t -contains 'window-shown')  { throw '-Cleanup opened a window' }
}

Remove-Item -LiteralPath $selDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($failures.Count) {
    Write-Host "$($failures.Count) failure(s):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
Write-Host 'The entry point routes every invocation correctly.' -ForegroundColor Green
