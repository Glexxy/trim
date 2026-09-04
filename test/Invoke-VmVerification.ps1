#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end verification of trim inside a disposable VM.

.DESCRIPTION
    This is the test the dry-run harness cannot be: it applies the changes for
    real and then proves two things that have only ever been asserted.

        1. LANDED  - every change the run claims to have made is actually present
                     in the registry afterwards.
        2. REVERSED - running the generated undo script returns every one of them
                     to exactly the value it had before, including removing values
                     that did not previously exist.

    It reads the run's own ledger rather than parsing the log, so the assertions
    are exact and cannot drift from what the script actually did.

    RUN THIS ONLY IN A DISPOSABLE VM. It makes real changes.

.PARAMETER Phases
    Which phases to exercise. Defaults to the registry-heavy ones, because DISM
    and sfc take 10-30 minutes and prove nothing about the undo path.

.PARAMETER Full
    Run every phase including Fixes (DISM + sfc) and WinUtil. Slow.
#>
[CmdletBinding()]
param(
    [string[]]$Phases = @('Gaming','Privacy','Personalisation','Network'),
    [switch]$Full,
    [string]$ScriptPath = '',

    # Escape hatch for a physical test bench that does not report as a VM. This
    # applies real changes - the guard exists for a reason.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Refuse to run on a real machine. The single most damaging way to misuse this
# file is to double-click it on the host, so the guard is deliberately noisy and
# checks several independent signals rather than one.
# ---------------------------------------------------------------------------
function Test-IsDisposableEnvironment {
    $signals = @{}

    $cs = Get-CimInstance Win32_ComputerSystem
    $signals['Model']        = $cs.Model
    $signals['Manufacturer'] = $cs.Manufacturer

    $isVm = ($cs.Model -match 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|Xen') -or
            ($cs.Manufacturer -match 'Microsoft Corporation|VMware|innotek|QEMU|Xen')

    # Windows Sandbox: the container user is always WDAGUtilityAccount.
    $isSandbox = ($env:USERNAME -eq 'WDAGUtilityAccount') -or
                 (Test-Path 'C:\Users\WDAGUtilityAccount')

    $signals['IsVM']      = $isVm
    $signals['IsSandbox'] = $isSandbox
    return [pscustomobject]$signals
}

$env = Test-IsDisposableEnvironment
Write-Host ''
Write-Host '  trim - VM verification' -ForegroundColor Cyan
Write-Host "  Host: $($env.Manufacturer) $($env.Model)" -ForegroundColor DarkGray
Write-Host "  VM: $($env.IsVM)   Sandbox: $($env.IsSandbox)" -ForegroundColor DarkGray
Write-Host ''

if (-not $env.IsVM -and -not $env.IsSandbox -and -not $Force) {
    Write-Host 'REFUSING TO RUN.' -ForegroundColor Red
    Write-Host 'This does not look like a virtual machine or a Sandbox container.' -ForegroundColor Red
    Write-Host 'It applies real changes. Run it inside a disposable environment.' -ForegroundColor Red
    Write-Host 'Override with -Force only if you are certain, and have a restore point.' -ForegroundColor DarkGray
    exit 2
}

if (-not $ScriptPath) {
    foreach ($c in @("$PSScriptRoot\..\trim.ps1", 'C:\opt\trim.ps1')) {
        if (Test-Path $c) { $ScriptPath = (Resolve-Path $c).Path; break }
    }
}
if (-not $ScriptPath -or -not (Test-Path $ScriptPath)) {
    Write-Host "Cannot find trim.ps1. Pass -ScriptPath." -ForegroundColor Red
    exit 2
}

$results  = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Check, [bool]$Pass, [string]$Detail = '')
    $results.Add([pscustomobject]@{ Check = $Check; Pass = $Pass; Detail = $Detail }) | Out-Null
    $tag = if ($Pass) { 'PASS' } else { 'FAIL' }
    $col = if ($Pass) { 'Green' } else { 'Red' }
    Write-Host ("{0}  {1}" -f $tag, $Check) -ForegroundColor $col
    if ($Detail -and -not $Pass) { Write-Host "      $Detail" -ForegroundColor DarkRed }
}

function Get-Actual {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Exists = $false; Value = $null } }
    $item = Get-Item -LiteralPath $Path
    if ($item.GetValueNames() -notcontains $Name) { return @{ Exists = $false; Value = $null } }
    return @{ Exists = $true; Value = $item.GetValue($Name) }
}

