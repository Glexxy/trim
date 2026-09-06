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

# Everything above hands -ApplySelection a file this test wrote itself, which
# tests the reader against this test's idea of the format rather than against
# the writer. If Invoke-Selection stopped writing Key, or wrote it under another
# name, every case above would still pass and the elevated apply would silently
# do nothing.
#
# So: the real writer produces the file, and the real reader is given that.
$roundTripKey = 'reg|HKCU:\Software\Trim\RoundTrip|Value'
$script:SelectionFilter = $null
$written = $null
try {
    $null = Invoke-Selection -Selection @([pscustomobject]@{
        Key = $roundTripKey; Kind = 'reg'; Phase = 'Privacy'
        Title = 'written by the real writer'; Tier = 'safe' })
    $written = Get-ChildItem (Join-Path $script:RunRoot 'selection') -Filter 'selection_*.json' `
               -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
} catch { }

# Invoke-Selection sets the filter itself on the elevated branch. Cleared here
# on purpose: leaving it set would let the case below pass without the file
# being read at all, which is the shape of half the faults this project has
# found in its own tests.
$script:SelectionFilter = $null
$script:DryRun = $false

if (-not $written) {
    $failures.Add('Invoke-Selection wrote no selection file, so the round trip could not be checked') | Out-Null
    Write-Host 'FAIL  a selection written by the window is readable by the elevated run' -ForegroundColor Red
} else {
    Case 'a selection written by the window is readable by the elevated run' `
         @{ ApplySelection = $written.FullName } {
        param($t)
        if ($t -notcontains 'phases(APPLY)') {
            throw 'the file the writer produced was rejected by the reader'
        }
        if (-not $script:SelectionFilter -or $script:SelectionFilter.Count -ne 1) {
            throw "the round-tripped selection did not reach the filter (count: $(@($script:SelectionFilter).Count))"
        }
        if (-not $script:SelectionFilter.ContainsKey($roundTripKey)) {
            throw "the key came back as '$($script:SelectionFilter.Keys -join ', ')' rather than what was written"
        }
    }
}

Case '-Cleanup runs the sweep and nothing else' @{ Cleanup = $true } {
    param($t)
    if ($t -notcontains 'cleanup')    { throw '-Cleanup did not run the sweep' }
    if ($t -contains 'phases(APPLY)') { throw '-Cleanup applied the tweak phases as well' }
    if ($t -contains 'window-shown')  { throw '-Cleanup opened a window' }
}


# The Memory Integrity crash aborted the Security phase, which is tenth of
# twelve. Whether the undo script still gets written when a phase throws is the
# difference between a half-applied machine you can reverse and one you cannot.
# Invoke-Main does write it from a finally - but nothing had ever thrown, so
# that was read rather than known, and each of the three apply routes has its
# own try/finally to get wrong.
$realPhases = ${function:Invoke-AllPhases}
function Invoke-AllPhases {
    param($Facts)
    Note $(if ($DryRun) { 'phases(dry)' } else { 'phases(APPLY)' })
    # Only the applying pass throws. The window builds its plan through this
    # same function first, and a plan that cannot be built tests nothing.
    if (-not $DryRun) { throw 'a phase blew up part of the way through' }
}
try {
    $routes = @(
        @{ What = '-Apply'; Params = @{ Apply = $true } }
        @{ What = '-ApplySelection'; Params = @{ ApplySelection = $goodSel } }
        @{ What = 'the window'; Params = @{ Gui = $true; WindowGives = @([pscustomobject]@{
               Key = 'reg|HKCU:\Software\Trim\FlowTest|Value'; Kind = 'reg'
               Phase = 'Privacy'; Title = 'a ticked change'; Tier = 'safe' }) } }
    )
    foreach ($route in $routes) {
        Case "a phase that throws still leaves an undo script ($($route.What))" $route.Params {
            param($t)
            if ($t -notcontains 'phases(APPLY)') {
                throw 'the phases never ran, so nothing was asked of the failure path'
            }
            if ($t -notcontains 'undo-script') {
                throw 'a phase threw and no undo script was written - a half-applied run is exactly when you need one'
            }
            if ($t -notcontains 'summary') {
                throw 'the run ended without telling anyone what had happened'
            }
        }
    }
} finally {
    ${function:Invoke-AllPhases} = $realPhases
    $script:SelectionFilter = $null
}


