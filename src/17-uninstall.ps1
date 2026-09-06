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
# What a Store app is actually called, who actually made it, and where its icon
# is - all three live in the package manifest, and all three are unusable
# without it. Get-AppxPackage reports the package identity instead: names like
# '5319275A.WhatsAppDesktop' or a bare GUID, and a publisher that is the raw
# certificate subject. A row reading '1527c705-839a-4832-9118-54d4Bd6a0c89'
# next to a Remove button is an accident waiting to be clicked.
#
# One read of the manifest, three answers, and '' wherever there is no answer -
# never a guess.
function Get-AppxManifestInfo {
    param([AllowEmptyString()][string]$InstallLocation)

    $empty = @{ DisplayName = ''; Publisher = ''; Logo = '' }
    if (-not $InstallLocation) { return $empty }
    $manifest = Join-Path $InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $empty }

    try { $text = Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop } catch { return $empty }

    $out = @{ DisplayName = ''; Publisher = ''; Logo = '' }

    # ms-resource: values are indirect strings that need the package's resource
    # index to resolve. Left alone rather than printed raw - 'ms-resource:AppName'
    # tells a reader less than the package name does.
    foreach ($pair in @(@{ Tag = 'DisplayName'; Key = 'DisplayName' },
                        @{ Tag = 'PublisherDisplayName'; Key = 'Publisher' })) {
        $m = [regex]::Match($text, "<$($pair.Tag)>\s*([^<]+?)\s*</$($pair.Tag)>")
        if ($m.Success -and $m.Groups[1].Value -notmatch '^ms-resource:') {
            $out[$pair.Key] = $m.Groups[1].Value
        }
    }

    $m = [regex]::Match($text, '<Logo>\s*([^<]+?)\s*</Logo>')
    if (-not $m.Success) { return $out }

    $full = Join-Path $InstallLocation ($m.Groups[1].Value -replace '/', '\')
    if (Test-Path -LiteralPath $full -PathType Leaf) { $out.Logo = $full; return $out }

    # Packaged assets usually ship only in scale-qualified form -
    # Square44x44Logo.scale-200.png, never Square44x44Logo.png. Prefer the
    # unscaled size so a 24px slot is not fed a 400% asset.
    $dir  = Split-Path -Parent $full
    $base = [IO.Path]::GetFileNameWithoutExtension($full)
    $ext  = [IO.Path]::GetExtension($full)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $out }

    $cand = @(Get-ChildItem -LiteralPath $dir -Filter "$base*$ext" -File -ErrorAction SilentlyContinue)
    if (-not $cand.Count) { return $out }
    foreach ($prefer in @('scale-100', 'targetsize-48', 'scale-200')) {
        $hit = @($cand | Where-Object { $_.Name -like "*$prefer*" })
        if ($hit.Count) { $out.Logo = $hit[0].FullName; return $out }
    }
    $out.Logo = (@($cand | Sort-Object { $_.Name.Length })[0]).FullName
    return $out
}

# The name the Start menu shows, per package family.
#
# Microsoft's own inbox apps put an ms-resource: reference in their manifest
# rather than a name - 'ms-resource:AppStoreName' - and resolving those against
# the package resource index fails for most of them (ERROR_MRM_MAP_NOT_FOUND),
# so the manifest is no help. Without this, Media Player is listed as
# 'ZuneMusic', Snipping Tool as 'ScreenSketch', and Phone Link as 'YourPhone' -
# on the one screen where being sure what you are deleting matters most.
#
# Get-StartApps has already done the resolving. Win32 entries have no '!' in
# their AppID and are skipped; their registry name is good enough already.
function Get-StartMenuNames {
    $map = @{}
    try {
        foreach ($s in @(Get-StartApps -ErrorAction Stop)) {
            $id = "$($s.AppID)"
            if ($id -match '^([^!]+)!' -and "$($s.Name)".Trim()) { $map[$Matches[1]] = "$($s.Name)".Trim() }
        }
    } catch { }
    return $map
}

