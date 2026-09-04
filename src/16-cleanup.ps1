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
    foreach ($def in (Get-CleanupDefinitions -Drives $drives)) {
        foreach ($path in $def.Paths) {
            # Test-Path THROWS on a directory the current user cannot read - it
            # does not return false. Unelevated, that is several of these, and an
            # unhandled throw here would spray access-denied errors at anyone who
            # simply opened the cleanup pane.
            $exists = $false
            try { $exists = Test-Path -LiteralPath $path -ErrorAction Stop } catch { $exists = $false }
            if (-not $exists) { continue }

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
        $total = ($results | Measure-Object Bytes -Sum).Sum
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

    $total = ($groups | Measure-Object Bytes -Sum).Sum
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
    param([switch]$IncludeDuplicates)
    Write-Phase 'Cleanup'

    $items = @(Get-CleanupScan)
    if ($IncludeDuplicates) { $items += @(Get-DuplicateScan) }
    if ($items.Count -eq 0) { Write-Log -Level OK -Message 'Nothing to clean.'; return }

    Write-Host ''
    foreach ($grp in ($items | Group-Object Category)) {
        $sum = ($grp.Group | Measure-Object Bytes -Sum).Sum
        Write-Log "$($grp.Name)  -  $(Format-Bytes ([double]$sum)) in $($grp.Count) location(s)"
        foreach ($i in $grp.Group) { Write-Log "    $($i.Size.PadLeft(10))  $($i.Path)" }
    }
    Write-Host ''
    Invoke-Cleanup -Items $items | Out-Null
}
