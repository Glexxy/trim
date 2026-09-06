# ---------------------------------------------------------------------------
# Core: run state, logging, the undo ledger, and the guarded registry writer.
#
# Nothing in this script writes to the registry except Set-Reg / Remove-Reg.
# That is what makes the undo script trustworthy: if a change did not go through
# the ledger, it does not exist.
# ---------------------------------------------------------------------------

$script:RunRoot   = Join-Path $env:ProgramData 'Trim'
$script:RunStamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$script:LogPath   = Join-Path $script:RunRoot "logs\run_$($script:RunStamp).log"
$script:UndoPath  = Join-Path $script:RunRoot "undo\undo_$($script:RunStamp).ps1"
$script:Ledger    = [System.Collections.Generic.List[object]]::new()
$script:Actions   = [System.Collections.Generic.List[object]]::new()
# Values the script checks and finds already correct. Kept OUT of the ledger so
# the undo path can never be polluted by a no-op, but recorded so that "what does
# this script touch" can be answered completely rather than only listing deltas.
$script:AlreadySet = [System.Collections.Generic.List[object]]::new()

# Reversals that are not a registry write. The ledger proper only knows about
# registry values, which was fine while that was the only thing being changed;
# moving a Startup-folder shortcut is a change too, and an undo script that
# silently ignored it would make the reversibility claim untrue.
$script:UndoExtra = [System.Collections.Generic.List[string]]::new()
$script:Warnings  = [System.Collections.Generic.List[string]]::new()
$script:Applied   = 0

# Whether Checkpoint-Computer actually produced a restore point this run.
# $null until the attempt is made. The window used to tell everyone "a restore
# point was taken" on the finish screen unconditionally, including the runs
# where Windows had refused to make one - which is the single worst thing to be
# wrong about, because it is the rollback people are relying on when they agree
# to any of this.
$script:RestorePointCreated = $null
$script:Skipped   = 0
$script:Phase     = 'startup'

# When $null, everything the phases decide to do gets done - the plain command
# line. When it is a hashtable, only keys present in it are applied: that is how
# the window's selection reaches the phase code without the phase code knowing
# a window exists.
$script:SelectionFilter = $null

# When the window is driving, the console is not the interface. Everything still
# goes to the log file; it just stops scrolling past somebody who asked for an
# application, not a build transcript.
$script:Quiet = $false

# Progress reporting. $script:ProgressHook is set by whatever is showing a bar;
# when it is $null, Step-Progress costs nothing.
$script:ProgressHook  = $null
$script:ProgressTotal = 0
$script:ProgressDone  = 0

# The same deal for a long walk with no total to divide by: set by whatever is
# on screen while Get-LargeFileScan is running, so a five-minute scan does not
# look like a hung window. $null when nobody is listening.
$script:ScanHook = $null

# What Get-AppLeftovers found but its guards refused to offer. Reported to the
# user rather than dropped: the pane's claim is that it shows what survived the
# uninstaller, and a silently filtered list does not.
$script:LeftoversWithheld = [System.Collections.Generic.List[object]]::new()

New-Item -ItemType Directory -Force -Path (Split-Path $script:LogPath)  | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $script:UndoPath) | Out-Null

<#
.SYNOPSIS
    The full path to a Windows system tool.

.DESCRIPTION
    This program runs as administrator, so resolving a bare name like "netsh"
    through PATH means whatever a writable PATH entry happens to contain gets
    executed with those rights. Every external tool is resolved under
    System32 instead, and a missing one is an error rather than a silent
    fallback to something else called the same thing.
