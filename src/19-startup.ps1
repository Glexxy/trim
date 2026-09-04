# ---------------------------------------------------------------------------
#  Startup items
#
#  What actually runs when you log in, gathered from the four places Windows
#  keeps it, and a way to switch any of it off.
#
#  Task Manager shows this list too. What it does not show is where each entry
#  lives, and it will not tell you that the thing you just disabled was put
#  there by a driver package that will quietly put it back. So this reports the
#  source of every entry, and disables things the way Windows itself does -
#  reversibly, without deleting anybody's shortcut.
# ---------------------------------------------------------------------------

# Windows records "disabled" for Run entries in an ApprovedRun key rather than
# by deleting the value: a 12-byte blob whose first byte is 2 for enabled and 3
# for disabled. Writing that, instead of removing the Run value, is what lets
# Task Manager and Settings agree with us afterwards - and what lets the user
# turn it back on without Trim being installed, which it is not.
$script:StartupApprovedEnabled  = [byte[]](2,0,0,0,0,0,0,0,0,0,0,0)
$script:StartupApprovedDisabled = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)

# Built rather than declared, because the machine-wide Run key exists in a
# 32-bit view as well and that view only exists on 64-bit Windows.
# Get-SoftwareHivePaths already answers "which HKLM software roots are real
# here", so the answer lives in one place instead of being re-derived.
$script:StartupRunKeys = @(
    @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
       Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
       Scope = 'You' }
)
# $startupHive, not $root: this runs at script scope when the module is
# dot-sourced, so a common name here silently overwrites the caller's variable.
# The test harness keeps the repository path in $root, and this cost it five
# passing tests before the name was changed.
foreach ($startupHive in (Get-SoftwareHivePaths 'Microsoft\Windows\CurrentVersion')) {
    $script:StartupRunKeys += @{
        Run      = "$startupHive\Run"
        Approved = "$startupHive\Explorer\StartupApproved\Run"
        Scope    = if ($startupHive -match 'WOW6432Node') { 'All users (32-bit)' } else { 'All users' }
    }
}

<#
.SYNOPSIS
    Pull the publisher out of a command line, so the list is readable.

.DESCRIPTION
    A Run value is a command line, not a path: quoted or not, with or without
    arguments, sometimes rundll32 pointing at something else entirely. This
    takes the best guess at the executable and asks the file who signed it.
#>
function Get-StartupPublisher {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return '' }

    $exe = $null
    if ($Command -match '^\s*"([^"]+)"') {
        $exe = $Matches[1]
    } elseif ($Command -match '^\s*([^\s]+\.(exe|com|bat|cmd))') {
        $exe = $Matches[1]
    } else {
        $exe = ($Command -split '\s+')[0]
    }

    try {
        $exe = [Environment]::ExpandEnvironmentVariables($exe)
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf -ErrorAction Stop)) { return '' }
        $info = (Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo
        if ($info.CompanyName) { return $info.CompanyName.Trim() }
    } catch { }
    return ''
}

<#
.SYNOPSIS
    Everything that runs at logon, and where it comes from.

.DESCRIPTION
    Four sources, because Windows has four:
      * Run keys, per user and machine-wide, 64- and 32-bit
      * the two Startup folders
      * scheduled tasks with a logon trigger
    Only the first two can be switched off here. A scheduled task with a logon
    trigger is reported but left alone, because plenty of them are how a driver
    or an antivirus keeps itself working, and this is not the place to find that
    out the hard way.
