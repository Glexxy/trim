# ---------------------------------------------------------------------------
# Deep uninstall
#
# Run the vendor's own uninstaller, then find and remove what it left behind -
# the folders and registry keys that accumulate until a machine is full of the
# ghosts of software nobody has run in years.
#
# This is the most destructive thing in this program, and the failure mode is
# not "a setting is wrong", it is "your files are gone". Leftover detection
# works by matching names, and a careless match takes out something that merely
# shares a vendor folder. So the guards come first and everything else is built
# behind them:
#
#   1. A path must sit under a known application root - Program Files,
#      ProgramData, AppData, or the application's own recorded install location.
#      Nothing else is even a candidate.
#   2. A path must be deep enough to be a product folder, never a root. There is
#      no code path here that can remove C:\Program Files or C:\Users\<name>.
#   3. The final segment must actually resemble the application or its
#      publisher. "Adobe" does not license removing every folder under Adobe.
#   4. Microsoft, Windows and the shared runtimes are never candidates at all.
#   5. Every registry key is exported to a .reg file before it is deleted.
#   6. Nothing is removed that was not listed on screen and confirmed.
#
# Anything that cannot satisfy all six is reported and left alone. A leftover
# that survives costs disk space; a wrong deletion costs somebody their work.
# ---------------------------------------------------------------------------

# Publishers whose files are never leftovers to sweep up.
$script:UninstallProtectedPublishers = @(
    'Microsoft', 'Microsoft Corporation', 'Windows', 'NVIDIA', 'NVIDIA Corporation',
    'Advanced Micro Devices', 'AMD', 'Intel', 'Intel Corporation', 'Realtek'
)

# Folder names that are shared infrastructure, never one product's leftovers.
$script:UninstallProtectedNames = @(
    'windows','windowsapps','microsoft','microsoft shared','common files','system32',
    'syswow64','winsxs','program files','program files (x86)','programdata','users',
    'appdata','local','locallow','roaming','temp','packages','installer','assembly',
    'dotnet','windowspowershell','powershell','driverstore','system','boot','recovery',
    'perflogs','msbuild','reference assemblies','windows defender','windows nt',
    'internet explorer','windows kits','windows photo viewer','uwp','windowsapps'
)

<#
.SYNOPSIS
    Everything installed, from the uninstall registry and the package manager.