#>
function Get-SystemTool {
    param([Parameter(Mandatory)][ValidateSet(
        'powercfg.exe','netsh.exe','reg.exe','sfc.exe','DISM.exe','shutdown.exe','winget.exe'
    )][string]$Name)

    if ($Name -eq 'winget.exe') {
        # Not a System32 tool: it lives in a per-user WindowsApps folder.
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        return $(if ($cmd) { $cmd.Source } else { $null })
    }

    $path = Join-Path $env:WinDir "System32\$Name"
    if (Test-Path -LiteralPath $path) { return $path }
    # Sysnative covers a 32-bit host on 64-bit Windows.
    $native = Join-Path $env:WinDir "Sysnative\$Name"
    if (Test-Path -LiteralPath $native) { return $native }
    Write-Log -Level WARN -Message "System tool not found where expected: $Name"
    return $null
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','FAIL','STEP','DRY')][string]$Level = 'INFO'
    )
    $colour = switch ($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'STEP' { 'Cyan' }
        'DRY'  { 'DarkGray' }
        default { 'Gray' }
    }
    $line = '[{0}] {1,-4} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    # The log file always gets everything. The console only does when it is the
    # interface - and a real failure always is, quiet or not.
    if (-not $script:Quiet -or $Level -eq 'FAIL') { Write-Host $line -ForegroundColor $colour }
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    if ($Level -eq 'WARN' -or $Level -eq 'FAIL') { $script:Warnings.Add($Message) | Out-Null }
}

<#
.SYNOPSIS
    Is this change in the current selection?

.DESCRIPTION
    True when no selection is active, so the command-line path is unaffected.
    Keys match the ones Get-GuiItems builds, which is what keeps the preview and
    the apply honest about each other.
#>
function Test-SelectedChange {
    param([Parameter(Mandatory)][string]$Key)
    if ($null -eq $script:SelectionFilter) { return $true }
    return $script:SelectionFilter.ContainsKey($Key)
}

<#
.SYNOPSIS
    Advance the progress indicator by one unit of work.

.DESCRIPTION
    Status is a single plain line describing what is happening right now, in
    words a person recognises - not the registry path being written.
#>
function Step-Progress {
    param([string]$Status = '')
    $script:ProgressDone++
    if ($script:ProgressHook) {
        $pct = if ($script:ProgressTotal -gt 0) {
            [Math]::Min(100, [int](100 * $script:ProgressDone / $script:ProgressTotal))
        } else { 0 }
        try { & $script:ProgressHook $pct $Status } catch { }
    }
}

function Set-ProgressTotal {
    param([int]$Total)
    $script:ProgressTotal = $Total
    $script:ProgressDone  = 0
}

# Set by whatever is showing progress, so a long scan can say where it is.
$script:PhaseHook = $null

function Write-Phase {
    param([Parameter(Mandatory)][string]$Name)
    $script:Phase = $Name
    if ($script:PhaseHook) { try { & $script:PhaseHook $Name } catch { } }
    Write-Host ''
    Write-Log -Level STEP -Message ("=== $Name " + ('=' * [Math]::Max(0, 58 - $Name.Length)))
}

<#
.SYNOPSIS
    Record a non-registry action so it appears in the manifest.

.DESCRIPTION
    Set-Reg covers registry work. This covers everything else the script does -
    AppX removals, netsh, DISM, the winutil handoff, the NVIDIA import - so that
    a dry run produces a COMPLETE picture of what would happen, not just the
    registry half. The GUI enumerates this to build its checklist.
#>
function Add-PlannedAction {
    param(
        [Parameter(Mandatory)][ValidateSet('appx','command','external','feature','file')][string]$Kind,
        [Parameter(Mandatory)][string]$Target,
        [string]$Detail     = '',
        [string]$Reversible = 'no',
        [ValidateSet('safe','op','trade')][string]$Tier = 'safe'
    )
    if ($null -ne $script:SelectionFilter -and -not $DryRun) {
        # During an apply, an action being recorded means it is about to happen.
        Step-Progress -Status $Target
    }
    $script:Actions.Add([pscustomobject]@{
        Phase      = $script:Phase
        Kind       = $Kind
        Target     = $Target
        Detail     = $Detail
        Reversible = $Reversible
        Tier       = $Tier
    }) | Out-Null
}

# Normalise HKCU:/HKLM: style paths to something both Get-ItemProperty and the
# undo script can consume unambiguously.
function Resolve-RegPath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path -replace '^HKEY_CURRENT_USER\\', 'HKCU:\' `
                 -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM:\' `
                 -replace '^HKEY_CLASSES_ROOT\\', 'HKCR:\'
}