# '5319275A.WhatsAppDesktop' -> 'WhatsAppDesktop'. The leading token is the
# publisher hash, which identifies nothing to a human. Only stripped when what
# remains is still a name; a package called nothing but a GUID stays as it is
# rather than being cut into a shorter GUID.
function Format-AppxPackageName {
    param([AllowEmptyString()][string]$Name)

    if ($Name -notmatch '^([A-Za-z0-9]+)\.(.+)$') { return $Name }
    $rest = $Matches[2]
    if ($rest -match '^[0-9a-f-]{8,}$') { return $Name }
    return $rest
}

# 'CN=Adobe Inc., OU=AAM 256, O=Adobe Inc., L=San Jose, S=ca, ...' -> 'Adobe Inc.'
# The rest of a certificate subject is not information a person needs in order
# to decide whether to uninstall something.
function Format-CertificateSubject {
    param([AllowEmptyString()][string]$Subject)

    if ($Subject -notmatch '(?:^|,)\s*CN=') { return $Subject }
    $m = [regex]::Match($Subject, '(?:^|,)\s*CN=(?:"([^"]*)"|([^,]*))')
    if (-not $m.Success) { return $Subject }
    $cn = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    $cn = $cn.Trim()
    if ($cn) { return $cn }
    return $Subject
}

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

                # Where the app's own icon lives, so the window can show it
                # beside the Remove button. Two apps with near-identical names
                # is exactly when someone uninstalls the wrong one.
                $icon = ''
                if ($p.PSObject.Properties.Name -contains 'DisplayIcon') { $icon = "$($p.DisplayIcon)".Trim() }

                $apps.Add([pscustomobject]@{
                    Name        = $name
                    Publisher   = "$($p.Publisher)".Trim()
                    # A registry entry already carries a human name and a plain
                    # publisher. The fields exist on every app so the window
                    # never has to ask which kind it is holding.
                    DisplayName      = $name
                    PublisherDisplay = "$($p.Publisher)".Trim()
                    Version     = "$($p.DisplayVersion)".Trim()
                    IconSource  = $icon
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

    $startNames = Get-StartMenuNames

    try {
        foreach ($pkg in (Get-AppxPackage -ErrorAction Stop | Where-Object { -not $_.IsFramework })) {
            if ($seen.ContainsKey($pkg.Name)) { continue }

            # Inbox Windows components are signed 'System'. They are packages
            # by construction, not applications anybody installed, and several
            # of them are named as a bare GUID - the Windows file picker shows
            # up as '1527c705-839a-4832-9118-54d4Bd6a0c89'. Offering those for
            # removal beside a Remove button is how somebody breaks Open and
            # Save dialogs in every application at once. The curated AppX phase
            # is where Store apps get removed, with protections.
            if ($pkg.PSObject.Properties.Name -contains 'SignatureKind' -and
                "$($pkg.SignatureKind)" -eq 'System') { continue }
            if ($pkg.PSObject.Properties.Name -contains 'NonRemovable' -and $pkg.NonRemovable) { continue }

            $seen[$pkg.Name] = $true

            $info = Get-AppxManifestInfo -InstallLocation "$($pkg.InstallLocation)"

            # Name and Publisher stay exactly as the platform reports them.
            # They are identity: leftover matching keys off Name, and the
            # protected-publisher list matches on Publisher, so a friendlier
            # spelling of either would quietly change what is safe to delete.
            # The display fields are for the window and nothing else.
            $apps.Add([pscustomobject]@{
                Name = "$($pkg.Name)"; Publisher = "$($pkg.Publisher)"; Version = "$($pkg.Version)"
                # Start menu first: it is the name the person recognises, and
                # the only one that exists for inbox apps.
                DisplayName      = if ($startNames.ContainsKey("$($pkg.PackageFamilyName)")) { $startNames["$($pkg.PackageFamilyName)"] }
                                   elseif ($info.DisplayName)                                { $info.DisplayName }
                                   else                                                      { Format-AppxPackageName -Name "$($pkg.Name)" }
                PublisherDisplay = if ($info.Publisher)   { $info.Publisher }   else { Format-CertificateSubject -Subject "$($pkg.Publisher)" }
                InstallDir = "$($pkg.InstallLocation)"; Uninstall = ''; QuietUninstall = ''
                IconSource = $info.Logo
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
    # Test-SafeToRemoveKey has refused these by name since it was written and
    # this did not, so C:\Program Files\NVIDIA rested entirely on the caller
    # having checked the publisher first. Guards should not depend on their
    # callers being careful.
    foreach ($p in $script:UninstallProtectedPublishers) {
        if ($leaf -eq $p.ToLower()) { return $false }
    }
    foreach ($seg in $segments) {
        if ($seg.ToLower() -eq 'windowsapps') { return $false }
    }

    # Rule 3: the folder has to actually resemble what is being removed.
    $norm  = { param($t) ($t -replace '[^A-Za-z0-9]', '').ToLower() }
    $leafN = & $norm $leaf
    $appN  = & $norm $AppName
    $pubN  = & $norm $Publisher
    if (-not $leafN) { return $false }
    if ($leafN.Length -lt 3) { return $false }

    # If this is the publisher's folder rather than the product's, only remove
    # it when this product is the only thing in it.
    #
    # Test-SafeToRemoveKey has had this rule since it was written - "removing
    # HKCU\Software\Valve because one Valve game was uninstalled would take
    # Steam's configuration with it" - and the same reasoning was never applied
    # here, where the consequence is worse: the registry holds settings, this
    # holds the files. Uninstalling one product offered the whole vendor folder,
    # ticked by default, with every other product from that vendor inside it.
    if ($pubN -and $leafN -eq $pubN -and $appN -ne $pubN) {
        try {
            # -Force: a hidden sibling is still somebody else's data.
            $children = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop)
            if ($children.Count -gt 1) { return $false }
            if ($children.Count -eq 1) {
                $childN = & $norm $children[0].Name
                if (-not ($childN -and ($childN.Contains($appN) -or $appN.Contains($childN)))) { return $false }
            }
        } catch { return $false }
        return $true
    }

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
    one that survives is offered to the user before anything happens.

    What the guards veto is recorded in $script:LeftoversWithheld rather than
    dropped on the floor. The window used to say "These survived the
    uninstaller. Every one is shown in full", which was two different sets: a
    folder the guards refuse to offer is a folder that survived and was never
    mentioned. Somebody checking the list against their own disk would find
    things Trim had not named and conclude the scan was bad, when in fact it
    had decided - correctly - not to touch them.

    Recorded, not offered. Nothing here becomes deletable by being listed.
#>
function Get-AppLeftovers {
    param([Parameter(Mandatory)]$App)

    $found = [System.Collections.Generic.List[object]]::new()
    $pub   = $App.Publisher

    $script:LeftoversWithheld = [System.Collections.Generic.List[object]]::new()

    if ($pub -and @($script:UninstallProtectedPublishers | Where-Object { $pub -like "*$_*" }).Count) {
        Write-Log "Publisher '$pub' is protected. Leftover removal is not offered for it."
        $script:LeftoversWithheld.Add([pscustomobject]@{
            Kind = 'publisher'; Path = $pub
            Why  = 'the publisher is on the protected list, so leftovers are not offered for it at all'
        }) | Out-Null
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
        if (-not (Test-SafeToRemovePath -Path $path -AppName $App.Name -Publisher $pub)) {
            $script:LeftoversWithheld.Add([pscustomobject]@{
                Kind = 'folder'; Path = $path
                Why  = 'shared, protected, or not clearly this app'
            }) | Out-Null
            continue
        }
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
            if (-not (Test-SafeToRemoveKey -Key $k -AppName $App.Name -Publisher $pub)) {
                $script:LeftoversWithheld.Add([pscustomobject]@{
                    Kind = 'registry'; Path = $k
                    Why  = 'shared, protected, or not clearly this app'
                }) | Out-Null
                continue
            }
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

    # --- candidate services --------------------------------------------
    #
    # An uninstaller that removes its files and leaves its service behind is
    # common: the service then fails to start on every boot, forever, and the
    # only trace is an event-log entry nobody reads.
    #
    # Every one goes through Test-SafeToRemoveService, and what it refuses is
    # recorded rather than dropped.
    try {
        foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
            $exe = Get-ServiceImageFile -PathName $svc.PathName

            # Only consider it at all if something connects it to this app.
            # Without this every service on the machine is put through the
            # guard on every scan, which is slow and reads like a fishing trip.
            $related = $false
            if (Test-LeftoverNameMatch -Candidate $svc.Name -AppName $App.Name -Publisher $pub) { $related = $true }
            if (-not $related -and (Test-LeftoverNameMatch -Candidate $svc.DisplayName -AppName $App.Name -Publisher $pub)) { $related = $true }
            if (-not $related -and $exe -and $App.InstallDir) {
                $inst = "$($App.InstallDir)".TrimEnd('\')
                if ($inst -and $exe.StartsWith("$inst\", [StringComparison]::OrdinalIgnoreCase)) { $related = $true }
            }
            if (-not $related) { continue }

            if (-not (Test-SafeToRemoveService -Name $svc.Name -DisplayName $svc.DisplayName `
                                               -ImagePath $svc.PathName -AppName $App.Name -Publisher $pub)) {
                $script:LeftoversWithheld.Add([pscustomobject]@{
                    Kind = 'service'; Path = $svc.Name
                    Why  = 'shared, protected, still depended on, or not clearly this app'
                }) | Out-Null
                continue
            }

            # Whether the binary is still there is the difference between "this
            # is definitely dead" and "this still runs", and the person ticking
            # the box deserves to know which.
            $orphaned = -not ($exe -and (Test-Path -LiteralPath $exe))
            $found.Add([pscustomobject]@{
                Kind = 'service'; Path = $svc.Name; Bytes = 0
                Size = $(if ($orphaned) { 'binary missing' } else { 'binary present' })
                # Off by default. A folder left behind wastes space; a service
                # removed by mistake stops something working, so this one is
                # ticked by a person or not at all.
                Selected = $false
                Detail = "$($svc.DisplayName)"
                Key  = "left|service|$($svc.Name)"
            }) | Out-Null
        }
    } catch {
        Write-Log -Level WARN -Message "Could not read the service list: $($_.Exception.Message.Trim())"
    }

    # --- candidate scheduled tasks --------------------------------------
    try {
        $sched = New-Object -ComObject Schedule.Service
        $sched.Connect()

        $folders = [System.Collections.Generic.List[object]]::new()
        $folders.Add($sched.GetFolder('\')) | Out-Null
        $i = 0
        while ($i -lt $folders.Count) {
            $f = $folders[$i]; $i++
            # \Microsoft is Windows' own, and walking into it only produces
            # candidates the guard will refuse. Skipped at the source.
            try {
                foreach ($sub in $f.GetFolders(0)) {
                    if ("$($sub.Path)" -like '\Microsoft*') { continue }
                    $folders.Add($sub) | Out-Null
                }
            } catch { }

            try { $tasks = @($f.GetTasks(1)) } catch { $tasks = @() }   # 1: include hidden
            foreach ($t in $tasks) {
                $action = ''
                try { $action = @($t.Definition.Actions | ForEach-Object { $_.Path } | Where-Object { $_ })[0] } catch { }

                $related = $false
                foreach ($seg in @("$($t.Path)" -split '\\' | Where-Object { $_ })) {
                    if (Test-LeftoverNameMatch -Candidate $seg -AppName $App.Name -Publisher $pub) { $related = $true; break }
                }
                if (-not $related -and $action -and $App.InstallDir) {
                    $inst = "$($App.InstallDir)".TrimEnd('\')
                    try {
                        $ap = [IO.Path]::GetFullPath($action.Trim('"'))
                        if ($inst -and $ap.StartsWith("$inst\", [StringComparison]::OrdinalIgnoreCase)) { $related = $true }
                    } catch { }
                }
                if (-not $related) { continue }

                if (-not (Test-SafeToRemoveTask -TaskPath $t.Path -ActionPath $action `
                                                -AppName $App.Name -Publisher $pub)) {
                    $script:LeftoversWithheld.Add([pscustomobject]@{
                        Kind = 'task'; Path = "$($t.Path)"
                        Why  = 'a Windows task, or not clearly this app'
                    }) | Out-Null
                    continue
                }

                $found.Add([pscustomobject]@{
                    Kind = 'task'; Path = "$($t.Path)"; Bytes = 0
                    Size = $(if ($t.Enabled) { 'enabled' } else { 'disabled' })
                    Selected = $false
                    Detail = $action
                    Key  = "left|task|$($t.Path)"
                }) | Out-Null
            }
        }
    } catch {
        Write-Log -Level WARN -Message "Could not read the scheduled tasks: $($_.Exception.Message.Trim())"
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
    # Never the hive roots themselves, and never anything outside them.
    #
    # Refusing only the roots was enough while the only caller built its own
    # candidates by joining a name onto one of these. It stopped being enough
    # when this became the check that runs again immediately before deletion:
    # a key from anywhere in the registry would then have been judged on its
    # name alone. The path guard has required its equivalent since it was
    # written. Derived from the same helper the rest of the program uses, so
    # this stays correct on a 32-bit install.
    $underRoot = $false
    foreach ($r in (@('HKCU:\Software') + @(Get-SoftwareHivePaths ''))) {
        $rr = $r.TrimEnd('\')
        if ($Key.TrimEnd('\') -ieq $rr) { return $false }
        if ($Key.StartsWith("$rr\", [StringComparison]::OrdinalIgnoreCase)) { $underRoot = $true }
    }
    if (-not $underRoot) { return $false }

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
    Does this name look like the application being removed?

.DESCRIPTION
    The evidence rule the folder and key guards each spell out inline, written
    once for the two guards added after them. Same normalisation, same minimum
    length, same "a two-character match is a coincidence, not evidence".

    The older two are deliberately left alone: they are load-bearing, they have
    a test asserting they agree with each other, and rewriting them to call this
    is a separate change with its own risk. Four copies would be worse than
    three, which is why the new pair share one.
#>
function Test-LeftoverNameMatch {
    param(
        [AllowEmptyString()][AllowNull()][string]$Candidate = '',
        [AllowEmptyString()][string]$AppName = '',
        [AllowEmptyString()][string]$Publisher = ''
    )
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    if ([string]::IsNullOrWhiteSpace($AppName))   { return $false }

    $norm = { param($t) ($t -replace '[^A-Za-z0-9]', '').ToLower() }
    $c    = & $norm $Candidate
    $appN = & $norm $AppName
    $pubN = & $norm $Publisher

    # Too short to be evidence of anything.
    if (-not $c -or $c.Length -lt 3) { return $false }
    if (-not $appN -or $appN.Length -lt 3) { return $false }

    if ($c -eq $appN -or $c.Contains($appN) -or $appN.Contains($c)) { return $true }
    if ($pubN -and $pubN.Length -ge 4 -and ($c -eq $pubN -or $c.Contains($pubN))) { return $true }
    return $false
}

<#
.SYNOPSIS
    The executable a service actually runs, out of its command line.

.DESCRIPTION
    Win32_Service.PathName is a command line, not a path: it may be quoted, it
    may carry arguments, and svchost-hosted services share one binary with half
    of Windows. Returns the executable alone, or '' when it cannot be read -
    never a guess, because everything downstream decides whether to delete
    something based on where this points.
#>
function Get-ServiceImageFile {
    param([AllowEmptyString()][AllowNull()][string]$PathName = '')
    if ([string]::IsNullOrWhiteSpace($PathName)) { return '' }

    $p = $PathName.Trim()
    if ($p.StartsWith('"')) {
        $end = $p.IndexOf('"', 1)
        if ($end -gt 1) { $p = $p.Substring(1, $end - 1) } else { return '' }
    } else {
        # Unquoted with arguments. Take everything up to the first .exe, which
        # is the only reliable boundary when the path itself contains spaces.
        $m = [regex]::Match($p, '^(?<exe>.*?\.exe)(\s|$)', 'IgnoreCase')
        if ($m.Success) { $p = $m.Groups['exe'].Value } else { $p = ($p -split '\s+')[0] }
    }

    try { return [IO.Path]::GetFullPath($p) } catch { return '' }
}

<#
.SYNOPSIS
    A service's ImagePath, read fresh from the registry.

.DESCRIPTION
    The re-check before deletion must not take the image path from the list it
    was handed: that list is the thing being distrusted. Read at the moment it
    matters, from the only place that decides what the service actually runs.
#>
function Get-ServiceImagePathFromRegistry {
    param([AllowEmptyString()][AllowNull()][string]$Name = '')
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    try {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
        return "$((Get-ItemProperty -LiteralPath $k -Name ImagePath -ErrorAction Stop).ImagePath)"
    } catch { return '' }
}

<#
.SYNOPSIS
    Does this executable live in a folder that belongs to somebody protected?

.DESCRIPTION
    Independent of any name. Pointing the service guard at every service on a
    real machine, with the app name set to each service own name - the most
    favourable evidence there is - allowed AUEPLauncher, which runs out of
    C:\Program Files\AMD\Performance Profile Client. It qualified on the name route while its binary sat in a vendor
    folder the folder guard refuses outright.

    The same lesson Test-SafeToRemovePath already carries in a comment: guards
    should not depend on their callers being careful. Evidence of a name is not
    permission to touch somebody else directory.
#>
function Test-PathUnderProtectedOwner {
    param([AllowEmptyString()][AllowNull()][string]$Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = ''
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return $false }
    if (-not $full) { return $false }

    foreach ($seg in @($full -split '\\' | Where-Object { $_ })) {
        $s = $seg.ToLower()
        foreach ($p in $script:UninstallProtectedPublishers) {
            if ($s -eq $p.ToLower()) { return $true }
        }
        if ($s -eq 'windowsapps') { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    Is this service safe to delete as a leftover of the app being removed?

.DESCRIPTION
    Default no, like its two older siblings, and empty-tolerant for the same
    reason: a guard that throws instead of refusing is a guard that fails open.

    A service is worse to get wrong than a folder. Deleting one takes its
    configuration with it, anything depending on it stops, and the machine may
    need a reboot to be consistent again. So the evidence has to be positive:
    either the binary lives somewhere this application owns, or the service
    names itself after the application.
#>
function Test-SafeToRemoveService {
    param(
        [AllowEmptyString()][AllowNull()][string]$Name = '',
        [AllowEmptyString()][AllowNull()][string]$DisplayName = '',
        [AllowEmptyString()][AllowNull()][string]$ImagePath = '',
        [AllowEmptyString()][string]$AppName = '',
        [AllowEmptyString()][string]$Publisher = ''
    )
    if ([string]::IsNullOrWhiteSpace($AppName)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Name))    { return $false }

    # A protected publisher's service is never a leftover, for the same reason
    # its folders are not.
    foreach ($p in $script:UninstallProtectedPublishers) {
        if ($Publisher -and $Publisher -like "*$p*") { return $false }
    }

    # Windows' own services, whatever they are called. Anything running out of
    # the Windows directory belongs to Windows, and svchost hosts dozens of
    # services at once - deleting one because its shared host matched would be
    # catastrophic and is the obvious way to get this wrong.
    $exe = Get-ServiceImageFile -PathName $ImagePath
    if ($exe) {
        $win = "$env:WinDir".TrimEnd('\')
        if ($win -and $exe.StartsWith("$win\", [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ([IO.Path]::GetFileName($exe).ToLower() -in @('svchost.exe','rundll32.exe','dllhost.exe')) { return $false }
    # Whoever owns the folder owns the service in it, whatever it is called.
        if (Test-PathUnderProtectedOwner -Path $exe) { return $false }
    }

    # Names Windows and its drivers rely on, refused outright whatever they
    # claim to be. Prefix-matched: a name is enough to refuse on, and asking
    # for an exact match invites 'WinDefend2'.
    $protectedServices = @(
        'windefend','wuauserv','bits','winmgmt','rpcss','dcomlaunch','lsm','schedule',
        'eventlog','plugplay','power','profsvc','themes','audiosrv','audioendpointbuilder',
        'dhcp','dnscache','lanmanserver','lanmanworkstation','netlogon','nsi','trustedinstaller',
        'wscsvc','sense','wdnissvc','securityhealthservice','msiserver','cryptsvc','termservice',
        'nvidia','amd','intel','realtek','xbl','xbox','wlansvc','spooler','sysmain','wsearch'
    )
    $n = $Name.ToLower()
    foreach ($p in $protectedServices) {
        if ($n.StartsWith($p)) { return $false }
    }

    # Something else still needs it. Whatever the evidence says, this is not a
    # leftover.
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if (@($svc.DependentServices).Count -gt 0) { return $false }
    } catch {
        # No such service, or it cannot be read. Nothing to delete either way.
        return $false
    }

    # Positive evidence, one of two kinds.
    if ($exe -and (Test-SafeToRemovePath -Path (Split-Path $exe -Parent) -AppName $AppName -Publisher $Publisher)) {
        return $true
    }
    if (Test-LeftoverNameMatch -Candidate $Name -AppName $AppName -Publisher $Publisher) { return $true }
    if (Test-LeftoverNameMatch -Candidate $DisplayName -AppName $AppName -Publisher $Publisher) { return $true }

    return $false
}

<#
.SYNOPSIS
    Is this scheduled task safe to delete as a leftover of the app being removed?

.DESCRIPTION
    Default no. The task folder is the strongest signal there is: everything
    under \Microsoft\ belongs to Windows, and nothing under it is ever a
    leftover of a third-party application no matter what it is called.
#>
function Test-SafeToRemoveTask {
    param(
        [AllowEmptyString()][AllowNull()][string]$TaskPath = '',
        [AllowEmptyString()][AllowNull()][string]$ActionPath = '',
        [AllowEmptyString()][string]$AppName = '',
        [AllowEmptyString()][string]$Publisher = ''
    )
    if ([string]::IsNullOrWhiteSpace($AppName))  { return $false }
    if ([string]::IsNullOrWhiteSpace($TaskPath)) { return $false }
    if (-not $TaskPath.StartsWith('\')) { return $false }

    foreach ($p in $script:UninstallProtectedPublishers) {
        if ($Publisher -and $Publisher -like "*$p*") { return $false }
    }

    # Windows' own tasks live under \Microsoft\. Never ours to remove.
    if ($TaskPath -like '\Microsoft\*') { return $false }

    # The task root itself, or anything that is only one segment deep with no
    # name, is not a task.
    $segments = @($TaskPath -split '\\' | Where-Object { $_ })
    if ($segments.Count -lt 1) { return $false }

    # Anything driven out of the Windows directory is Windows' business.
    if ($ActionPath) {
        $exe = ''
        try { $exe = [IO.Path]::GetFullPath($ActionPath.Trim('"')) } catch { $exe = '' }
        if ($exe) {
            $win = "$env:WinDir".TrimEnd('\')
            if ($win -and $exe.StartsWith("$win\", [StringComparison]::OrdinalIgnoreCase)) { return $false }

            if (Test-PathUnderProtectedOwner -Path $exe) { return $false }
        }
    }

    # Positive evidence: the binary it runs lives somewhere this application
    # owns, or the task or its folder is named after the application.
    if ($ActionPath) {
        $dir = ''
        try { $dir = Split-Path ([IO.Path]::GetFullPath($ActionPath.Trim('"'))) -Parent } catch { $dir = '' }
        if ($dir -and (Test-SafeToRemovePath -Path $dir -AppName $AppName -Publisher $Publisher)) { return $true }
    }
    foreach ($seg in $segments) {
        if (Test-LeftoverNameMatch -Candidate $seg -AppName $AppName -Publisher $Publisher) { return $true }
    }

    return $false
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

        # unbounded-by-design: this is the vendor's own uninstaller and the
        # run says so - "It may ask you questions." Somebody is sitting in
        # front of it answering them. A timeout here closes a dialog they are
        # mid-way through reading, and leaves their application half-removed.
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
    param(
        [Parameter(Mandatory)]$Leftovers,
        [Parameter(Mandatory)][string]$AppName,
        # Without this the re-check below is a stricter guard than the one that
        # built the list, not the same one: anything that qualified because it
        # matched the publisher gets refused at the last moment, and the user
        # is told their tick "does not pass the safety check" after the fact.
        [AllowEmptyString()][string]$Publisher = ''
    )

    $backupDir = Join-Path $script:RunRoot "uninstall\$($script:RunStamp)_$(($AppName -replace '[^A-Za-z0-9]','_'))"
    $freed = 0L; $removed = 0; $skipped = 0

    foreach ($l in @($Leftovers)) {
        if (-not $l.Selected) { continue }

        if ($DryRun) {
            Write-Log -Level DRY -Message "would remove $($l.Kind): $($l.Path)"
            continue
        }

        if ($l.Kind -eq 'service') {
            # Belt and braces, the same as the folder and key branches. Five
            # rules once existed in one half of this module and not the other;
            # a new kind arriving without its second check is how that happens
            # again.
            if (-not (Test-SafeToRemoveService -Name $l.Path -DisplayName $l.Detail `
                                               -ImagePath (Get-ServiceImagePathFromRegistry -Name $l.Path) `
                                               -AppName $AppName -Publisher $Publisher)) {
                $skipped++
                Write-Log -Level WARN -Message "refusing to remove service '$($l.Path)': it does not pass the safety check"
                continue
            }
            try {
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                # The service's whole definition, exported before it is gone.
                # Importing this back and rebooting is what restores it.
                $safe   = ($l.Path -replace '[^A-Za-z0-9]', '_')
                $file   = Join-Path $backupDir "service_$safe.reg"
                $native = "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$($l.Path)"
                & (Get-SystemTool 'reg.exe') export "$native" "$file" /y 2>&1 | Out-Null
                if (-not (Test-Path -LiteralPath $file)) {
                    throw 'the service definition could not be exported, so it is being left alone'
                }

                $sc = Get-SystemTool 'sc.exe'
                & $sc stop   "$($l.Path)" 2>&1 | Out-Null
                & $sc delete "$($l.Path)" 2>&1 | Out-Null

                # sc.exe reports success by exit code, and a service with a
                # handle still open is only marked for deletion. Say which
                # happened rather than claiming it is gone.
                if (Get-Service -Name $l.Path -ErrorAction SilentlyContinue) {
                    Write-Log -Level WARN -Message "service '$($l.Path)' is marked for deletion and goes on the next restart  (backed up to $file)"
                } else {
                    Write-Log -Level OK -Message "removed service: $($l.Path)  (backed up to $file)"
                }
                $removed++
            } catch {
                $skipped++
                Write-Log -Level WARN -Message "could not remove service '$($l.Path)': $($_.Exception.Message.Trim())"
            }
            continue
        }

        if ($l.Kind -eq 'task') {
            if (-not (Test-SafeToRemoveTask -TaskPath $l.Path -ActionPath $l.Detail `
                                            -AppName $AppName -Publisher $Publisher)) {
                $skipped++
                Write-Log -Level WARN -Message "refusing to remove task '$($l.Path)': it does not pass the safety check"
                continue
            }
            try {
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                $sched = New-Object -ComObject Schedule.Service
                $sched.Connect()
                $parent = Split-Path $l.Path -Parent
                if (-not $parent) { $parent = '\' }
                $leaf   = Split-Path $l.Path -Leaf
                $folder = $sched.GetFolder($parent)

                # The task's own XML, which is exactly what schtasks /create
                # /xml takes to put it back.
                $safe = ($l.Path -replace '[^A-Za-z0-9]', '_')
                $file = Join-Path $backupDir "task_$safe.xml"
                $xml  = $folder.GetTask($leaf).Xml
                Set-Content -LiteralPath $file -Value $xml -Encoding Unicode
                if (-not (Test-Path -LiteralPath $file)) {
                    throw 'the task definition could not be exported, so it is being left alone'
                }

                $folder.DeleteTask($leaf, 0)
                Write-Log -Level OK -Message "removed task: $($l.Path)  (backed up to $file)"
                $removed++
            } catch {
                $skipped++
                Write-Log -Level WARN -Message "could not remove task '$($l.Path)': $($_.Exception.Message.Trim())"
            }
            continue
        }

        if ($l.Kind -eq 'registry') {
            # The same belt and braces the folder branch has had all along. A
            # key was deleted on the strength of a list built earlier, with
            # nothing re-checking it at the moment it mattered - so any fault
            # that put a wrong key in the list would have been caught for a
            # folder and not for a key.
            if (-not (Test-SafeToRemoveKey -Key $l.Path -AppName $AppName -Publisher $Publisher)) {
                $skipped++
                Write-Log -Level WARN -Message "refusing to remove key '$($l.Path)': it does not pass the safety check"
                continue
            }
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
        if (-not (Test-SafeToRemovePath -Path $l.Path -AppName $AppName -Publisher $Publisher)) {
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
