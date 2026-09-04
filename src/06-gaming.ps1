# ---------------------------------------------------------------------------
# Phase: Gaming
#
# Settings > Gaming, plus System > Display > Graphics.
#
# Game discovery is manifest-driven, not heuristic. Every launcher publishes an
# authoritative record of what it installed and where; walking directories and
# guessing which .exe looks biggest misses games and picks debug builds. The
# earlier heuristic version of this file missed three installed titles on the
# development machine while confidently picking a Source 2 dev console.
#
# A note on Game Mode: this turns it OFF because that is what was asked for, but
# it is genuinely contested. On Windows 11 22H2 and later Game Mode mostly
# suppresses background scheduling and blocks Windows Update restarts during
# play, and on most machines it is neutral-to-helpful. Flip $DisableGameMode.
# ---------------------------------------------------------------------------

$script:DisableGameMode = $true

# GpuPreference: 0 system default, 1 power saving, 2 high performance.
$script:GpuHighPerformance = 'GpuPreference=2;'

function Invoke-GamingPhase {
    param([Parameter(Mandatory)]$Facts)
    Write-Phase 'Gaming'

    Disable-GameBarAndCapture
    Set-WindowedGameOptimizations
    Set-GamesToHighPerformance -Facts $Facts
}

function Disable-GameBarAndCapture {
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0 -Because 'Game Bar off'
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'GamePanelStartupTipIndex' 3 -Because 'suppress Game Bar tips'
    Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0 -Because 'Game Bar off'

    # Captures / Game DVR. Three separate places, all of which have to agree or
    # background recording keeps running even with the UI toggle showing Off.
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 -Because 'Captures off'
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 -Because 'Captures off'
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2 -Because 'disable fullscreen optimisation override'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0 -Because 'Captures off, machine-wide'

    if ($script:DisableGameMode) {
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0 -Because 'Game Mode off' -Tier op
        Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 0 -Because 'Game Mode off' -Tier op
    }
}

<#
.SYNOPSIS
    System > Display > Graphics > "Optimizations for windowed games".

.DESCRIPTION
    Lives in a single semicolon-delimited REG_SZ that also carries the variable
    refresh rate and Auto HDR flags, so it has to be merged rather than
    overwritten - clobbering it silently turns those off for windowed games.
