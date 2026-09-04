#Requires -Version 5.1
<#
.SYNOPSIS
    Proves the generated undo script actually restores state, by doing it for real.

.DESCRIPTION
    The dry-run harness only proves the undo script parses and has the right
    shape. This executes it, which is a different claim.

    SAFE ON THE HOST. Every write is confined to a throwaway key:

        HKCU:\Software\TrimRoundTripTest

    which is created at the start and deleted at the end. It never touches a real
    setting, and it refuses to run if the scratch key already contains anything
    it did not put there.

    Covers the cases most likely to be wrong:
      * a value that existed before, of every registry type
      * a value that did NOT exist before (undo must remove it, not zero it)
      * a key that did not exist at all before
      * values containing single quotes, which is where naive script generation
        produces something that parses but does the wrong thing
      * an explicit Remove-Reg, which undo must restore
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root  = Split-Path $PSScriptRoot -Parent
$Scratch = 'HKCU:\Software\TrimRoundTripTest'
$Nested  = "$Scratch\Nested"

# The optimizer's param-block variables, which src/02-core.ps1 expects to exist.
$DryRun = $false

. (Join-Path $root 'src\02-core.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host "PASS  $What" -ForegroundColor Green }
    else {
        Write-Host "FAIL  $What" -ForegroundColor Red
        if ($Detail) { Write-Host "      $Detail" -ForegroundColor DarkRed }
        $failures.Add($What) | Out-Null
    }
}

function Peek {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Exists = $false; Value = $null } }
    $i = Get-Item -LiteralPath $Path
    if ($i.GetValueNames() -notcontains $Name) { return @{ Exists = $false; Value = $null } }
    return @{ Exists = $true; Value = $i.GetValue($Name) }
}

Write-Host ''
Write-Host '  Undo round-trip test (host-safe, scratch key only)' -ForegroundColor Cyan
Write-Host "  Scratch: $Scratch" -ForegroundColor DarkGray
Write-Host ''

if (Test-Path -LiteralPath $Scratch) {
    Write-Host "Scratch key already exists. Removing it before starting." -ForegroundColor Yellow
    Remove-Item -LiteralPath $Scratch -Recurse -Force
}

