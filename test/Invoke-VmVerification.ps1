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
    # Every phase whose changes the undo script claims to reverse.
    #
    # It was four of these. The other five write registry values, record them
    # in the same ledger, and are covered by the same promise - they had simply
    # never been applied and reversed for real.
    #
    # The three that are absent cannot be checked this way, and saying which is
    # part of being honest about what this proves:
    #   WinUtil - hands off to a third-party script and says in the log that its
    #             changes are NOT covered by the undo script.
    #   Appx    - removes Store apps, which the README already states cannot be
    #             put back.
    #   Fixes   - runs DISM and sfc. Ten to thirty minutes, and nothing it does
    #             is a recorded change to reverse.
    # -Full still runs everything, for when the question is whether they crash
    # rather than whether they reverse.
    [string[]]$Phases = @('Gaming','Privacy','Personalisation','Network',
                          'Performance','Background','Graphics','Security','Extras'),
    [switch]$Full,

    # Run the WinUtil handoff for real. Off by default because it downloads and
    # executes a third-party script and takes several noisy minutes, and on
    # because nothing else has ever executed it: the harness only ever reaches
    # that phase under -DryRun, which returns before the handoff.
    #
    # It matters. The phase failed on its first statement for every user, every
    # run, with "The property 'runspace' cannot be found on this object" - our
    # own Set-StrictMode -Version 2.0, inherited by anything this script
    # invokes, against code not written for it. That was fixed and the fix was
    # never once observed working.
    [switch]$ThirdParty,

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
    <#
        -Inconclusive is a third state on purpose.

        A check with nothing to test reports success, and that has been the
        most persistent fault in this project's own tests: an assertion that
        could only ever pass, a fixture that happened to agree with the bug, a
        filter that selected nothing, a captured stream that was empty. Every
        one of them was green.

        So when a check cannot be carried out here, it says so and is counted
        separately. Green means verified. It does not mean nothing went wrong.
    #>
    param([string]$Check, [bool]$Pass, [string]$Detail = '', [switch]$Inconclusive)

    $state = if ($Inconclusive) { 'SKIP' } elseif ($Pass) { 'PASS' } else { 'FAIL' }
    $results.Add([pscustomobject]@{
        Check = $Check; Pass = $Pass; Detail = $Detail; State = $state
    }) | Out-Null

    $col = switch ($state) { 'PASS' { 'Green' } 'SKIP' { 'Yellow' } default { 'Red' } }
    Write-Host ("{0}  {1}" -f $state, $Check) -ForegroundColor $col
    if ($Detail -and $state -ne 'PASS') {
        Write-Host "      $Detail" -ForegroundColor $(if ($state -eq 'SKIP') { 'DarkYellow' } else { 'DarkRed' })
    }
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
# -Apply is not optional either, and this is the only script in the project that
# needs it. A run with no mode switch opens the window - that is the whole point
# of the change that introduced it, because the published one-liner passes no
# arguments and used to apply everything unattended. Unattended in a sandbox
# there is no window to open, so the run falls back to printing the plan and
# this verification would sit there measuring a dry run against a claim that
# something was applied.
#
# -NoRestorePoint and -Only are filters, not instructions to change anything.
# Only this says "do it".
$phaseArgs = @{ Apply = $true; NoRestorePoint = $true; NoRestartPrompt = $true }
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
# 5. The WinUtil handoff, actually executed.
# ---------------------------------------------------------------------------
if ($ThirdParty) {
    Write-Host ''
    Write-Host '--- Running the WinUtil handoff for real (several minutes, noisy) ---' -ForegroundColor Cyan

    # Read the run's LOG, not its output stream.
    #
    # Write-Log reports through Write-Host, which does not travel on the
    # success stream, so "2>&1 | Out-String" captured an empty string. The two
    # assertions looking for progress markers failed against nothing, and - far
    # worse - the assertion looking for the strict-mode ERROR passed against
    # nothing too. It could not have failed. Meanwhile the log showed the phase
    # handing off and completing perfectly.
    $logDir  = 'C:\ProgramData\Trim\logs'
    $before  = @(Get-ChildItem $logDir -Filter 'run_*.log' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

    & $ScriptPath -Apply -Only WinUtil -NoRestorePoint -NoRestartPrompt | Out-Null

    $newLog = Get-ChildItem $logDir -Filter 'run_*.log' -ErrorAction SilentlyContinue |
              Where-Object { $before -notcontains $_.Name } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $wuOut = if ($newLog) { Get-Content -Raw -LiteralPath $newLog.FullName } else { '' }

    # And prove there is something to assert against, before asserting on it.
    Add-Result 'The WinUtil run produced a log to check' ([bool]$newLog -and $wuOut.Length -gt 0) `
        'no new log file, so every check below would be measuring an empty string'

    # The exact failure this phase died on for every user, every run.
    $strict = $wuOut -match "property 'runspace' cannot be found"
    Add-Result 'WinUtil survives our strict mode' (-not $strict) `
        'the phase died on Set-StrictMode again - see 04-winutil.ps1'

    # A check that passes because it could not run is not a check. If the
    # handoff never happened - no network, the third party moved - this says so
    # rather than reporting success for something it never observed.
    $reached  = $wuOut -match 'Handing off to winutil'
    $finished = $wuOut -match 'WinUtil phase complete'
    Add-Result 'WinUtil handoff was actually reached' $reached `
        'the run never got as far as invoking winutil, so nothing about it was verified'
    Add-Result 'WinUtil phase completed' $finished `
        "reached the handoff but did not report completion. Output tail: $(($wuOut -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 3) -join ' | ')"
}

# ---------------------------------------------------------------------------
# 6. AppX removal - the protections, checked against a real run.
# ---------------------------------------------------------------------------
# The README promises that shared runtimes, winget and Xbox sign-in are
# protected from removal. Two lists are asserted not to overlap, and the
# removal itself has never been run. That is the same shape as the leftover
# scan, whose two filters both had unit guards and which still offered another
# product's folder the first time it was actually executed.
Write-Host ''
Write-Host '--- AppX removal ---' -ForegroundColor Cyan

$protectedNames = @('DesktopAppInstaller','VCLibs','UI.Xaml','NET.Native','WindowsAppRuntime','XboxIdentityProvider')
$before = @()
try { $before = @(Get-AppxPackage -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }

& $ScriptPath -Apply -Only Appx -NoRestorePoint -NoRestartPrompt | Out-Null

$after = @()
try { $after = @(Get-AppxPackage -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { }
$removed = @($before | Where-Object { $after -notcontains $_ })

# Whatever else happened, nothing on the protected list may have gone.
$lostProtected = @()
foreach ($p in $protectedNames) {
    $had = @($before | Where-Object { $_ -like "*$p*" })
    foreach ($h in $had) { if ($after -notcontains $h) { $lostProtected += $h } }
}
Add-Result 'AppX removal spared everything protected' ($lostProtected.Count -eq 0) `
    "removed protected package(s): $($lostProtected -join ', ')"

# And say plainly when that proved nothing. A Windows Sandbox image carries
# none of the packages this phase removes, so the check above passes here
# without the removal path ever having run.
if ($removed.Count -eq 0) {
    Add-Result 'AppX removal was exercised' $false -Inconclusive `
        ("nothing on this image matched the removal list ($($before.Count) package(s) present), " +
         'so the protections were not put to the test. Run this on an image with Store apps to verify them.')
} else {
    Add-Result 'AppX removal was exercised' $true "removed $($removed.Count): $($removed -join ', ')"
}

# ---------------------------------------------------------------------------
Write-Host ''
$failed = @($results | Where-Object { $_.State -eq 'FAIL' })
$skipped = @($results | Where-Object { $_.State -eq 'SKIP' })
$passed  = @($results | Where-Object { $_.State -eq 'PASS' })

if ($skipped.Count) {
    Write-Host "$($skipped.Count) check(s) could not be carried out here:" -ForegroundColor Yellow
    foreach ($s in $skipped) { Write-Host "  - $($s.Check)" -ForegroundColor Yellow }
    Write-Host ''
}

if ($failed.Count -eq 0) {
    Write-Host "$($passed.Count) CHECKS PASSED$(if ($skipped.Count) { ", $($skipped.Count) NOT VERIFIED HERE" })" `
        -ForegroundColor $(if ($skipped.Count) { 'Yellow' } else { 'Green' })
    exit 0
} else {
    Write-Host "$($failed.Count) of $($results.Count) CHECKS FAILED" -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "  - $($f.Check)" -ForegroundColor Red }
    exit 1
}