#>
function Set-WindowedGameOptimizations {
    $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $name = 'DirectXUserGlobalSettings'

    $current = ''
    $existing = Get-RegValueOrAbsent -Path $path -Name $name
    if ($existing.Exists) { $current = [string]$existing.Value }

    $pairs = [ordered]@{}
    foreach ($chunk in ($current -split ';')) {
        if ($chunk -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') { $pairs[$Matches[1]] = $Matches[2] }
    }
    $pairs['SwapEffectUpgradeEnable'] = '1'

    $merged = (($pairs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';') + ';'
    Set-Reg $path $name $merged -Type String -Because 'optimisations for windowed games on'
}

# ===========================================================================
#  Storage and launcher discovery
# ===========================================================================

<#
.SYNOPSIS
    Every drive that could hold a game library.

.DESCRIPTION
    Fixed and removable, because game libraries are frequently not on C: and
    frequently on an external disk. Network drives are excluded: they may be
    disconnected, slow, or very large, and scanning one can hang the run.
#>
function Get-StorageInventory {
    $drives = @()
    try {
        $drives = @(Get-Volume -ErrorAction Stop |
            # Removable is included deliberately: external drives are a very
            # common home for game libraries. Network drives are not - they may
            # be absent, slow, or enormous.
            Where-Object { $_.DriveLetter -and $_.DriveType -in @('Fixed','Removable') } |
            ForEach-Object {
                [pscustomobject]@{
                    Letter = $_.DriveLetter
                    Root   = "$($_.DriveLetter):\"
                    Label  = $_.FileSystemLabel
                    Type   = "$($_.DriveType)"
                    FreeGB = [Math]::Round($_.SizeRemaining / 1GB, 1)
                    SizeGB = [Math]::Round($_.Size / 1GB, 1)
                }
            })
    } catch {
        # Get-Volume is unavailable in some minimal images; fall back to the
        # provider, which is always there.
        $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.Length -eq 1 -and (Test-Path "$($_.Name):\") } |
            ForEach-Object {
                [pscustomobject]@{
                    Letter = $_.Name; Root = "$($_.Name):\"; Label = ''; Type = 'Unknown'
                    FreeGB = if ($_.Free) { [Math]::Round($_.Free / 1GB, 1) } else { 0 }
                    SizeGB = 0
                }
            })
    }
    return $drives
}

<#
.SYNOPSIS
    Which game launchers are installed, and where their own executables live.

.DESCRIPTION
    The launcher executable matters for its own sake: it is the fallback GPU
    preference target for any title whose real binary cannot be resolved, and
    several launchers render overlays themselves.
#>
function Get-InstalledLaunchers {
    $found = [System.Collections.Generic.List[object]]::new()

    function Add-Launcher {
        param([string]$Name, [string]$Root, [string]$Exe)
        if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return }
        $found.Add([pscustomobject]@{
            Name = $Name
            Root = $Root
            Exe  = if ($Exe -and (Test-Path -LiteralPath $Exe)) { $Exe } else { $null }
        }) | Out-Null
    }

    # Every registry lookup goes through Get-SoftwareHivePaths so it is correct
    # on 32-bit Windows too, and every Program Files guess through
    # Get-ProgramFilesRoots so an undefined (x86) root cannot throw.
    $pf = @(Get-ProgramFilesRoots)

    # --- Steam ---
    $steam = Get-RegistryValue (@('HKCU:\Software\Valve\Steam') + (Get-SoftwareHivePaths 'Valve\Steam')) @('SteamPath','InstallPath')
    if (-not $steam) { $steam = Find-UnderRoots $pf 'Steam' }
    if ($steam) { Add-Launcher 'Steam' $steam (Join-Path $steam 'steam.exe') }

    # --- Epic ---
    $epicDir = Find-UnderRoots $pf 'Epic Games\Launcher\Portal\Binaries\Win64'
    if ($epicDir) { Add-Launcher 'Epic Games' $epicDir (Join-Path $epicDir 'EpicGamesLauncher.exe') }

    # --- Ubisoft Connect ---
    $ubi = Get-RegistryValue (Get-SoftwareHivePaths 'Ubisoft\Launcher') @('InstallDir')
    if (-not $ubi) { $ubi = Find-UnderRoots $pf 'Ubisoft\Ubisoft Game Launcher' }
    if ($ubi) { Add-Launcher 'Ubisoft Connect' $ubi (Join-Path $ubi 'upc.exe') }

    # --- EA ---
    $ea = Find-UnderRoots $pf 'Electronic Arts\EA Desktop\EA Desktop'
    if (-not $ea) { $ea = Find-UnderRoots $pf 'Origin' }
    if ($ea) {
        $exe = @(Get-ChildItem -LiteralPath $ea -Filter '*.exe' -ErrorAction SilentlyContinue |
                 Where-Object { $_.BaseName -match 'EADesktop|Origin' } | Select-Object -First 1)
        Add-Launcher 'EA' $ea $(if ($exe.Count) { $exe[0].FullName } else { $null })
    }

    # --- GOG Galaxy ---
    $gog = Get-RegistryValue (Get-SoftwareHivePaths 'GOG.com\GalaxyClient\paths') @('client')
    if (-not $gog) { $gog = Find-UnderRoots $pf 'GOG Galaxy' }
    if ($gog) { Add-Launcher 'GOG Galaxy' $gog (Join-Path $gog 'GalaxyClient.exe') }

    # --- Battle.net ---
    $bnet = Find-UnderRoots $pf 'Battle.net'
    if ($bnet) { Add-Launcher 'Battle.net' $bnet (Join-Path $bnet 'Battle.net.exe') }

    # --- Riot ---
    $riot = Join-Path $env:ProgramData 'Riot Games\Riot Client'
    if (-not (Test-Path -LiteralPath $riot)) { $riot = Find-UnderRoots $pf 'Riot Games\Riot Client' }
    if ($riot) { Add-Launcher 'Riot' $riot (Join-Path $riot 'RiotClientServices.exe') }

    # --- Xbox app ---
    if (@(Get-AppxPackage -Name 'Microsoft.GamingApp' -ErrorAction SilentlyContinue).Count -gt 0) {
        $found.Add([pscustomobject]@{ Name = 'Xbox'; Root = 'AppX'; Exe = $null }) | Out-Null
    }

    return @($found)
}

<#
.SYNOPSIS
    First existing path formed by joining a relative path onto any known
    Program Files root.
#>
function Find-UnderRoots {
    param([string[]]$Roots, [Parameter(Mandatory)][string]$Relative)
    foreach ($r in @($Roots)) {
        if (-not $r) { continue }
        $c = Join-Path $r $Relative
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Get-RegistryValue {
    param([string[]]$Paths, [string[]]$Names)
    foreach ($p in $Paths) {
        try {
            $item = Get-ItemProperty -LiteralPath $p -ErrorAction Stop
            foreach ($n in $Names) {
                if ($item.PSObject.Properties.Name -contains $n) {
                    $v = "$($item.$n)"
                    if ($v) { return $v.Trim('"') }
                }
            }
        } catch { }
    }
    return $null
}

# ===========================================================================
#  Per-launcher game enumeration
# ===========================================================================

<#
.SYNOPSIS
    Every installed game each launcher knows about.

.DESCRIPTION
    Returns objects with Launcher, Title, InstallDir, and where the launcher
    tells us outright, Exe. Manifests beat guessing: Epic and GOG name the
    launch executable explicitly, and Steam names the install directory exactly,
    which removes any need to decide what "looks like a game folder".
#>
function Get-GameLibrary {
    $games = [System.Collections.Generic.List[object]]::new()

    function Add-Game {
        param([string]$Launcher, [string]$Title, [string]$InstallDir, [string]$Exe = $null)
        if (-not $InstallDir -or -not (Test-Path -LiteralPath $InstallDir)) { return }
        $games.Add([pscustomobject]@{
            Launcher   = $Launcher
            Title      = $Title
            InstallDir = $InstallDir
            Exe        = if ($Exe -and (Test-Path -LiteralPath $Exe)) { $Exe } else { $null }
        }) | Out-Null
    }

    foreach ($g in (Find-SteamGames))   { Add-Game $g.Launcher $g.Title $g.InstallDir $g.Exe }
    foreach ($g in (Find-EpicGames))    { Add-Game $g.Launcher $g.Title $g.InstallDir $g.Exe }
    foreach ($g in (Find-XboxGames))    { Add-Game $g.Launcher $g.Title $g.InstallDir $g.Exe }
    foreach ($g in (Find-UbisoftGames)) { Add-Game $g.Launcher $g.Title $g.InstallDir $g.Exe }
    foreach ($g in (Find-GogGames))     { Add-Game $g.Launcher $g.Title $g.InstallDir $g.Exe }
    foreach ($g in (Find-EaGames))      { Add-Game $g.Launcher $g.Title $g.InstallDir $g.Exe }
    foreach ($g in (Find-BattleNetGames)) { Add-Game $g.Launcher $g.Title $g.InstallDir $g.Exe }

    return @($games)
}

<#
.SYNOPSIS
    Steam, via libraryfolders.vdf and the per-app appmanifest files.

.DESCRIPTION
    appmanifest_<appid>.acf carries the exact "installdir" and the display
    "name". Reading them removes all guesswork about which folders under
    steamapps\common are games and what they are called.
#>
function Find-SteamGames {
    $out = @()
    $steam = Get-RegistryValue (@('HKCU:\Software\Valve\Steam') + (Get-SoftwareHivePaths 'Valve\Steam')) @('SteamPath','InstallPath')
    if (-not $steam) { $steam = Find-UnderRoots (Get-ProgramFilesRoots) 'Steam' }
    if (-not $steam) { return $out }

    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $vdf)) { return $out }

    # Steam has used two formats here. Current builds write
    #     "path"   "D:\\SteamLibrary"
    # Builds before roughly 2021 wrote a bare numbered key instead:
    #     "1"      "D:\\SteamLibrary"
    # Matching only the first finds no libraries at all on an older install,
    # which is indistinguishable from "this user owns no games".
    $libraries = @()
    try {
        $text = Get-Content -Raw -LiteralPath $vdf
        foreach ($m in ([regex]'"path"\s+"([^"]+)"').Matches($text)) {
            $libraries += ($m.Groups[1].Value -replace '\\\\', '\')
        }
        foreach ($m in ([regex]'"\d+"\s+"([A-Za-z]:\\\\[^"]*)"').Matches($text)) {
            $libraries += ($m.Groups[1].Value -replace '\\\\', '\')
        }
    } catch { return $out }

    # The Steam install directory is itself a library and is not always listed.
    $libraries += $steam

    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $apps = Join-Path $lib 'steamapps'
        if (-not (Test-Path -LiteralPath $apps)) { continue }

        foreach ($acf in (Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
            try {
                $text = Get-Content -Raw -LiteralPath $acf.FullName
                $name    = ([regex]'"name"\s+"([^"]*)"').Match($text).Groups[1].Value
                $dirName = ([regex]'"installdir"\s+"([^"]*)"').Match($text).Groups[1].Value
                if (-not $dirName) { continue }

                $dir = Join-Path (Join-Path $apps 'common') $dirName
                if (Test-Path -LiteralPath $dir) {
                    $out += [pscustomobject]@{
                        Launcher = 'Steam'; Title = $(if ($name) { $name } else { $dirName })
                        InstallDir = $dir; Exe = $null
                    }
                }
            } catch { }
        }
    }
    return $out
}

<#
.SYNOPSIS
    Epic, via the launcher's own manifests - which name the executable outright.
#>
function Find-EpicGames {
    $out = @()
    $manifests = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path -LiteralPath $manifests)) { return $out }

    foreach ($m in (Get-ChildItem -LiteralPath $manifests -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
        try {
            # PowerShell 5.1's Get-Content defaults to ANSI; Epic manifests are
            # UTF-8, so titles like "Rocket League(R)" come back mangled without this.
            $j = Get-Content -Raw -Encoding UTF8 -LiteralPath $m.FullName | ConvertFrom-Json
            if (-not $j.InstallLocation) { continue }

            # LaunchExecutable is relative to InstallLocation and is authoritative.
            $exe = $null
            if ($j.PSObject.Properties.Name -contains 'LaunchExecutable' -and $j.LaunchExecutable) {
                $candidate = Join-Path $j.InstallLocation $j.LaunchExecutable
                if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
            }
            $title = if ($j.PSObject.Properties.Name -contains 'DisplayName') { $j.DisplayName } else { Split-Path $j.InstallLocation -Leaf }

            $out += [pscustomobject]@{
                Launcher = 'Epic Games'; Title = $title
                InstallDir = $j.InstallLocation; Exe = $exe
            }
        } catch { }
    }
    return $out
}

<#
.SYNOPSIS
    Xbox / Microsoft Store games.

.DESCRIPTION
    The modern Xbox app installs to <drive>:\XboxGames\<Title>\Content\ on
    whichever drive the user chose, which makes them findable by walking fixed
    drives - far simpler than trying to decide which AppX packages are games.
#>
function Find-XboxGames {
    $out = @()
    foreach ($drive in (Get-StorageInventory)) {
        $root = Join-Path $drive.Root 'XboxGames'
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($titleDir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $content = Join-Path $titleDir.FullName 'Content'
            if (-not (Test-Path -LiteralPath $content)) { continue }
            $out += [pscustomobject]@{
                Launcher = 'Xbox'; Title = $titleDir.Name
                InstallDir = $content; Exe = $null
            }
        }
    }
    return $out
}

function Find-UbisoftGames {
    $out = @()
    $key = @(Get-SoftwareHivePaths 'Ubisoft\Launcher\Installs' | Where-Object { Test-Path -LiteralPath $_ })[0]
    if (-not $key) { return $out }

    foreach ($sub in (Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
        $dir = Get-RegistryValue @($sub.PSPath) @('InstallDir')
        if ($dir) {
            $dir = $dir -replace '/', '\'
            $out += [pscustomobject]@{
                Launcher = 'Ubisoft Connect'; Title = (Split-Path $dir.TrimEnd('\') -Leaf)
                InstallDir = $dir; Exe = $null
            }
        }
    }
    return $out
}

<#
.SYNOPSIS
    GOG, which records both the install path and the launch executable.
#>
function Find-GogGames {
    $out = @()
    foreach ($key in (Get-SoftwareHivePaths 'GOG.com\Games')) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        foreach ($sub in (Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)) {
            $dir  = Get-RegistryValue @($sub.PSPath) @('path','PATH')
            $name = Get-RegistryValue @($sub.PSPath) @('gameName','GAMENAME')
            $exe  = Get-RegistryValue @($sub.PSPath) @('exe','EXE')
            if (-not $dir) { continue }

            $exePath = $null
            if ($exe) {
                $c = if ([System.IO.Path]::IsPathRooted($exe)) { $exe } else { Join-Path $dir $exe }
                if (Test-Path -LiteralPath $c) { $exePath = $c }
            }
            $out += [pscustomobject]@{
                Launcher = 'GOG Galaxy'; Title = $(if ($name) { $name } else { Split-Path $dir -Leaf })
                InstallDir = $dir; Exe = $exePath
            }
        }
    }
    return $out
}

function Find-EaGames {
    $out = @()
    # Origin's legacy manifests name the install path directly.
    $local = Join-Path $env:ProgramData 'Origin\LocalContent'
    if (Test-Path -LiteralPath $local) {
        foreach ($d in (Get-ChildItem -LiteralPath $local -Directory -ErrorAction SilentlyContinue)) {
            $guesses = @()
            foreach ($r in (Get-ProgramFilesRoots)) {
                $guesses += (Join-Path $r "EA Games\$($d.Name)")
                $guesses += (Join-Path $r "Origin Games\$($d.Name)")
            }
            foreach ($guess in $guesses) {
                if (Test-Path -LiteralPath $guess) {
                    $out += [pscustomobject]@{ Launcher = 'EA'; Title = $d.Name; InstallDir = $guess; Exe = $null }
                    break
                }
            }
        }
    }
    # EA Desktop keeps installs under a common root on each drive.
    foreach ($drive in (Get-StorageInventory)) {
        foreach ($rootName in @('EA Games','Origin Games')) {
            $root = Join-Path $drive.Root $rootName
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                $out += [pscustomobject]@{ Launcher = 'EA'; Title = $d.Name; InstallDir = $d.FullName; Exe = $null }
            }
        }
    }
    return $out
}

<#
.SYNOPSIS
    Blizzard titles, via their uninstall entries.

.DESCRIPTION
    Battle.net's own product database is a protobuf blob with no stable schema.
    The uninstall registry entries carry the same install locations and are
    documented, so they are the sane source.
#>
function Find-BattleNetGames {
    $out = @()
    # Both views matter on 64-bit: 64-bit apps register in the plain path,
    # 32-bit ones under the WOW node. On 32-bit Windows there is only the one.
    $roots = @(Get-SoftwareHivePaths 'Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($sub in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction Stop
                $pub = "$($p.Publisher)"
                if ($pub -notmatch 'Blizzard') { continue }
                # The Battle.net client itself is published by Blizzard and has an
                # uninstall entry like any game. It is a launcher, not a title.
                if ("$($p.DisplayName)" -match '^Battle\.net$|^Blizzard') { continue }
                $dir = "$($p.InstallLocation)"
                if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
                $out += [pscustomobject]@{
                    Launcher = 'Battle.net'; Title = "$($p.DisplayName)"
                    InstallDir = $dir; Exe = $null
                }
            } catch { }
        }
    }
    return $out
}

# ===========================================================================
#  Executable resolution
# ===========================================================================

# Substrings that mark an executable as not-the-game.
$script:NotAGame = @(
    'unins','uninstall','setup','install','vcredist','vc_redist','dxsetup',
    'dxwebsetup','directx','dotnetfx','oalinst','ueprereqsetup','prereq',
    'crash',            # blanket: crashUploader, crashSender, CrashHandler, ...
    'overlay','bootstrap','launcher','updater','patcher','redist','helper',
    'service','daemon','trainer','activation',
    'easyanticheat','anticheat','battleye','be_service','activationui',
    'vconsole','editor','devenv','benchmark','config','settings','report',
    'toolkit','sdk','server','dedicated','cleanup','diagnostic'
)

# Unreal ships debug and editor builds beside the real one as <Name>-d.exe and
# <Name>-e.exe. They are frequently LARGER than the shipping binary because of
# debug symbols, so a size heuristic picks them every time unless excluded by
# shape rather than by substring.
$script:DebugSuffixPattern = '-(d|e|db|dbg|debug|editor|test)$'

<#
.SYNOPSIS
    Decide which executable in a game folder is the game.

.DESCRIPTION
    Order matters, and each step is more reliable than the next:
      1. the launcher told us outright
      2. an Unreal shipping binary, which is definitive when present
      3. an executable named after its own folder, the common convention
      4. the largest remaining plausible executable
    Returns $null rather than guessing badly when nothing qualifies - the caller
    falls back to the launcher.
#>
function Resolve-GameExecutable {
    param([Parameter(Mandatory)]$Game)

    # A launcher's manifest is authoritative about what it launches, which is
    # not always the game: Epic lists Rocket League's LaunchExecutable as
    # Launcher.exe, a bootstrapper that then starts the real binary. Setting a
    # GPU preference on the bootstrapper does nothing, so a manifest exe still
    # has to clear the same filter as a discovered one.
    if ($Game.Exe) {
        $n = [System.IO.Path]::GetFileNameWithoutExtension($Game.Exe).ToLower()
        if (-not (@($script:NotAGame | Where-Object { $n -like "*$_*" }).Count)) {
            return $Game.Exe
        }
        Write-Log "'$($Game.Title)': manifest names '$n', which is a bootstrapper - looking for the real binary"
    }

    # Nearly every engine puts the binary in one of a handful of places. Looking
    # there first turns a recursive walk of a 100 GB game folder into a couple of
    # directory reads, and only falls back to the full scan when it has to.
    $quick = @()
    foreach ($sub in @('', 'Binaries\Win64', 'Binaries\Win32', 'game\bin\win64', 'bin', 'bin\x64', 'Content')) {
        $dir = if ($sub) { Join-Path $Game.InstallDir $sub } else { $Game.InstallDir }
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $quick += @(Get-ChildItem -LiteralPath $dir -Filter '*.exe' -File -ErrorAction SilentlyContinue)
    }
    $usable = @($quick | Where-Object {
        $n = $_.BaseName.ToLower()
        ($_.Length -gt 1MB) -and
        ($n -notmatch $script:DebugSuffixPattern) -and
        -not (@($script:NotAGame | Where-Object { $n -like "*$_*" }).Count)
    })
    if ($usable.Count -gt 0) {
        $shipQuick = @($usable | Where-Object { $_.BaseName -match '-Win64-Shipping$|-WinGDK-Shipping$' })
        if ($shipQuick.Count) { return (@($shipQuick | Sort-Object Length -Descending)[0]).FullName }
        $nameQuick = @($usable | Where-Object {
            ($_.BaseName -replace '[^A-Za-z0-9]','') -in @(
                ((Split-Path $Game.InstallDir -Leaf) -replace '[^A-Za-z0-9]',''),
                ("$($Game.Title)" -replace '[^A-Za-z0-9]',''))
        })
        if ($nameQuick.Count) { return (@($nameQuick | Sort-Object Length -Descending)[0]).FullName }
    }

    $candidates = @()
    try {
        $candidates = @(Get-ChildItem -LiteralPath $Game.InstallDir -Filter '*.exe' -Recurse -Depth 4 -File -ErrorAction SilentlyContinue |
            Where-Object {
                $n = $_.BaseName.ToLower()
                ($_.Length -gt 1MB) -and
                ($n -notmatch $script:DebugSuffixPattern) -and
                -not (@($script:NotAGame | Where-Object { $n -like "*$_*" }).Count)
            })
    } catch {
        Write-Log -Level WARN -Message "could not scan '$($Game.InstallDir)': $($_.Exception.Message)"
        return $null
    }
    if ($candidates.Count -eq 0) { return $null }

    $shipping = @($candidates | Where-Object { $_.BaseName -match '-Win64-Shipping$|-WinGDK-Shipping$' })
    if ($shipping.Count -gt 0) {
        return (@($shipping | Sort-Object Length -Descending)[0]).FullName
    }

    $folderName = (Split-Path $Game.InstallDir -Leaf) -replace '[^A-Za-z0-9]', ''
    $titleName  = "$($Game.Title)" -replace '[^A-Za-z0-9]', ''
    $named = @($candidates | Where-Object {
        $b = ($_.BaseName -replace '[^A-Za-z0-9]', '')
        $b -eq $folderName -or $b -eq $titleName
    })
    if ($named.Count -gt 0) { return (@($named | Sort-Object Length -Descending)[0]).FullName }

    return (@($candidates | Sort-Object Length -Descending)[0]).FullName
}

<#
.SYNOPSIS
    Store-app identities for anything installed as an AppX package under a game
    directory.

.DESCRIPTION
    A Store app's GPU preference is keyed by "<PackageFamilyName>!<AppId>", not
    by a path, so a UWP title needs a completely different value name from a
    win32 one. Most Xbox titles are win32 under XboxGames and are handled by
    path; this catches the genuinely packaged ones.
#>
function Get-StoreGameIdentities {
    $out = @()
    try {
        $packages = @(Get-AppxPackage -ErrorAction Stop |
            # ONLY XboxGames. Matching \WindowsApps\ sweeps up every Store app on
            # the machine - Edge, Sticky Notes, a WinRAR shell extension, image
            # codecs - and fills the user's Graphics settings with dozens of
            # entries they then have to look at forever. None of them are games.
            Where-Object { $_.InstallLocation -and $_.InstallLocation -match '\\XboxGames\\' -and -not $_.IsFramework })
    } catch { return $out }

    foreach ($p in $packages) {
        # Only packages that declare an Application entry can be targeted, and
        # the AppId is part of the key.
        try {
            $manifest = Join-Path $p.InstallLocation 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $manifest)) { continue }
            [xml]$x = Get-Content -Raw -LiteralPath $manifest
            $apps = @($x.Package.Applications.Application)
            foreach ($a in $apps) {
                if (-not $a -or -not $a.Id) { continue }
                $out += [pscustomobject]@{
                    Title = $p.Name
                    Key   = "$($p.PackageFamilyName)!$($a.Id)"
                }
            }
        } catch { }
    }
    return $out
}