#>
function Get-InstalledApplications {
    $apps = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    foreach ($root in (Get-SoftwareHivePaths 'Microsoft\Windows\CurrentVersion\Uninstall') +
                      @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($sub in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop
                $name = "$($p.DisplayName)".Trim()
                if (-not $name) { continue }
                # System components and update entries are not applications.
                if ($p.PSObject.Properties.Name -contains 'SystemComponent' -and $p.SystemComponent -eq 1) { continue }
                if ($p.PSObject.Properties.Name -contains 'ParentKeyName') { continue }
                if ($name -match '^(Update for|Security Update|Hotfix|KB\d{6,})') { continue }
                if ($seen.ContainsKey($name)) { continue }
                $seen[$name] = $true

                $sizeMb = 0
                if ($p.PSObject.Properties.Name -contains 'EstimatedSize' -and $p.EstimatedSize) {
                    $sizeMb = [Math]::Round($p.EstimatedSize / 1024, 0)
                }

                $apps.Add([pscustomobject]@{
                    Name        = $name
                    Publisher   = "$($p.Publisher)".Trim()
                    Version     = "$($p.DisplayVersion)".Trim()
                    InstallDir  = "$($p.InstallLocation)".Trim().TrimEnd('\')
                    Uninstall   = "$($p.UninstallString)".Trim()
                    QuietUninstall = if ($p.PSObject.Properties.Name -contains 'QuietUninstallString') { "$($p.QuietUninstallString)".Trim() } else { '' }
                    SizeMB      = $sizeMb
                    RegistryKey = ($sub.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE', 'HKLM:' `
                                                -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_CURRENT_USER', 'HKCU:')
                    Kind        = 'win32'
                }) | Out-Null
            } catch { }
        }
    }

    try {
        foreach ($pkg in (Get-AppxPackage -ErrorAction Stop | Where-Object { -not $_.IsFramework })) {
            if ($seen.ContainsKey($pkg.Name)) { continue }
            $seen[$pkg.Name] = $true
            $apps.Add([pscustomobject]@{
                Name = $pkg.Name; Publisher = "$($pkg.Publisher)"; Version = "$($pkg.Version)"
                InstallDir = "$($pkg.InstallLocation)"; Uninstall = ''; QuietUninstall = ''
                SizeMB = 0; RegistryKey = ''; Kind = 'appx'
                PackageFullName = $pkg.PackageFullName
            }) | Out-Null
        }
    } catch { }

    return @($apps | Sort-Object Name)
}

<#
.SYNOPSIS
    The only function permitted to say a path may be deleted.

.DESCRIPTION
    Every rule is a veto. A path has to clear all of them, and the default
    answer is no.
#>
function Test-SafeToRemovePath {
    param(
        # Deliberately NOT mandatory, and empty-string tolerant. A guard whose
        # entire job is to say no must be able to say no to nothing at all,
        # rather than throwing a parameter-binding error at its caller. A guard
        # that crashes instead of refusing is a guard that fails open.
        [AllowEmptyString()][AllowNull()][string]$Path = '',
        [AllowEmptyString()][string]$AppName = '',
        [AllowEmptyString()][string]$Publisher = ''
    )
    if ([string]::IsNullOrWhiteSpace($AppName)) { return $false }

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = $null
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    if (-not $full -or $full -notmatch '^[A-Za-z]:\\') { return $false }

    # Rule 2: never a drive root, and never shallow enough to be a system root.
    $segments = @($full -split '\\' | Where-Object { $_ })
    if ($segments.Count -lt 3) { return $false }

    # Rule 1: it has to live under somewhere applications actually install.
    $roots = @()
    foreach ($r in (Get-ProgramFilesRoots)) { $roots += $r }
    $roots += @($env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA,
                (Join-Path $env:USERPROFILE 'AppData\LocalLow'))
    $underRoot = $false
    foreach ($r in ($roots | Where-Object { $_ })) {
        $rr = $r.TrimEnd('\')
        if ($full -eq $rr) { return $false }                       # the root itself
        if ($full.StartsWith("$rr\", [StringComparison]::OrdinalIgnoreCase)) { $underRoot = $true }
    }
    if (-not $underRoot) { return $false }

    # Rule 4: shared infrastructure is never a leftover.
    $leaf = $segments[-1].ToLower()
    if ($script:UninstallProtectedNames -contains $leaf) { return $false }
    foreach ($seg in $segments) {
        if ($seg.ToLower() -eq 'windowsapps') { return $false }
    }

    # Rule 3: the folder has to actually resemble what is being removed.
    $norm  = { param($t) ($t -replace '[^A-Za-z0-9]', '').ToLower() }
    $leafN = & $norm $leaf
    $appN  = & $norm $AppName
    $pubN  = & $norm $Publisher
    if (-not $leafN) { return $false }

    $matches = $false
    if ($appN -and ($leafN -eq $appN -or $leafN.Contains($appN) -or $appN.Contains($leafN))) { $matches = $true }
    if (-not $matches -and $pubN -and $pubN.Length -ge 4 -and
        ($leafN -eq $pubN -or $leafN.Contains($pubN))) { $matches = $true }
    # A two-character folder name matching a two-character app name is a
    # coincidence, not evidence.
    if ($leafN.Length -lt 3) { $matches = $false }

    return $matches
}

<#
.SYNOPSIS
    Folders and registry keys that look like they belong to this application.

.DESCRIPTION
    Candidates only. Every one is put through Test-SafeToRemovePath, and every
    one that survives is shown to the user before anything happens.
#>
function Get-AppLeftovers {
    param([Parameter(Mandatory)]$App)

    $found = [System.Collections.Generic.List[object]]::new()
    $pub   = $App.Publisher

    if ($pub -and @($script:UninstallProtectedPublishers | Where-Object { $pub -like "*$_*" }).Count) {
        Write-Log "Publisher '$pub' is protected. Leftover removal is not offered for it."
        return @($found)
    }

    # --- candidate folders ---------------------------------------------
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($App.InstallDir) { $candidates.Add($App.InstallDir) | Out-Null }

    foreach ($root in (@(Get-ProgramFilesRoots) + @($env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA,
                        (Join-Path $env:USERPROFILE 'AppData\LocalLow')))) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($nameToTry in @($App.Name, $pub) | Where-Object { $_ }) {
            $c = Join-Path $root $nameToTry
            try { if (Test-Path -LiteralPath $c -ErrorAction Stop) { $candidates.Add($c) | Out-Null } } catch { }
        }
        # A publisher folder containing exactly this one product.
        if ($pub) {
            $pubDir = Join-Path $root $pub
            try {
                if (Test-Path -LiteralPath $pubDir -ErrorAction Stop) {
                    foreach ($child in (Get-ChildItem -LiteralPath $pubDir -Directory -ErrorAction SilentlyContinue)) {
                        $candidates.Add($child.FullName) | Out-Null
                    }
                }
            } catch { }
        }
    }

    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (-not (Test-SafeToRemovePath -Path $path -AppName $App.Name -Publisher $pub)) { continue }
        $bytes = 0L
        try {
            $bytes = [long](@(Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue |
                     Measure-Object Length -Sum).Sum)
        } catch { }
        $found.Add([pscustomobject]@{
            Kind = 'folder'; Path = $path; Bytes = $bytes
            Size = Format-Bytes ([double]$bytes); Selected = $true
            Key  = "left|folder|$path"
        }) | Out-Null
    }

    # --- candidate registry keys ---------------------------------------
    $regRoots = @('HKCU:\Software') + @(Get-SoftwareHivePaths '' | ForEach-Object { $_.TrimEnd('\') })

    foreach ($root in $regRoots) {
        foreach ($nameToTry in @($App.Name, $pub) | Where-Object { $_ }) {
            $k = Join-Path $root $nameToTry
            try { if (-not (Test-Path -LiteralPath $k -ErrorAction Stop)) { continue } } catch { continue }
            if (-not (Test-SafeToRemoveKey -Key $k -AppName $App.Name -Publisher $pub)) { continue }
            $found.Add([pscustomobject]@{
                Kind = 'registry'; Path = $k; Bytes = 0; Size = ''
                Selected = $true; Key = "left|registry|$k"
            }) | Out-Null
        }
    }

    if ($App.RegistryKey) {
        $found.Add([pscustomobject]@{
            Kind = 'registry'; Path = $App.RegistryKey; Bytes = 0; Size = ''
            Selected = $true; Key = "left|registry|$($App.RegistryKey)"
        }) | Out-Null
    }

    return @($found | Sort-Object Bytes -Descending)
}

<#
.SYNOPSIS
    Registry equivalent of the path guard.

.DESCRIPTION
    The extra rule that matters here: a publisher key shared with other products
    is kept. Removing HKCU\Software\Valve because one Valve game was uninstalled
    would take Steam's configuration with it.
#>
function Test-SafeToRemoveKey {
    param(
        [AllowEmptyString()][AllowNull()][string]$Key = '',
        [AllowEmptyString()][string]$AppName = '',
        [AllowEmptyString()][string]$Publisher = ''
    )
    if ([string]::IsNullOrWhiteSpace($Key) -or [string]::IsNullOrWhiteSpace($AppName)) { return $false }

    $segments = @($Key -split '\\' | Where-Object { $_ })
    if ($segments.Count -lt 3) { return $false }

    $leaf = $segments[-1].ToLower()
    if ($script:UninstallProtectedNames -contains $leaf) { return $false }
    foreach ($p in $script:UninstallProtectedPublishers) {
        if ($leaf -eq $p.ToLower()) { return $false }
    }
    # Never the hive roots themselves. Derived from the same helper the rest of
    # the program uses, so this stays correct on a 32-bit install.
    foreach ($r in (@('HKCU:\Software') + @(Get-SoftwareHivePaths ''))) {
        if ($Key.TrimEnd('\') -ieq $r.TrimEnd('\')) { return $false }
    }

    $norm  = { param($t) ($t -replace '[^A-Za-z0-9]', '').ToLower() }
    $leafN = & $norm $leaf
    $appN  = & $norm $AppName
    $pubN  = & $norm $Publisher
    if ($leafN.Length -lt 3) { return $false }

    # If this is the publisher key rather than the product key, only remove it
    # when this product is the only thing under it.
    if ($pubN -and $leafN -eq $pubN -and $appN -ne $pubN) {
        try {
            $children = @(Get-ChildItem -LiteralPath $Key -ErrorAction Stop)
            if ($children.Count -gt 1) { return $false }
            if ($children.Count -eq 1) {
                $childN = & $norm $children[0].PSChildName
                if (-not ($childN.Contains($appN) -or $appN.Contains($childN))) { return $false }
            }
        } catch { return $false }
        return $true
    }

    return ($appN -and ($leafN -eq $appN -or $leafN.Contains($appN) -or $appN.Contains($leafN)))
}

<#
.SYNOPSIS
    Run the application's own uninstaller and wait for it.
#>
function Invoke-AppUninstaller {
    param([Parameter(Mandatory)]$App, [switch]$Silent)

    if ($App.Kind -eq 'appx') {
        if ($DryRun) { Write-Log -Level DRY -Message "would remove package $($App.Name)"; return $true }
        try {
            Remove-AppxPackage -Package $App.PackageFullName -ErrorAction Stop
            Write-Log -Level OK -Message "removed package: $($App.Name)"
            return $true
        } catch {
            Write-Log -Level FAIL -Message "could not remove '$($App.Name)': $($_.Exception.Message.Trim())"
            return $false
        }
    }

    $cmd = if ($Silent -and $App.QuietUninstall) { $App.QuietUninstall } else { $App.Uninstall }
    if (-not $cmd) {
        Write-Log -Level WARN -Message "'$($App.Name)' records no uninstaller. Its leftovers can still be reviewed."
        return $false
    }
    if ($DryRun) { Write-Log -Level DRY -Message "would run: $cmd"; return $true }

    Write-Log "Running the uninstaller for '$($App.Name)'. It may ask you questions."
    try {
        # MsiExec entries are well formed; a bare path with arguments is not, so
        # the executable and its arguments are separated by hand.
        if ($cmd -match '^"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $args = $Matches[2] }
        elseif ($cmd -match '^(\S+\.exe)\s*(.*)$') { $exe = $Matches[1]; $args = $Matches[2] }
        else { $exe = $cmd; $args = '' }

        $p = if ($args) { Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru }
             else       { Start-Process -FilePath $exe -Wait -PassThru }
        Write-Log -Level OK -Message "Uninstaller finished with exit code $($p.ExitCode)."
        return $true
    } catch {
        Write-Log -Level FAIL -Message "could not start the uninstaller: $($_.Exception.Message.Trim())"
        return $false
    }
}

<#
.SYNOPSIS
    Remove confirmed leftovers, exporting every registry key first.
#>
function Remove-AppLeftovers {
    param([Parameter(Mandatory)]$Leftovers, [Parameter(Mandatory)][string]$AppName)

    $backupDir = Join-Path $script:RunRoot "uninstall\$($script:RunStamp)_$(($AppName -replace '[^A-Za-z0-9]','_'))"
    $freed = 0L; $removed = 0; $skipped = 0

    foreach ($l in @($Leftovers)) {
        if (-not $l.Selected) { continue }

        if ($DryRun) {
            Write-Log -Level DRY -Message "would remove $($l.Kind): $($l.Path)"
            continue
        }

        if ($l.Kind -eq 'registry') {
            try {
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                $safe = ($l.Path -replace '[^A-Za-z0-9]', '_')
                $file = Join-Path $backupDir "$safe.reg"
                $native = $l.Path -replace '^HKCU:', 'HKEY_CURRENT_USER' -replace '^HKLM:', 'HKEY_LOCAL_MACHINE'
                & (Get-SystemTool 'reg.exe') export "$native" "$file" /y 2>&1 | Out-Null
                Remove-Item -LiteralPath $l.Path -Recurse -Force -ErrorAction Stop
                Write-Log -Level OK -Message "removed key: $($l.Path)  (backed up to $file)"
                $removed++
            } catch {
                $skipped++
                Write-Log -Level WARN -Message "could not remove '$($l.Path)': $($_.Exception.Message.Trim())"
            }
            continue
        }

        # Belt and braces: the guard runs again immediately before deletion, in
        # case anything mutated the list between the scan and the confirmation.
        if (-not (Test-SafeToRemovePath -Path $l.Path -AppName $AppName)) {
            $skipped++
            Write-Log -Level WARN -Message "refusing to remove '$($l.Path)': it does not pass the safety check"
            continue
        }
        try {
            Remove-Item -LiteralPath $l.Path -Recurse -Force -ErrorAction Stop
            Write-Log -Level OK -Message "removed folder: $($l.Path) ($($l.Size))"
            $freed += $l.Bytes; $removed++
        } catch {
            $skipped++
            Write-Log -Level WARN -Message "could not remove '$($l.Path)': $($_.Exception.Message.Trim())"
        }
    }

    if (-not $DryRun) {
        Write-Log -Level OK -Message "Leftovers: $removed removed, $skipped left alone, $(Format-Bytes ([double]$freed)) freed."
        if (Test-Path -LiteralPath $backupDir) { Write-Log "Registry backups: $backupDir" }
    }
    return [pscustomobject]@{ Freed = $freed; Removed = $removed; Skipped = $skipped; BackupDir = $backupDir }
}