# ---------------------------------------------------------------------------
# 1. Apply
# ---------------------------------------------------------------------------
# A HASHTABLE splat, not an array. Splatting an array onto a script passes its
# elements POSITIONALLY, so @('-Only','Gaming,Privacy') bound the literal string
# "-Only" as a value for the first positional parameter instead of naming one.
#
# -NoRestartPrompt is not optional either. Without it the run reaches Read-Host
# after applying and waits forever for an answer nobody is there to give, which
# looks exactly like a hung verification.
$phaseArgs = @{ NoRestorePoint = $true; NoRestartPrompt = $true }
if (-not $Full) { $phaseArgs['Only'] = $Phases }

Write-Host ''
Write-Host "--- Applying (phases: $(if ($Full) { 'ALL' } else { $Phases -join ',' })) ---" -ForegroundColor Cyan
& $ScriptPath @phaseArgs 2>&1 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }

$ledgerPath = 'C:\ProgramData\Trim\ledger\latest.json'
if (-not (Test-Path $ledgerPath)) {
    Add-Result 'Ledger produced' $false "no ledger at $ledgerPath"
    exit 1
}
$ledger  = Get-Content -Raw $ledgerPath | ConvertFrom-Json
$entries = @($ledger.Entries)
Add-Result 'Ledger produced' ($entries.Count -gt 0) "$($entries.Count) entries"
if ($entries.Count -eq 0) { exit 1 }

# ---------------------------------------------------------------------------
# 2. Did the changes actually land?
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Verifying changes landed ---' -ForegroundColor Cyan
$landedBad = [System.Collections.Generic.List[string]]::new()
foreach ($e in $entries) {
    $a = Get-Actual -Path $e.Path -Name $e.Name
    if ($e.Action -eq 'remove') {
        if ($a.Exists) { $landedBad.Add("$($e.Path)\$($e.Name) should have been removed but is still present") | Out-Null }
    } else {
        if (-not $a.Exists) {
            $landedBad.Add("$($e.Path)\$($e.Name) missing after run") | Out-Null
        } elseif ("$($a.Value)" -ne "$($e.NewValue)") {
            $landedBad.Add("$($e.Path)\$($e.Name) is '$($a.Value)', expected '$($e.NewValue)'") | Out-Null
        }
    }
}
Add-Result "All $($entries.Count) recorded changes are present" ($landedBad.Count -eq 0) ($landedBad -join '; ')
foreach ($b in ($landedBad | Select-Object -First 10)) { Write-Host "      $b" -ForegroundColor DarkRed }

# ---------------------------------------------------------------------------
# 3. Does the undo script actually undo?
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Running the undo script ---' -ForegroundColor Cyan
$undo = $ledger.UndoPath
Add-Result 'Undo script exists' (Test-Path $undo) $undo
if (Test-Path $undo) {
    & $undo 2>&1 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }

    $undoBad = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) {
        $a = Get-Actual -Path $e.Path -Name $e.Name
        if ($e.HadValue) {
            if (-not $a.Exists) {
                $undoBad.Add("$($e.Path)\$($e.Name) should have been restored to '$($e.OldValue)' but is absent") | Out-Null
            } elseif ("$($a.Value)" -ne "$($e.OldValue)") {
                $undoBad.Add("$($e.Path)\$($e.Name) is '$($a.Value)', should be back at '$($e.OldValue)'") | Out-Null
            }
        } else {
            # Never existed before the run, so undo must REMOVE it, not zero it.
            if ($a.Exists) {
                $undoBad.Add("$($e.Path)\$($e.Name) did not exist before the run but is still present as '$($a.Value)'") | Out-Null
            }
        }
    }
    Add-Result "Undo restored all $($entries.Count) values exactly" ($undoBad.Count -eq 0) ($undoBad -join '; ')
    foreach ($b in ($undoBad | Select-Object -First 10)) { Write-Host "      $b" -ForegroundColor DarkRed }
}

# ---------------------------------------------------------------------------
# 4. Idempotence: a second run should report almost everything already correct.
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Re-applying to check idempotence ---' -ForegroundColor Cyan
& $ScriptPath @phaseArgs 2>&1 | Out-Null
& $ScriptPath @phaseArgs 2>&1 | Out-Null
$second = Get-Content -Raw $ledgerPath | ConvertFrom-Json
Add-Result 'Second consecutive run is a no-op' (@($second.Entries).Count -eq 0) `
    "second run still changed $(@($second.Entries).Count) value(s); they are not being detected as already-set"

# ---------------------------------------------------------------------------
Write-Host ''
$failed = @($results | Where-Object { -not $_.Pass })
if ($failed.Count -eq 0) {
    Write-Host "ALL $($results.Count) CHECKS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failed.Count) of $($results.Count) CHECKS FAILED" -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "  - $($f.Check)" -ForegroundColor Red }
    exit 1
}