# ===========================================================================
#  Apply
# ===========================================================================

<#
.SYNOPSIS
    Point every discovered game at the high-performance GPU.

.DESCRIPTION
    On a machine with only one GPU vendor and no hybrid graphics this changes
    nothing, so it is skipped rather than writing hundreds of inert values into
    the user's Graphics settings list, which they then have to look at forever.
#>
function Set-GamesToHighPerformance {
    param([Parameter(Mandatory)]$Facts)

    $drives = @(Get-StorageInventory)
    Write-Log "Storage: $($drives.Count) drive(s) - $(($drives | ForEach-Object { "$($_.Letter): $($_.Type), $($_.FreeGB)/$($_.SizeGB) GB free" }) -join '; ')"

    $launchers = @(Get-InstalledLaunchers)
    if ($launchers.Count -eq 0) {
        Write-Log 'No game launchers found. Skipping GPU preferences.'
        return
    }
    Write-Log "Launchers: $(($launchers | Select-Object -ExpandProperty Name) -join ', ')"

    $games = @(Get-GameLibrary)
    Write-Log "Games found: $($games.Count)"
    foreach ($grp in ($games | Group-Object Launcher | Sort-Object Name)) {
        Write-Log "  $($grp.Name): $($grp.Count)"
    }

    if (@($Facts.GpuVendors).Count -lt 2 -and -not $Facts.IsLaptop) {
        Write-Log 'Single GPU vendor on a desktop - there is nothing for a per-application preference to choose between. Recording the library, changing nothing.'
        return
    }

    $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $unresolved = [System.Collections.Generic.List[string]]::new()

    foreach ($g in $games) {
        $exe = Resolve-GameExecutable -Game $g
        if ($exe) {
            Set-Reg $path $exe $script:GpuHighPerformance -Type String `
                -Because "high performance GPU: $($g.Title) ($($g.Launcher))"
        } else {
            # Cannot identify the binary. Record it so the launcher fallback
            # below is a deliberate decision rather than a silent omission.
            $unresolved.Add("$($g.Title) [$($g.Launcher)]") | Out-Null
        }
    }

    # Packaged Store titles are keyed by package identity, not by path.
    foreach ($s in (Get-StoreGameIdentities)) {
        Set-Reg $path $s.Key $script:GpuHighPerformance -Type String `
            -Because "high performance GPU: $($s.Title) (Store app)"
    }

    # The fallback: any game we could not resolve is still launched by its
    # launcher, so setting the launcher gives those titles somewhere to inherit
    # a sensible default from. Launchers are added regardless - they render
    # overlays and store fronts of their own.
    foreach ($l in $launchers) {
        if (-not $l.Exe) { continue }
        Set-Reg $path $l.Exe $script:GpuHighPerformance -Type String `
            -Because "high performance GPU: $($l.Name) launcher"
    }

    if ($unresolved.Count -gt 0) {
        Write-Log -Level WARN -Message "$($unresolved.Count) title(s) had no identifiable executable; their launcher was set instead:"
        foreach ($u in $unresolved) { Write-Log "    $u" }
    }
}