#>
function Get-StartupItems {
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($k in $script:StartupRunKeys) {
        $full = $k.Run
        try { if (-not (Test-Path -LiteralPath $full -ErrorAction Stop)) { continue } } catch { continue }

        $approvedPath = $k.Approved
        $approved = $null
        try { $approved = Get-ItemProperty -LiteralPath $approvedPath -ErrorAction Stop } catch { }

        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $full -ErrorAction Stop } catch { continue }

        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }

            $state = 'Enabled'
            if ($approved -and $approved.PSObject.Properties[$p.Name]) {
                $blob = $approved.($p.Name)
                # The first byte carries the state: even means enabled, odd
                # means disabled. Windows writes 2 and 3, but 6 and 7 both turn
                # up once Task Manager has been used, so test the bit rather
                # than comparing to a literal.
                if ($blob -and $blob.Count -gt 0 -and ($blob[0] -band 1)) { $state = 'Disabled' }
            }

            $items.Add([pscustomobject]@{
                Name      = $p.Name
                Command   = [string]$p.Value
                Publisher = Get-StartupPublisher -Command ([string]$p.Value)
                Source    = 'Registry'
                Scope     = $k.Scope
                Location  = $full
                Approved  = $approvedPath
                State     = $state
                CanChange = $true
            }) | Out-Null
        }
    }

    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup');       Scope = 'You' },
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Scope = 'All users' }
    )
    foreach ($f in $folders) {
        if (-not $f.Path) { continue }
        try { if (-not (Test-Path -LiteralPath $f.Path -ErrorAction Stop)) { continue } } catch { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $f.Path -File -Force -ErrorAction SilentlyContinue)) {
            if ($file.Extension -eq '.ini') { continue }
            $items.Add([pscustomobject]@{
                Name      = $file.BaseName
                Command   = $file.FullName
                Publisher = Get-StartupPublisher -Command $file.FullName
                Source    = 'Startup folder'
                Scope     = $f.Scope
                Location  = $f.Path
                Approved  = ''
                State     = 'Enabled'
                CanChange = $true
            }) | Out-Null
        }
    }

    # Logon-triggered scheduled tasks, reported only.
    try {
        $sched = New-Object -ComObject Schedule.Service
        $sched.Connect()
        $folder = $sched.GetFolder('\')
        foreach ($t in $folder.GetTasks(0)) {
            if ($t.Enabled -ne $true) { continue }
            if ($t.Definition.Triggers | Where-Object { $_.Type -eq 9 }) {   # TASK_TRIGGER_LOGON
                $items.Add([pscustomobject]@{
                    Name      = $t.Name
                    Command   = ($t.Definition.Actions | ForEach-Object { $_.Path }) -join ' '
                    Publisher = ''
                    Source    = 'Scheduled task'
                    Scope     = 'All users'
                    Location  = $t.Path
                    Approved  = ''
                    State     = 'Enabled'
                    CanChange = $false
                }) | Out-Null
            }
        }
    } catch { }

    Write-Log "Startup: $($items.Count) item(s) - $(@($items | Where-Object { $_.State -eq 'Enabled' }).Count) enabled."
    return @($items | Sort-Object @{ E = { $_.Source } }, Name)
}

<#
.SYNOPSIS
    Switch a startup item off, the way Windows does it.

.DESCRIPTION
    Registry entries are marked disabled in StartupApproved rather than deleted,
    so Task Manager shows the same state and the user can re-enable without
    this tool. Startup folder shortcuts are moved into a Disabled subfolder
    rather than deleted, because a shortcut somebody put there by hand is not
    ours to destroy.

    Both routes go through the undo ledger, so the run's rollback script puts
    them back.
#>
function Disable-StartupItem {
    param([Parameter(Mandatory)]$Item)

    if (-not $Item.CanChange) {
        Write-Log -Level WARN -Message "Cannot change '$($Item.Name)' from here - it is a $($Item.Source)."
        return $false
    }

    if ($Item.Source -eq 'Registry') {
        if ($Item.State -eq 'Disabled') { return $true }
        # Set-Reg records the prior value first, so undo restores whatever was
        # there - including the absence of the value.
        Set-Reg $Item.Approved $Item.Name $script:StartupApprovedDisabled -Type Binary `
            -Because "startup: $($Item.Name) off" -Tier op
        return $true
    }

    if ($Item.Source -eq 'Startup folder') {
        $dest = Join-Path $Item.Location 'Disabled by Trim'
        if ($DryRun) {
            Write-Log -Level DRY -Message "would move: $($Item.Command) -> $dest"
            return $true
        }
        try {
            New-Item -ItemType Directory -Force -Path $dest -ErrorAction Stop | Out-Null
            $target = Join-Path $dest (Split-Path $Item.Command -Leaf)
            Move-Item -LiteralPath $Item.Command -Destination $target -Force -ErrorAction Stop
            Add-UndoCommand "Move-Item -LiteralPath '$($target -replace "'", "''")' -Destination '$($Item.Command -replace "'", "''")' -Force -ErrorAction SilentlyContinue"
            Write-Log -Level OK -Message "startup: moved $($Item.Name) out of the Startup folder"
            return $true
        } catch {
            Write-Log -Level FAIL -Message "could not move $($Item.Command): $($_.Exception.Message)"
            return $false
        }
    }

    return $false
}

<#
.SYNOPSIS
    Turn a previously disabled registry startup entry back on.
#>
function Enable-StartupItem {
    param([Parameter(Mandatory)]$Item)

    if ($Item.Source -ne 'Registry') {
        Write-Log -Level WARN -Message "Re-enabling '$($Item.Name)' is not something this can do; it is a $($Item.Source)."
        return $false
    }
    Set-Reg $Item.Approved $Item.Name $script:StartupApprovedEnabled -Type Binary `
        -Because "startup: $($Item.Name) on" -Tier op
    return $true
}