function Get-RegValueOrAbsent {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; KeyExists = $false; Value = $null; Type = $null }
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.GetValueNames() -notcontains $Name) {
        return [pscustomobject]@{ Exists = $false; KeyExists = $true; Value = $null; Type = $null }
    }
    return [pscustomobject]@{
        Exists    = $true
        KeyExists = $true
        Value     = $item.GetValue($Name)
        Type      = $item.GetValueKind($Name)
    }
}

<#
.SYNOPSIS
    The only sanctioned way to write a registry value. Records the prior state
    into the undo ledger before touching anything.
#>
<#
.SYNOPSIS
    Does this change apply to the Windows build we are running on?

.DESCRIPTION
    A good number of these settings are Windows 11 only. Writing them on Windows
    10 is not harmless-but-useless: it creates a registry value the OS never
    reads, it counts towards the change total the interface shows, and the undo
    ledger then carries an entry for something that never did anything. Worse,
    the site tells Windows 10 users the tool "skips whatever does not apply",
    which was not true of anything until this existed.

    Build numbers rather than a version name, because that is what the OS
    actually reports and 22000 is the exact line between 10 and 11.
#>
function Test-BuildApplies {
    param(
        [int]$MinBuild = 0,
        [int]$MaxBuild = 0,
        [string]$What = ''
    )

    if ($MinBuild -le 0 -and $MaxBuild -le 0) { return $true }

    $build = 0
    if ($script:MachineFacts) { $build = [int]$script:MachineFacts.OSBuild }

    # No facts yet means something is calling a phase without detecting the
    # machine first. Applying the change is the wrong default here - silently
    # writing Windows 11 keys to an unknown OS is the exact failure this guards
    # against - but so is silently skipping. Say so, and apply.
    if ($build -le 0) { return $true }

    if ($MinBuild -gt 0 -and $build -lt $MinBuild) {
        Write-Log -Level INFO -Message "skipped (needs build $MinBuild+, this is $build): $What"
        $script:Skipped++
        return $false
    }
    if ($MaxBuild -gt 0 -and $build -gt $MaxBuild) {
        Write-Log -Level INFO -Message "skipped (only for build $MaxBuild and below, this is $build): $What"
        $script:Skipped++
        return $false
    }
    return $true
}

<#
.SYNOPSIS
    Check the changes actually stuck, and say so when they did not.

.DESCRIPTION
    A write can succeed and then be undone by Windows. The value that found
    this is HKCU:\System\GameConfigStore\GameDVR_FSEBehaviorMode: on a profile
    where Game Bar has never initialised, setting it reports success and
    something in the GameDVR stack puts it back to 0 during the same run. Set
    it a second time and it holds.

    That matters more than one setting. This program's entire argument is that
    the ledger is an exact record of what changed - it is what the summary
    counts, what the undo script reverses, and what the site invites people to
    check. A change recorded as made and silently reverted makes the record a
    claim rather than a record.

    So every applied value is read back at the end of the run. Anything that
    did not survive is applied once more, and if it still will not hold it is
    reported by name rather than counted as done. Re-applying is safe: the
    ledger keeps the ORIGINAL prior value, so the undo script still reverses to
    where the machine started, however many times the value was written.
