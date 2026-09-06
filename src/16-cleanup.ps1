# ---------------------------------------------------------------------------
# System cleanup
#
# Deliberately NOT part of Invoke-AllPhases. Deleting files is a different kind
# of act from changing a setting: a setting is written down and reversed by the
# undo script, a deleted file is gone. So this is something you navigate to and
# run knowingly, never something a preset does to you in passing.
#
# It sweeps every drive rather than assuming C:, and it reports every location
# separately with its own size, because "we found 14 GB" is not consent. You
# should be able to see exactly which folder on which disk is about to lose
# what before anything happens.
#
# Nothing here globs a whole drive. Every path is named. A cleanup tool that
# walks the filesystem deciding what looks like junk is how people lose work.
# ---------------------------------------------------------------------------

function Format-Bytes {
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes / 1KB) }
    return "$([int]$Bytes) B"
}

<#
.SYNOPSIS
    Every location this tool is prepared to delete from, with its reasoning.

.DESCRIPTION
    Tier means the same thing here as everywhere else. Anything that loses
    something a person might actually want - a rollback, a browser session, a
    crash trail - is opinionated, never safe.
#>
function Get-CleanupDefinitions {
    param([Parameter(Mandatory)]$Drives)

    $d = [System.Collections.Generic.List[object]]::new()
    function Add-Def {
        param([string]$Name, [string]$Why, [string[]]$Paths, [string]$Tier = 'safe',
              [string]$Filter = '*', [int]$OlderThanDays = 0, [switch]$FilesOnly)
        $d.Add([pscustomobject]@{
            Name = $Name; Why = $Why; Paths = @($Paths | Where-Object { $_ })
            Tier = $Tier; Filter = $Filter; OlderThanDays = $OlderThanDays; FilesOnly = [bool]$FilesOnly
        }) | Out-Null
    }

    Add-Def 'Temporary files (your account)' `
        'Everything applications left in your temp folder. Windows recreates what it still needs.' `
        @($env:TEMP, (Join-Path $env:LOCALAPPDATA 'Temp'))

    Add-Def 'Temporary files (system)' `
        'The machine-wide temp folder. Same story, different owner.' `
        @((Join-Path $env:WinDir 'Temp'))

    Add-Def 'Windows Update cache' `
        'Installers for updates that are already installed. Windows re-downloads anything it needs.' `
        @((Join-Path $env:WinDir 'SoftwareDistribution\Download'))

    Add-Def 'Delivery Optimization cache' `
        'Update chunks kept to share with other PCs on your network. Frequently several gigabytes.' `
        @((Join-Path $env:WinDir 'SoftwareDistribution\DeliveryOptimization'),
          (Join-Path $env:WinDir 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization'))

    Add-Def 'Thumbnail and icon cache' `
        'Preview images for your files. Your files are untouched; Windows rebuilds these on demand.' `
        @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')) -Filter '*cache_*.db' -FilesOnly

    Add-Def 'Shader caches' `
        'Compiled shaders from DirectX and the graphics driver. Rebuilt automatically; the first launch of a game may be slightly slower once.' `
        @((Join-Path $env:LOCALAPPDATA 'D3DSCache'),
          (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'),
          (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'),
          (Join-Path $env:APPDATA  'NVIDIA\ComputeCache'),
          (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'),
          (Join-Path $env:LOCALAPPDATA 'AMD\GLCache'),
          (Join-Path $env:LOCALAPPDATA 'Intel\ShaderCache'))

    Add-Def 'Crash dumps and error reports' `
        'Diagnostic files from programs that crashed. Useful only while you are diagnosing that crash.' `
        @((Join-Path $env:LOCALAPPDATA 'CrashDumps'),
          (Join-Path $env:WinDir 'Minidump'),
          (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
          (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive')) -Tier op

    Add-Def 'Windows log files' `
        'Setup, servicing and component logs. Kept only for troubleshooting an install that already finished.' `
        @((Join-Path $env:WinDir 'Logs\CBS'),
          (Join-Path $env:WinDir 'Logs\DISM'),
          (Join-Path $env:WinDir 'Logs\WindowsUpdate'),
          (Join-Path $env:WinDir 'Panther')) -Tier op

    Add-Def 'Old prefetch data' `
        'Launch traces older than 30 days. Windows rebuilds these; recently used apps are left alone.' `
        @((Join-Path $env:WinDir 'Prefetch')) -Tier op -Filter '*.pf' -OlderThanDays 30 -FilesOnly

    Add-Def 'Font cache' `
        'Rebuilt at next sign-in.' `
        @((Join-Path $env:WinDir 'ServiceProfiles\LocalService\AppData\Local\FontCache')) -Tier op

    # Browser caches. Cache only - not cookies, history, passwords or sessions.
    $browserCaches = @()
    foreach ($b in @(
        @{ P = 'Microsoft\Edge\User Data';  L = $true  },
        @{ P = 'Google\Chrome\User Data';   L = $true  },
        @{ P = 'BraveSoftware\Brave-Browser\User Data'; L = $true },
        @{ P = 'Mozilla\Firefox\Profiles';  L = $true  })) {
        $root = Join-Path $env:LOCALAPPDATA $b.P
        try { if (-not (Test-Path -LiteralPath $root -ErrorAction Stop)) { continue } } catch { continue }
        foreach ($prof in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            foreach ($sub in @('Cache\Cache_Data','Code Cache','GPUCache','cache2')) {
                $c = Join-Path $prof.FullName $sub
                try { if (Test-Path -LiteralPath $c -ErrorAction Stop) { $browserCaches += $c } } catch { }
            }
        }
    }
    if ($browserCaches.Count) {
        Add-Def 'Browser caches' `
            'Cached page data only. Your history, passwords, cookies and open tabs are not touched.' `
            $browserCaches -Tier op
    }

    # Per-drive: recycle bins and previous Windows installations.
    $bins = @()
    $olds = @()
    foreach ($drv in $Drives) {
        $bin = Join-Path $drv.Root '$Recycle.Bin'
        $old = Join-Path $drv.Root 'Windows.old'
        try { if (Test-Path -LiteralPath $bin -ErrorAction Stop) { $bins += $bin } } catch { }
        try { if (Test-Path -LiteralPath $old -ErrorAction Stop) { $olds += $old } } catch { }
    }
    if ($bins.Count) {
        Add-Def 'Recycle Bin' 'Files you already deleted, on every drive.' $bins -Tier op
    }
    if ($olds.Count) {
        Add-Def 'Previous Windows installation' `
            'Windows.old. Deleting this removes your ability to roll back to the previous version of Windows. Usually many gigabytes.' `
            $olds -Tier trade
    }

    return @($d)
}

<#
.SYNOPSIS
    Measure what is there, without deleting anything.

.DESCRIPTION
    Returns one row per location, not one per category, because the user needs
    to see which disk and which folder. Locked and in-use files are counted -
    they are genuinely there - but the delete step skips them rather than
    fighting Windows for a handle.
#>
function Get-CleanupScan {
    param([switch]$Quiet)

    $drives = @(Get-StorageInventory)
    if (-not $Quiet) {
        Write-Log "Scanning $($drives.Count) drive(s): $((($drives | ForEach-Object { $_.Letter }) -join ', '))"
    }

    $results = [System.Collections.Generic.List[object]]::new()

    # Two definitions can name the same folder by different routes, and one
    # definition already did: %TEMP% and %LOCALAPPDATA%\Temp are the same
    # directory on any machine that has not moved it. Both were listed, both
    # were scanned, and the bytes were counted twice - so the pane showed the
    # folder twice and overstated what deleting it would free, on the category
    # total, the headline total and the selected total alike.
    #
    # Listing both is still right: %TEMP% can be redirected. Counting both is
    # not. Keyed on the resolved path, so a redirected %TEMP% is a second entry
    # and an unredirected one is not.
    $seenPaths = @{}

    foreach ($def in (Get-CleanupDefinitions -Drives $drives)) {
        foreach ($path in $def.Paths) {
            # Test-Path THROWS on a directory the current user cannot read - it
            # does not return false. Unelevated, that is several of these, and an
            # unhandled throw here would spray access-denied errors at anyone who
            # simply opened the cleanup pane.
            $exists = $false
            try { $exists = Test-Path -LiteralPath $path -ErrorAction Stop } catch { $exists = $false }
            if (-not $exists) { continue }

            # Resolve before comparing: '%TEMP%' and '%LOCALAPPDATA%\Temp'
            # expand to different strings and the same directory. Falls back to
            # the literal path if it cannot be resolved, which is no worse than
            # not deduplicating at all.
            $resolved = $path
            try { $resolved = (Get-Item -LiteralPath $path -Force -ErrorAction Stop).FullName } catch { }
            $key = $resolved.TrimEnd('\').ToLowerInvariant()
            if ($seenPaths.ContainsKey($key)) { continue }
            $seenPaths[$key] = $true

            $bytes = 0L
            $count = 0
            $cutoff = if ($def.OlderThanDays -gt 0) { (Get-Date).AddDays(-$def.OlderThanDays) } else { $null }

            try {
                $files = Get-ChildItem -LiteralPath $path -Filter $def.Filter -File -Recurse -Force -ErrorAction SilentlyContinue
                foreach ($f in $files) {
                    if ($cutoff -and $f.LastWriteTime -gt $cutoff) { continue }
                    $bytes += $f.Length
                    $count++
                }
            } catch { }

            if ($count -eq 0) { continue }

            $drive = ($path -replace '^([A-Za-z]):.*$', '$1')
            $results.Add([pscustomobject]@{
                Category = $def.Name
                Why      = $def.Why
                Tier     = $def.Tier
                Path     = $path
                Drive    = $drive
                Bytes    = $bytes
                Size     = Format-Bytes $bytes
                Count    = $count
                Filter   = $def.Filter
                OlderThanDays = $def.OlderThanDays
                Selected = ($def.Tier -eq 'safe')
                Key      = "clean|$path"
            }) | Out-Null
        }
    }

    if (-not $Quiet) {
        # A machine with nothing to clean is the whole point of scanning, and it
        # is exactly the case that made this throw when it was written the
        # obvious way. The window never saw it because the window scans -Quiet.
        $total = Get-SumOrZero -Items @($results) -Property Bytes
        Write-Log "Found $(Format-Bytes ([double]$total)) across $($results.Count) location(s)."
    }
    return @($results | Sort-Object Bytes -Descending)
}

<#
.SYNOPSIS
    Find identical files, by content, in the places duplicates actually collect.

.DESCRIPTION
    Size first, then a hash of only the same-size candidates - hashing every file
    on a disk to find duplicates is how these tools end up taking an hour.

    Nothing is pre-selected. The newest copy of each set is marked as the one to
    keep, and only the others are offered, but the whole thing is off by default
    because "these two files are identical" is not the same as "you do not want
    both of them".
#>
function Get-DuplicateScan {
    param(
        [string[]]$Roots = @(),
        [int]$MinimumMB = 1
    )

    if (-not $Roots -or $Roots.Count -eq 0) {
        $Roots = @(
            (Join-Path $env:USERPROFILE 'Downloads'),
            (Join-Path $env:USERPROFILE 'Documents'),
            (Join-Path $env:USERPROFILE 'Desktop')
        ) | Where-Object { Test-Path -LiteralPath $_ }
    }

    Write-Log "Looking for duplicates in: $($Roots -join ', ')"
    $min = $MinimumMB * 1MB

    $bySize = @{}
    foreach ($root in $Roots) {
        try {
            foreach ($f in (Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)) {
                if ($f.Length -lt $min) { continue }
                if (-not $bySize.ContainsKey($f.Length)) { $bySize[$f.Length] = [System.Collections.Generic.List[object]]::new() }
                $bySize[$f.Length].Add($f) | Out-Null
            }
        } catch {
            Write-Log -Level WARN -Message "could not scan '$root': $($_.Exception.Message)"
        }
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($size in $bySize.Keys) {
        $candidates = @($bySize[$size])
        if ($candidates.Count -lt 2) { continue }

        $byHash = @{}
        foreach ($f in $candidates) {
            try {
                $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            } catch { continue }
            if (-not $byHash.ContainsKey($h)) { $byHash[$h] = [System.Collections.Generic.List[object]]::new() }
            $byHash[$h].Add($f) | Out-Null
        }

        foreach ($h in $byHash.Keys) {
            $set = @($byHash[$h] | Sort-Object LastWriteTime -Descending)
            if ($set.Count -lt 2) { continue }
            $keep = $set[0]
            foreach ($dupe in ($set | Select-Object -Skip 1)) {
                $groups.Add([pscustomobject]@{
                    Category = 'Duplicate files'
                    Why      = "Identical to $($keep.FullName), which is newer and would be kept."
                    Tier     = 'op'
                    Path     = $dupe.FullName
                    Drive    = ($dupe.FullName -replace '^([A-Za-z]):.*$', '$1')
                    Bytes    = $dupe.Length
                    Size     = Format-Bytes $dupe.Length
                    Count    = 1
                    Keeps    = $keep.FullName
                    Selected = $false
                    Key      = "dupe|$($dupe.FullName)"
                }) | Out-Null
            }
        }
    }

    # Finding nothing is the normal outcome, and totalling an empty collection
    # the obvious way throws under Set-StrictMode -Version 2.0.
    $total = Get-SumOrZero -Items @($groups) -Property Bytes
    Write-Log "Found $($groups.Count) duplicate file(s), $(Format-Bytes ([double]$total)) recoverable."
    return @($groups | Sort-Object Bytes -Descending)
}

<#
.SYNOPSIS
    Delete the selected locations, and report honestly what could not be removed.

.DESCRIPTION
    Files in use are skipped rather than forced. A cleanup tool that fights for a
    handle on a file Windows currently has open is how a machine ends up in a
    state nobody can explain.
#>
<#
.SYNOPSIS
    The biggest files on the machine, so somebody can see what is actually
    using the disk.

.DESCRIPTION
    Report only. Nothing here is ever selected, batched or deleted by Trim: a
    large file is not a junk file, and the difference between the two is a
    judgement only the owner can make. A 40 GB game, a 40 GB video project and
    a 40 GB forgotten ISO look identical from here.

    Windows, Program Files and WinSxS are skipped outright. Not because they are
    small - WinSxS in particular is enormous - but because listing them invites
    somebody to delete one, and the honest answer for that space is Disk Cleanup
    and component-store servicing, not a file manager.
#>
function Get-LargeFileScan {
    param(
        [string[]]$Roots = @(),
        [int]$MinimumMB = 256,
        [int]$Top = 60,
        # Five minutes, raised from ninety seconds on 6 September 2026. Ninety
        # was not enough to finish a four-drive desktop, so the list was always
        # partial and the window said nothing about it. Anything that still
        # cannot finish in five minutes reports itself as incomplete.
        [int]$TimeoutSeconds = 300
    )

    if (-not $Roots -or $Roots.Count -eq 0) {
        $Roots = @(Get-StorageInventory | ForEach-Object { "$($_.Letter):\" })
    }

    $min = [int64]$MinimumMB * 1MB
    $script:LargeScanTruncated = $false
    $script:LargeScanSeconds   = $TimeoutSeconds

    # Pruned while walking, not filtered afterwards. The first version of this
    # recursed through all of C:\Windows and then threw the results away, which
    # cost two minutes to return nothing.
    $skip = @(
        $env:WinDir,
        (Join-Path $env:SystemDrive 'System Volume Information'),
        (Join-Path $env:SystemDrive '$Recycle.Bin')
    ) + @(Get-ProgramFilesRoots) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    Write-Log "Looking for files over $(Format-Bytes $min) in: $($Roots -join ', ')"

    # .NET enumeration rather than Get-ChildItem -Recurse: same walk, without
    # building a full FileInfo for every file on the drive, and with control
    # over which directories are entered at all.
    $found = [System.Collections.Generic.List[object]]::new()
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lastTick = [int64]0
    $now = Get-Date
    $pruned = 0
    $timedOut = $false

    foreach ($root in $Roots) {
        try { if (-not [System.IO.Directory]::Exists($root)) { continue } } catch { continue }

        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($root)

        while ($stack.Count -gt 0) {
            if ($clock.Elapsed.TotalSeconds -gt $TimeoutSeconds) { $timedOut = $true; break }

            # Whoever is showing this gets a chance to stay alive. Costs a
            # comparison per directory when nothing is listening, which is the
            # same deal $script:ProgressHook makes.
            if ($script:ScanHook -and ($clock.ElapsedMilliseconds - $lastTick) -gt 400) {
                $lastTick = $clock.ElapsedMilliseconds
                try { & $script:ScanHook ([int]$clock.Elapsed.TotalSeconds) $TimeoutSeconds $found.Count } catch { }
            }

            $dir = $stack.Pop()

            $skipThis = $false
            foreach ($sk in $skip) {
                if ($dir.StartsWith($sk, [StringComparison]::OrdinalIgnoreCase)) { $skipThis = $true; break }
            }
            if ($skipThis) { $pruned++; continue }

            $di = $null
            try { $di = New-Object System.IO.DirectoryInfo $dir } catch { continue }

            try {
                foreach ($sub in $di.EnumerateDirectories()) {
                    # A junction or symlink is another path into somewhere already
                    # being walked. Following them turns this into a loop.
                    if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($sub.FullName)
                }
            } catch { }

            try {
                # EnumerateFiles on a DirectoryInfo yields FileInfo objects whose
                # length and timestamps come from the directory entry. Building a
                # FileInfo from a path string instead costs an extra stat per
                # file, which on a user profile is tens of thousands of them.
                foreach ($info in $di.EnumerateFiles()) {
                    if ($info.Length -lt $min) { continue }
                    $found.Add([pscustomobject]@{
                        Path     = $info.FullName
                        Name     = $info.Name
                        Bytes    = $info.Length
                        Size     = Format-Bytes $info.Length
                        Modified = $info.LastWriteTime
                        Age      = [int]($now - $info.LastWriteTime).TotalDays
                        Kind     = Get-FileKind -Extension $info.Extension -Name $info.Name
                    }) | Out-Null
                }
            } catch { }
        }
        if ($timedOut) { break }
    }

    $ranked = @($found | Sort-Object Bytes -Descending | Select-Object -First $Top)
    $took = [Math]::Round($clock.Elapsed.TotalSeconds, 1)

    # Recorded, not just logged. A 90-second walk gives up on a machine with
    # several large drives, and the window presented what it had as the whole
    # answer - "Largest files - 40 found", with nothing to say the walk had
    # stopped early. Somebody working out where their disk went would get a
    # partial picture and no reason to doubt it. The log said so; nobody reads
    # the log while looking at the window.
    $script:LargeScanTruncated = $timedOut
    $script:LargeScanSeconds   = $TimeoutSeconds

    if ($timedOut) {
        Write-Log -Level WARN -Message "Large-file scan stopped at $TimeoutSeconds s. Showing the largest $($ranked.Count) of $($found.Count) found so far."
    } else {
        Write-Log "Found $($found.Count) file(s) over $(Format-Bytes $min) in ${took}s; showing the largest $($ranked.Count)."
    }
    return $ranked
}

<#
.SYNOPSIS
    A rough label for what a large file is, so a list of paths is readable.
#>
function Get-FileKind {
    param([string]$Extension, [string]$Name = '')

    # Named first, because these are the ones somebody might otherwise try to
    # delete. pagefile.sys is routinely the largest file on a machine and is
    # very often the honest answer to "where did my disk go" - but listing it
    # among "wasted space" without saying what it is invites exactly the wrong
    # action. Windows manages these; deleting one by hand breaks things.
    switch -Regex ($Name) {
        '^pagefile\.sys$'  { 'Windows paging file - leave alone' ; return }
        '^swapfile\.sys$'  { 'Windows swap file - leave alone' ; return }
        '^hiberfil\.sys$'  { 'Hibernation file - disable hibernation to reclaim' ; return }
        '^DumpStack\.log'  { 'Windows crash stack - leave alone' ; return }
    }

    switch -Regex ($Extension) {
        '\.(iso|img|vhdx?|wim|esd)$'            { 'Disk image' ; break }
        '\.(mp4|mkv|avi|mov|wmv|webm)$'          { 'Video' ; break }
        '\.(zip|7z|rar|tar|gz|xz)$'              { 'Archive' ; break }
        '\.(exe|msi|msix|appx)$'                 { 'Installer' ; break }
        '\.(pak|vpk|bsa|ba2|pck|assets|bundle)$' { 'Game data' ; break }
        '\.(psd|ai|prproj|aep|blend|fbx)$'       { 'Project file' ; break }
        '\.(dmp|etl|log)$'                       { 'Diagnostic' ; break }
        '\.(bak|old|tmp)$'                       { 'Backup or temp' ; break }
        default                                  { 'File' }
    }
}

function Invoke-Cleanup {
    param(
        [Parameter(Mandatory)]$Items,
        [switch]$WhatIfOnly
    )

    $freed   = 0L
    $removed = 0
    $skipped = 0

    foreach ($item in @($Items)) {
        if (-not $item.Selected) { continue }

        if ($WhatIfOnly -or $DryRun) {
            Write-Log -Level DRY -Message "would free $($item.Size) from $($item.Path)"
            $freed += $item.Bytes
            continue
        }

        # A duplicate is one named file. A category is a folder's contents - the
        # folder itself stays, because half of these are recreated by Windows
        # only if the directory is still there.
        if ($item.Key -like 'dupe|*') {
            try {
                $len = (Get-Item -LiteralPath $item.Path -Force -ErrorAction Stop).Length
                Remove-Item -LiteralPath $item.Path -Force -ErrorAction Stop
                $freed += $len; $removed++
            } catch {
                $skipped++
                Write-Log -Level WARN -Message "could not remove '$($item.Path)': $($_.Exception.Message.Trim())"
            }
            continue
        }

        $cutoff = if ($item.OlderThanDays -gt 0) { (Get-Date).AddDays(-$item.OlderThanDays) } else { $null }
        $localFreed = 0L; $localRemoved = 0; $localSkipped = 0
        try {
            $files = Get-ChildItem -LiteralPath $item.Path -Filter $item.Filter -File -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                if ($cutoff -and $f.LastWriteTime -gt $cutoff) { continue }
                try {
                    $len = $f.Length
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $localFreed += $len; $localRemoved++
                } catch {
                    $localSkipped++      # in use; leave it alone
                }
            }
            # Tidy up directories that are now empty, but never the root itself.
            Get-ChildItem -LiteralPath $item.Path -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object {
                    try {
                        if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                    } catch { }
                }
        } catch {
            Write-Log -Level WARN -Message "could not clean '$($item.Path)': $($_.Exception.Message.Trim())"
        }

        $freed += $localFreed; $removed += $localRemoved; $skipped += $localSkipped
        $note = if ($localSkipped -gt 0) { " ($localSkipped in use, left alone)" } else { '' }
        Write-Log -Level OK -Message "$($item.Category): freed $(Format-Bytes ([double]$localFreed)) from $($item.Path)$note"
    }

    Write-Log ''
    if ($WhatIfOnly -or $DryRun) {
        Write-Log -Level DRY -Message "would free about $(Format-Bytes ([double]$freed))"
    } else {
        Write-Log -Level OK -Message "Freed $(Format-Bytes ([double]$freed)) - $removed file(s) removed, $skipped in use and left alone."
    }
    return [pscustomobject]@{ Freed = $freed; Removed = $removed; Skipped = $skipped }
}

<#
.SYNOPSIS
    Command-line entry point. The window has its own.
#>
function Invoke-CleanupPhase {
    param([switch]$IncludeDuplicates, [switch]$ReportLargeFiles)
    Write-Phase 'Cleanup'

    # Printed before the cleanup list and never mixed into it: these are
    # reported, not removed.
    if ($ReportLargeFiles) {
        # Five minutes of nothing on a console reads as a hang too, and the
        # window is not the only way in here. One line, rewritten in place, and
        # only when there is a console to write it to.
        $spinner = $null
        if (-not $script:Quiet) {
            $spinner = {
                param($elapsed, $budget, $found)
                Write-Host ("`r  scanning... {0}s of {1}s, {2} file(s) so far   " -f $elapsed, $budget, $found) -NoNewline -ForegroundColor DarkGray
            }
        }
        $script:ScanHook = $spinner
        try   { $big = @(Get-LargeFileScan) }
        finally {
            $script:ScanHook = $null
            if ($spinner) { Write-Host ("`r" + (' ' * 60) + "`r") -NoNewline }
        }
        if ($big.Count) {
            Write-Host ''
            Write-Log "Largest files (reported only, nothing here is deleted):"
            foreach ($f in $big) {
                Write-Log ("    {0}  {1}  ({2}, {3}d old)" -f $f.Size.PadLeft(10), $f.Path, $f.Kind, $f.Age)
            }
            Write-Host ''
        }
    }

    $items = @(Get-CleanupScan)
    if ($IncludeDuplicates) { $items += @(Get-DuplicateScan) }
    if ($items.Count -eq 0) { Write-Log -Level OK -Message 'Nothing to clean.'; return }

    Write-Host ''
    foreach ($grp in ($items | Group-Object Category)) {
        $sum = Get-SumOrZero -Items @($grp.Group) -Property Bytes
        Write-Log "$($grp.Name)  -  $(Format-Bytes ([double]$sum)) in $($grp.Count) location(s)"
        foreach ($i in $grp.Group) { Write-Log "    $($i.Size.PadLeft(10))  $($i.Path)" }
    }
    Write-Host ''
    Invoke-Cleanup -Items $items | Out-Null
}