# ---------------------------------------------------------------------------
# -ElevationHash. Nothing had ever run this: it is only set when the script
# stages a copy of itself to elevate, and it ends in `exit 1`, which would take
# any in-process test down with it. So it runs the built artefact as a
# subprocess, which is also the only way to observe the exit code a user gets.
# ---------------------------------------------------------------------------
$artefact = Join-Path $root 'trim.ps1'
if (-not (Test-Path -LiteralPath $artefact)) {
    $failures.Add('trim.ps1 is not built, so the elevation hash check could not be exercised') | Out-Null
    Write-Host 'FAIL  the elevation hash check refuses a file that was tampered with' -ForegroundColor Red
} else {
    $stage   = Join-Path ([IO.Path]::GetTempPath()) "trim-elev-test-$([Guid]::NewGuid().ToString('N')).ps1"
    $tampered = $null
    try {
        Copy-Item -LiteralPath $artefact -Destination $stage -Force
        $good = (Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash

        function Invoke-Staged {
            param([string]$Path, [string]$Hash)
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path `
                       -ElevationHash $Hash -DryRun -Only Fixes -NoRestartPrompt *>&1 | Out-String
            @{ Out = $out; Code = $LASTEXITCODE }
        }

        # A hash that does not match must stop the run before anything else
        # happens, and say why.
        $what = 'the elevation hash check refuses a hash that does not match'
        try {
            $r = Invoke-Staged -Path $stage -Hash ('0' * 64)
            if ($r.Code -ne 1) { throw "it exited $($r.Code), not 1" }
            if ($r.Out -notmatch 'does not match the fingerprint') {
                throw 'it did not say the fingerprint was wrong'
            }
            # Not "DRY RUN": the unelevated-dry-run notice is printed before
            # this check runs, so matching on it would pass whatever happened.
            # The phase banner only appears once the run is under way.
            if ($r.Out -match '=== Fixes') {
                throw 'it went on and ran the phases anyway'
            }
            Write-Host "PASS  $what" -ForegroundColor Green
        } catch {
            Write-Host "FAIL  $what" -ForegroundColor Red
            Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
            $failures.Add($what) | Out-Null
        }

        # The matching hash must get past it, or the refusal above would be
        # satisfied by a check that refuses everything.
        $what = 'the elevation hash check lets the file it was launched with through'
        try {
            $r = Invoke-Staged -Path $stage -Hash $good
            if ($r.Out -match 'does not match the fingerprint') {
                throw 'it refused the very file it hashed'
            }
            if ($r.Out -notmatch '=== Fixes') { throw 'it never reached the phases, so the refusal above proves nothing' }
            Write-Host "PASS  $what" -ForegroundColor Green
        } catch {
            Write-Host "FAIL  $what" -ForegroundColor Red
            Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
            $failures.Add($what) | Out-Null
        }

        # And the thing the check is actually for: a staged file that was added
        # to after it was hashed. This is what the comment on the check claims,
        # now that it no longer claims to stop wholesale replacement - which it
        # cannot, because a file that is not this script does not run this
        # check at all.
        $tampered = Join-Path ([IO.Path]::GetTempPath()) "trim-elev-tampered-$([Guid]::NewGuid().ToString('N')).ps1"
        Copy-Item -LiteralPath $stage -Destination $tampered -Force
        Add-Content -LiteralPath $tampered -Value "`r`nWrite-Host 'TAMPERED PAYLOAD RAN'"
        $what = 'the elevation hash check refuses a file that was appended to after staging'
        try {
            $r = Invoke-Staged -Path $tampered -Hash $good
            if ($r.Out -match 'TAMPERED PAYLOAD RAN') { throw 'the appended payload executed' }
            if ($r.Out -notmatch 'does not match the fingerprint') {
                throw 'an altered file was not refused'
            }
            if ($r.Code -ne 1) { throw "it exited $($r.Code), not 1" }
            Write-Host "PASS  $what" -ForegroundColor Green
        } catch {
            Write-Host "FAIL  $what" -ForegroundColor Red
            Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
            $failures.Add($what) | Out-Null
        }

        # The comment on the check is the only place this defence is described,
        # and it overclaimed until 7 September: it said re-hashing closed the
        # window in which the staged file could be replaced, which it does not.
        $mainSrc = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '99-main.ps1')
        $block = [regex]::Match($mainSrc, '(?s)(#[^\r\n]*\r?\n\s*)*?if \(\$ElevationHash\)')
        $what = 'the elevation hash check does not claim to stop a file being replaced'
        try {
            $lead = $mainSrc.Substring(0, $mainSrc.IndexOf('if ($ElevationHash)'))
            $lead = $lead.Substring([Math]::Max(0, $lead.Length - 1400))
            if ($lead -notmatch 'replace') {
                throw 'it no longer says what it cannot do - restore that or remove this check'
            }
            if ($lead -match 'closes that window') {
                throw 'it claims re-hashing closes the replacement window; a replaced file does not run this check'
            }
            Write-Host "PASS  $what" -ForegroundColor Green
        } catch {
            Write-Host "FAIL  $what" -ForegroundColor Red
            Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
            $failures.Add($what) | Out-Null
        }
    }
    finally {
        Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        if ($tampered) { Remove-Item -LiteralPath $tampered -Force -ErrorAction SilentlyContinue }
        Remove-Item Function:\Invoke-Staged -ErrorAction SilentlyContinue
    }
}


# ---------------------------------------------------------------------------
# -Version. The one thing a user can do to check that what reached their
# machine is what was published, and the site and README both send people to
# it - and it was the only function in src\ that no test could reach at all.
# It short-circuits in the header before Invoke-Main, so it needs a subprocess
# like the elevation checks do.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $artefact)) {
    $failures.Add('trim.ps1 is not built, so -Version could not be exercised') | Out-Null
    Write-Host 'FAIL  -Version prints the hash of the file it is running from' -ForegroundColor Red
} else {
    $selfUrl = ([regex]::Match(
        (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '01-header.ps1')),
        "SelfUrl\s*=\s*'([^']+)'")).Groups[1].Value
    if (-not $selfUrl) { $selfUrl = 'https://trimbloat.com/go' }

    # Saved to a file: it must print that file's real hash, and nothing else.
    $what = '-Version prints the hash of the file it is running from'
    try {
        # Inside the try: a subprocess that cannot even start is a failure of
        # this case, not a reason for the whole file to stop without saying so.
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $artefact -Version *>&1 | Out-String
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "it exited $code" }
        $m = [regex]::Match($out, 'SHA256\s*:\s*([0-9A-Fa-f]{64})')
        if (-not $m.Success) { throw 'it printed no SHA256 at all' }
        $real = (Get-FileHash -LiteralPath $artefact -Algorithm SHA256).Hash
        if ($m.Groups[1].Value -ne $real) {
            throw "it printed $($m.Groups[1].Value) for a file whose hash is $real"
        }
        # The published sidecar is what a user is told to compare against, so
        # the two have to be the same number or the instruction is useless.
        $sidecar = "$artefact.sha256"
        if (Test-Path -LiteralPath $sidecar) {
            $published = ((Get-Content -Raw -LiteralPath $sidecar).Trim() -split '\s+')[0]
            if ($published -ne $real) {
                throw "the built file hashes to $real and the sidecar published beside it says $published"
            }
        }
        $ver = ([regex]::Match(
            (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '01-header.ps1')),
            "TrimVersion\s*=\s*'([^']+)'")).Groups[1].Value
        if ($ver -and $out -notmatch ('Version\s*:\s*' + [regex]::Escape($ver))) {
            throw "it did not print the version the source declares ($ver)"
        }
        if ($out -notmatch [regex]::Escape($selfUrl)) {
            throw "it did not name the canonical URL the rest of the script uses ($selfUrl)"
        }
        # Printing a version must not be a run.
        if ($out -match 'STEP ===' -or $out -match 'restore point') {
            throw 'it did more than print a version'
        }
        Write-Host "PASS  $what" -ForegroundColor Green
    } catch {
        Write-Host "FAIL  $what" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add($what) | Out-Null
    }

    # Piped, which is how almost everyone runs this: there is no file, so there
    # is no hash, and saying one would be a lie about something the reader is
    # being asked to trust. Built as a scriptblock so $PSCommandPath is empty,
    # which is exactly what `iex` leaves behind.
    $what = '-Version on a piped run says it cannot hash anything, and how to'
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
               "& ([scriptblock]::Create((Get-Content -Raw '$artefact'))) -Version" *>&1 | Out-String
        if ($out -match 'SHA256\s*:\s*[0-9A-Fa-f]{64}') {
            throw 'it printed a hash for a file it was not run from'
        }
        if ($out -notmatch 'not available') { throw 'it did not say the hash was unavailable' }
        foreach ($step in @('-OutFile trim.ps1', 'Get-FileHash', '-Version')) {
            if ($out -notmatch [regex]::Escape($step)) {
                throw "the instructions it prints leave out '$step'"
            }
        }
        Write-Host "PASS  $what" -ForegroundColor Green
    } catch {
        Write-Host "FAIL  $what" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
        $failures.Add($what) | Out-Null
    }
}

Remove-Item -LiteralPath $selDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($failures.Count) {
    Write-Host "$($failures.Count) failure(s):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
Write-Host 'The entry point routes every invocation correctly.' -ForegroundColor Green

# Explicit, because this file now runs powershell.exe as a subprocess and one of
# those runs is meant to exit 1. Without this the script inherits that code and
# a passing suite reports a failed build.
exit 0