#>
function Confirm-AppliedChanges {
    if ($DryRun) { return }

    # Action is 'set' or 'remove', and every entry carries one. The first
    # version of this filtered on the ABSENCE of an Action property, meaning to
    # exclude removals, and excluded everything - so this whole function
    # selected nothing and returned in silence. Read as a clean result.
    $applied = @($script:Ledger | Where-Object {
        $_.Action -eq 'set' -and -not $_.Intended -and $_.Path -and $_.Name
    })
    if (-not $applied.Count) { return }

    $reverted = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $applied) {
        try { $now = Get-RegValueOrAbsent -Path $e.Path -Name $e.Name } catch { continue }
        if (-not $now.Exists -or "$($now.Value)" -ne "$($e.NewValue)") { $reverted.Add($e) | Out-Null }
    }
    if (-not $reverted.Count) { return }

    Write-Log -Level WARN -Message "$($reverted.Count) change(s) did not survive the run. Applying them again."

    $stuck = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $reverted) {
        $label = "$($e.Path)\$($e.Name)"
        try {
            if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
            New-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $e.NewValue `
                -PropertyType $e.Type -Force -ErrorAction Stop | Out-Null
        } catch {
            $stuck.Add("$label - $($_.Exception.Message.Trim())") | Out-Null
            continue
        }

        $after = $null
        try { $after = Get-RegValueOrAbsent -Path $e.Path -Name $e.Name } catch { }
        if ($after -and $after.Exists -and "$($after.Value)" -eq "$($e.NewValue)") {
            Write-Log -Level OK -Message "re-applied: $label = $($e.NewValue)"
        } else {
            $stuck.Add("$label wanted '$($e.NewValue)', reads '$(if ($after -and $after.Exists) { $after.Value } else { '<absent>' })'") | Out-Null
        }
    }

    foreach ($s in $stuck) {
        Write-Log -Level WARN -Message "would not hold: $s"
    }
    if ($stuck.Count) {
        Write-Log -Level WARN -Message 'Windows is managing these values and putting them back. They are listed above rather than counted as applied.'
    }
}

function Set-Reg {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','QWord','String','ExpandString','MultiString','Binary')]
        [string]$Type = 'DWord',
        [string]$Because = '',

        # How much argument this change deserves. Drives the interface's presets:
        #   safe  - no plausible downside
        #   op    - opinionated; works, but someone may want the opposite
        #   trade - a real cost is being paid for the gain
        [ValidateSet('safe','op','trade')]
        [string]$Tier = 'safe',

        # Windows build range this setting exists on. 22000 means "Windows 11
        # only"; a MaxBuild of 21999 means "Windows 10 and older only".
        [int]$MinBuild = 0,
        [int]$MaxBuild = 0
    )

    $Path = Resolve-RegPath $Path
    if (-not (Test-SelectedChange "reg|$Path|$Name")) { return }

    $label = "$Path\$Name = $Value"
    if ($Because) { $label = "$label  ($Because)" }

    if (-not (Test-BuildApplies -MinBuild $MinBuild -MaxBuild $MaxBuild -What $label)) { return }

    try {
        $prior = Get-RegValueOrAbsent -Path $Path -Name $Name
    } catch {
        # Being refused a read is expected without administrator rights and is
        # not a failure of this program. Anything else is.
        $level = if ($_.Exception.Message -match 'not allowed|denied') { 'WARN' } else { 'FAIL' }
        Write-Log -Level $level -Message "cannot read $Path\$Name - $($_.Exception.Message.Trim())"
        return
    }

    if ($prior.Exists -and "$($prior.Value)" -eq "$Value") {
        $script:Skipped++
        $script:AlreadySet.Add([pscustomobject]@{
            Phase = $script:Phase; Path = $Path; Name = $Name
            NewValue = $Value; Type = $Type; Because = $Because; Tier = $Tier
        }) | Out-Null
        Write-Log -Level INFO -Message "already set: $label"
        return
    }

    # The ledger entry is built the same way whether or not the write happens, so
    # that a dry run produces a complete, machine-readable manifest of everything
    # the script intends to do. Intended=$true means "planned, not performed".
    $entry = [pscustomobject]@{
        Action     = 'set'
        Phase      = $script:Phase
        Path       = $Path
        Name       = $Name
        NewValue   = $Value
        Type       = $Type
        Because    = $Because
        Tier       = $Tier
        HadValue   = $prior.Exists
        OldValue   = $prior.Value
        OldType    = if ($prior.Type) { "$($prior.Type)" } else { $Type }
        KeyExisted = $prior.KeyExists
        Intended   = [bool]$DryRun
    }

    if ($DryRun) {
        $was = if ($prior.Exists) { "$($prior.Value)" } else { '<absent>' }
        Write-Log -Level DRY -Message "would set: $label  [was $was]"
        $script:Ledger.Add($entry) | Out-Null
        return
    }

    try {
        if (-not $prior.KeyExists) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value `
            -PropertyType $Type -Force -ErrorAction Stop | Out-Null

        $script:Ledger.Add($entry) | Out-Null
        $script:Applied++
        Write-Log -Level OK -Message "set: $label"
        Step-Progress -Status $(if ($Because) { $Because } else { $Name })
    } catch {
        Write-Log -Level FAIL -Message "write failed: $label - $($_.Exception.Message)"
    }
}