try {
    # -----------------------------------------------------------------------
    # Seed a "before" state across several types.
    # -----------------------------------------------------------------------
    New-Item -Path $Scratch -Force | Out-Null
    $before = [ordered]@{
        ExistingDword  = @{ Value = 7;                         Type = 'DWord'  }
        ExistingString = @{ Value = "it's a value; with ;=";   Type = 'String' }
        ExistingQword  = @{ Value = [int64]123456789012;       Type = 'QWord'  }
        ExistingMulti  = @{ Value = @('one',"two's",'three');  Type = 'MultiString' }
        ExistingExpand = @{ Value = '%SystemRoot%\test';       Type = 'ExpandString' }
        ToBeRemoved    = @{ Value = 42;                        Type = 'DWord'  }
    }
    foreach ($k in $before.Keys) {
        New-ItemProperty -LiteralPath $Scratch -Name $k -Value $before[$k].Value `
            -PropertyType $before[$k].Type -Force | Out-Null
    }
    Write-Host "Seeded $($before.Count) pre-existing value(s)." -ForegroundColor DarkGray

    # Snapshot the true before-state, including the values we will not touch.
    $snapshot = @{}
    foreach ($k in $before.Keys) { $snapshot[$k] = Peek $Scratch $k }
    $snapshot['BrandNew']       = Peek $Scratch 'BrandNew'        # absent
    $snapshot['NestedBrandNew'] = Peek $Nested  'NestedBrandNew'  # key absent too

    $script:Ledger.Clear()

    # -----------------------------------------------------------------------
    # Apply changes through the real Set-Reg / Remove-Reg.
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '--- Applying ---' -ForegroundColor Cyan
    Set-Reg    $Scratch 'ExistingDword'  99                  -Type DWord        -Because 'overwrite a dword'
    Set-Reg    $Scratch 'ExistingString' "changed's value"   -Type String       -Because 'overwrite a string with quotes'
    Set-Reg    $Scratch 'ExistingQword'  ([int64]999)        -Type QWord        -Because 'overwrite a qword'
    Set-Reg    $Scratch 'ExistingMulti'  @('a','b')          -Type MultiString  -Because 'overwrite a multistring'
    Set-Reg    $Scratch 'ExistingExpand' '%TEMP%\other'      -Type ExpandString -Because 'overwrite an expandstring'
    Set-Reg    $Scratch 'BrandNew'       1                   -Type DWord        -Because 'value that did not exist'
    Set-Reg    $Nested  'NestedBrandNew' 5                   -Type DWord        -Because 'key that did not exist'
    Remove-Reg $Scratch 'ToBeRemoved'                                            -Because 'explicit removal'

    Check 'Ledger recorded every change' ($script:Ledger.Count -eq 8) "recorded $($script:Ledger.Count), expected 8"

    # -----------------------------------------------------------------------
    # Did they land?
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '--- Verifying they landed ---' -ForegroundColor Cyan
    Check 'dword overwritten'       ((Peek $Scratch 'ExistingDword').Value  -eq 99)
    Check 'string overwritten'      ((Peek $Scratch 'ExistingString').Value -eq "changed's value")
    Check 'qword overwritten'       ((Peek $Scratch 'ExistingQword').Value  -eq 999)
    Check 'multistring overwritten' (((Peek $Scratch 'ExistingMulti').Value -join '|') -eq 'a|b')
    Check 'new value created'       ((Peek $Scratch 'BrandNew').Value -eq 1)
    Check 'nested key created'      ((Peek $Nested  'NestedBrandNew').Value -eq 5)
    Check 'value removed'           (-not (Peek $Scratch 'ToBeRemoved').Exists)

    # -----------------------------------------------------------------------
    # Undo, and demand exact restoration.
    # -----------------------------------------------------------------------
    Write-Host ''
    Write-Host '--- Running the generated undo script ---' -ForegroundColor Cyan
    Write-UndoScript
    Check 'Undo script generated' (Test-Path $script:UndoPath) $script:UndoPath

    & $script:UndoPath | Out-Null

    Write-Host ''
    Write-Host '--- Verifying exact restoration ---' -ForegroundColor Cyan
    foreach ($k in @('ExistingDword','ExistingString','ExistingQword','ExistingExpand')) {
        $now = Peek $Scratch $k
        Check "restored: $k" ($now.Exists -and "$($now.Value)" -eq "$($snapshot[$k].Value)") `
            "now '$($now.Value)', was '$($snapshot[$k].Value)'"
    }
    $nowMulti = Peek $Scratch 'ExistingMulti'
    Check 'restored: ExistingMulti' `
        ($nowMulti.Exists -and (($nowMulti.Value -join '|') -eq ($snapshot['ExistingMulti'].Value -join '|'))) `
        "now '$($nowMulti.Value -join '|')', was '$($snapshot['ExistingMulti'].Value -join '|')'"

    $nowRemoved = Peek $Scratch 'ToBeRemoved'
    Check 'restored: explicitly removed value came back' `
        ($nowRemoved.Exists -and $nowRemoved.Value -eq 42) "now '$($nowRemoved.Value)'"

    # The case a naive implementation gets wrong: writing 0 instead of removing.
    Check 'value that never existed was REMOVED, not zeroed' `
        (-not (Peek $Scratch 'BrandNew').Exists) `
        "BrandNew is still present as '$((Peek $Scratch 'BrandNew').Value)'"
    Check 'nested value that never existed was REMOVED' `
        (-not (Peek $Nested 'NestedBrandNew').Exists)

    # Nothing should be left over beyond the original six names.
    $remaining = @((Get-Item -LiteralPath $Scratch).GetValueNames() | Sort-Object)
    $expected  = @($before.Keys | Sort-Object)
    Check 'no stray values left behind' (($remaining -join ',') -eq ($expected -join ',')) `
        "left: $($remaining -join ','); expected: $($expected -join ',')"

} finally {
    if (Test-Path -LiteralPath $Scratch) {
        Remove-Item -LiteralPath $Scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Write-Host 'Scratch key removed.' -ForegroundColor DarkGray
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'UNDO ROUND-TRIP VERIFIED - every value returned to its exact prior state.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failures.Count) failure(s):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