function Remove-Reg {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string]$Because = '',
        [ValidateSet('safe','op','trade')][string]$Tier = 'safe',
        [int]$MinBuild = 0,
        [int]$MaxBuild = 0
    )
    $Path = Resolve-RegPath $Path
    if (-not (Test-SelectedChange "reg|$Path|$Name")) { return }
    if (-not (Test-BuildApplies -MinBuild $MinBuild -MaxBuild $MaxBuild -What "$Path\$Name  ($Because)")) { return }
    $prior = Get-RegValueOrAbsent -Path $Path -Name $Name
    if (-not $prior.Exists) { $script:Skipped++; return }

    $entry = [pscustomobject]@{
        Action     = 'remove'
        Phase      = $script:Phase
        Path       = $Path
        Name       = $Name
        NewValue   = $null
        Type       = "$($prior.Type)"
        Because    = $Because
        Tier       = $Tier
        HadValue   = $true
        OldValue   = $prior.Value
        OldType    = "$($prior.Type)"
        KeyExisted = $true
        Intended   = [bool]$DryRun
    }

    if ($DryRun) {
        Write-Log -Level DRY -Message "would remove: $Path\$Name  [was $($prior.Value)]"
        $script:Ledger.Add($entry) | Out-Null
        return
    }
    try {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction Stop
        $script:Ledger.Add($entry) | Out-Null
        $script:Applied++
        Write-Log -Level OK -Message "removed: $Path\$Name  ($Because)"
        Step-Progress -Status $(if ($Because) { $Because } else { "removing $Name" })
    } catch {
        Write-Log -Level FAIL -Message "remove failed: $Path\$Name - $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Emits a standalone PowerShell script that reverses every ledger entry, newest
    first. Written even on a partial or failed run.
#>
<#
.SYNOPSIS
    Record a line of PowerShell that reverses a non-registry change.

.DESCRIPTION
    The caller has already made the change and knows exactly how to put it back.
    Quoting is the caller's problem for the same reason it is here: only they
    know which parts are literal.
#>
function Add-UndoCommand {
    param([Parameter(Mandatory)][string]$Line)
    if ($DryRun) { return }
    $script:UndoExtra.Add($Line) | Out-Null
}

function Write-UndoScript {
    if ($DryRun) { return }
    if ($script:Ledger.Count -eq 0 -and $script:UndoExtra.Count -eq 0) {
        Write-Log -Level INFO -Message 'No changes recorded; no undo script written.'
        return
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('#Requires -Version 5.1')
    [void]$sb.AppendLine('# Auto-generated undo script for Trim.')
    [void]$sb.AppendLine("# Run:  $($script:RunStamp)")
    [void]$sb.AppendLine("# Reverses $($script:Ledger.Count) registry change(s)$(if ($script:UndoExtra.Count) { " and $($script:UndoExtra.Count) other change(s)" }), newest first.")
    [void]$sb.AppendLine('# It does NOT undo AppX removals, DISM feature changes, or winutil tweaks.')
    [void]$sb.AppendLine('$ErrorActionPreference = ''Continue''')
    [void]$sb.AppendLine('')

    # Reverse order so that dependent writes unwind correctly.
    for ($i = $script:Ledger.Count - 1; $i -ge 0; $i--) {
        $e = $script:Ledger[$i]
        $p = $e.Path -replace "'", "''"
        $n = $e.Name -replace "'", "''"

        if ($e.HadValue) {
            $v = if ($e.OldValue -is [string]) { "'" + ($e.OldValue -replace "'", "''") + "'" }
                 elseif ($e.OldValue -is [array]) { "@(" + (($e.OldValue | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ',') + ")" }
                 else { "$($e.OldValue)" }
            [void]$sb.AppendLine("if (-not (Test-Path -LiteralPath '$p')) { New-Item -Path '$p' -Force | Out-Null }")
            [void]$sb.AppendLine("New-ItemProperty -LiteralPath '$p' -Name '$n' -Value $v -PropertyType '$($e.OldType)' -Force | Out-Null")
        } else {
            [void]$sb.AppendLine("Remove-ItemProperty -LiteralPath '$p' -Name '$n' -Force -ErrorAction SilentlyContinue")
        }
    }

    # Newest first here too, so a sequence of moves unwinds in the order it was
    # made rather than fighting itself.
    if ($script:UndoExtra.Count) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('# Changes that are not registry values.')
        for ($i = $script:UndoExtra.Count - 1; $i -ge 0; $i--) {
            [void]$sb.AppendLine($script:UndoExtra[$i])
        }
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Write-Host ''Undo complete. Sign out and back in, or reboot, for all changes to take effect.'' -ForegroundColor Green')

    Set-Content -LiteralPath $script:UndoPath -Value $sb.ToString() -Encoding UTF8
    Write-Log -Level OK -Message "Undo script written: $($script:UndoPath)"
}

<#
.SYNOPSIS
    Write the ledger as JSON alongside the undo script.

.DESCRIPTION
    The undo script is for humans; this is for machines. The verification harness
    reads it to assert two things that cannot be checked any other way:
      1. every change the run claims to have made is actually present afterwards
      2. running the undo script returns every one of them to its prior value
    Also written to ledger\latest.json so a verifier does not have to guess at
    timestamps.
#>
function Write-LedgerJson {
    $dir = Join-Path $script:RunRoot 'ledger'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $payload = [pscustomobject]@{
        RunStamp  = $script:RunStamp
        DryRun    = [bool]$DryRun
        UndoPath  = $script:UndoPath
        LogPath   = $script:LogPath
        Applied   = $script:Applied
        Skipped   = $script:Skipped
        Machine   = $script:MachineFacts
        Entries    = @($script:Ledger)
        Actions    = @($script:Actions)
        AlreadySet = @($script:AlreadySet)
    }
    $json = $payload | ConvertTo-Json -Depth 6

    foreach ($p in @((Join-Path $dir "ledger_$($script:RunStamp).json"), (Join-Path $dir 'latest.json'))) {
        Set-Content -LiteralPath $p -Value $json -Encoding UTF8
    }
    Write-Log -Level OK -Message "Ledger written: $(Join-Path $dir 'latest.json')"
}

function New-SafetyRestorePoint {
    if ($NoRestorePoint) { Write-Log -Level WARN -Message 'Restore point skipped by request.'; return }
    if ($DryRun)         { Write-Log -Level DRY  -Message 'would create a system restore point'; return }

    try {
        # System Protection is off by default on many OEM images, and
        # Checkpoint-Computer silently no-ops when it is. Turn it on first.
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop

        # Windows rate-limits restore points to one per 24h unless this is relaxed.
        Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
                -Name 'SystemRestorePointCreationFrequency' -Value 0 `
                -Because 'allow a restore point even if one was made today'

        Checkpoint-Computer -Description 'Before Trim' `
                            -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $script:RestorePointCreated = $true
        Write-Log -Level OK -Message 'System restore point created.'
    } catch {
        $script:RestorePointCreated = $false
        Write-Log -Level WARN -Message "Could not create a restore point: $($_.Exception.Message)"
        Write-Log -Level WARN -Message 'Continuing. The undo script is still your rollback path.'
    }
}

function Test-PhaseEnabled {
    param([Parameter(Mandatory)][string]$Name)
    if ($Only.Count -gt 0) { return $Only -contains $Name }
    return -not ($Skip -contains $Name)
}
