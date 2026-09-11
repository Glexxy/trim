#Requires -Version 5.1
<#
.SYNOPSIS
    Trim - opinionated, reversible Windows 10 and 11 tuning.

.DESCRIPTION
    Applies a curated set of debloat, privacy, gaming and personalisation changes
    to a Windows 10 or 11 machine. Every registry write is recorded before it is
    made, and an undo script is emitted at the end of the run.

    It detects laptop vs desktop, GPU vendor and Windows version, and skips
    anything that does not apply rather than guessing.

.PARAMETER Gui
    Open the window. This is what a run with no arguments does, and nothing in
    the plan is changed until Apply is pressed. The Startup, Cleanup and
    Uninstall panes each ask before they act.

.PARAMETER Apply
    Apply from the command line, with no window and no prompt. Required: a run
    without it changes nothing.

.PARAMETER DryRun
    Show every change that would be made without making any of them. Still writes
    a log, and the only mode that does not ask for administrator rights - so a few
    machine-wide values cannot be read and are missing from the plan.

.PARAMETER Skip
    Phases to skip. The valid names are the ValidateSet on the parameter itself,
    a few lines below; the harness checks this help against it.

.PARAMETER Only
    Run only these phases. Overrides -Skip.

.PARAMETER Cleanup
    Include the disk cleanup scan. Never part of a preset.

.PARAMETER LargeFiles
    Report the biggest files on every drive. Report only - nothing is deleted.

.PARAMETER NoRestorePoint
    Skip creating a system restore point. Not recommended.

.PARAMETER Aggressive
    Widen the AppX removal list to products some people genuinely use - Teams,
    OneNote, To Do, Sticky Notes, Outlook for Windows. Nothing else in the run
    behaves differently.

.PARAMETER Version
    Print the version and the SHA256 of this exact file, then exit.

.EXAMPLE
    irm https://trimbloat.com/go | iex

.EXAMPLE
    .\trim.ps1 -DryRun

.EXAMPLE
    .\trim.ps1 -Skip Appx,Network
#>
[CmdletBinding()]
param(
    [switch]$DryRun,

    [ValidateSet('WinUtil','Fixes','Performance','Gaming','Graphics','Privacy','Background','Appx','Network','Security','Personalisation','Extras')]
    [string[]]$Skip = @(),

    [ValidateSet('WinUtil','Fixes','Performance','Gaming','Graphics','Privacy','Background','Appx','Network','Security','Personalisation','Extras')]
    [string[]]$Only = @(),

    # Show the window. This is what happens by default, including for
    # `irm | iex`, so the flag is only needed to be explicit about it.
    # Builds the plan unelevated, then asks for administrator rights at Apply.
    [switch]$Gui,

    # Apply from the command line, with no window and no confirmation. Has to
    # be asked for by name: a run with no arguments opens the window instead.
    # Piping this script into a shell passes no arguments, and a stranger who
    # runs a one-liner has not consented to an unattended sweep of their
    # machine - they have consented to being shown one.
    [switch]$Apply,

    # Internal: apply a selection saved by an earlier, unelevated window.
    [string]$ApplySelection = '',

    # Run the disk cleanup sweep from the command line. Never part of a preset.
    [switch]$Cleanup,
    [switch]$IncludeDuplicates,

    # Report the biggest files on every drive. Report only - nothing here is
    # ever deleted, because a large file and a junk file look identical from
    # the outside.
    [switch]$LargeFiles,

    # Set only by this script when it elevates itself from a piped run. The
    # elevated process re-hashes the file it was launched from and refuses to
    # continue if it does not match, which closes the window between staging
    # the file and Windows starting it.
    [string]$ElevationHash = '',

    # Print the version and the SHA256 of this exact file, then exit. The one
    # way a user can confirm that what reached their machine is what was
    # published, rather than what somebody in the middle preferred.
    [switch]$Version,

    [switch]$NoRestorePoint,
    [switch]$Aggressive,

    # Suppress the restart prompt. For unattended and scripted runs.
    [switch]$NoRestartPrompt,

    # Opt-in ONLY. Trades kernel driver protection for roughly 3-7% average FPS.
    # Never set by a preset; the user has to ask for it by name.
    [switch]$DisableMemoryIntegrity,

    # Where to read the winutil selection config from. Accepts an https URL or a
    # local path. Defaults to the copy beside the script when running from a
    # clone, and falls back to the published one for `irm | iex` use.
    [string]$WinUtilConfigUrl = '',

    # Path or URL to an NVIDIA Profile Inspector .nip to import globally.
    [string]$NvidiaProfile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:TrimVersion = '0.1.0'

# Modern TLS only, set before the first fetch. Windows PowerShell 5.1 still
# defaults to SSL3/TLS1.0 on some builds, which is both refused by GitHub and a
# downgrade waiting to happen.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
}

<#
.SYNOPSIS
    Split a phase list that arrived as one comma-separated string.

.DESCRIPTION
    powershell.exe -File hands "-Skip Extras,Gaming" over as the single string
    'Extras,Gaming' rather than two names, and the elevated relaunch uses -File.
    Unsplit, it names no phase: -Skip skips nothing, and the elevated run applies
    exactly what the user asked it to leave alone.
#>
function Split-PhaseList {
    param([AllowEmptyCollection()][AllowNull()][string[]]$List = @())
    return @(@($List) | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

<#
.SYNOPSIS
    Join arguments into one Windows command line that splits back into exactly them.

.DESCRIPTION
    Start-Process joins -ArgumentList with spaces and quotes nothing, and the
    process it starts splits the result again. A script path under a profile
    folder whose user name has a space - C:\Users\Jo Smith\... - arrives as two
    arguments, and the elevated window cannot find the script.

    Each argument is quoted by the rules the receiving process splits by:
    backslashes are literal except before a quote, where each one has to be
    doubled, and a quote inside the argument is escaped with a backslash.
#>
function Join-CommandLine {
    param([AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @())
    $bs = [char]92
    $parts = foreach ($a in $Arguments) {
        if ($a -and $a -notmatch '[\s"]') { $a; continue }
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($c in $a.ToCharArray()) {
            if ($c -eq $bs) { $slashes++; continue }
            if ($c -eq '"') { [void]$sb.Append($bs, 2 * $slashes + 1) }
            else { [void]$sb.Append($bs, $slashes) }
            [void]$sb.Append($c)
            $slashes = 0
        }
        [void]$sb.Append($bs, 2 * $slashes)
        [void]$sb.Append('"')
        $sb.ToString()
    }
    return (@($parts) -join ' ')
}

<#
.SYNOPSIS
    Download this script to a file and pin it by hash, for elevating.

.DESCRIPTION
    Used when there is no file on disk to re-invoke - which is the normal case,
    because the documented way to run this is `irm ... | iex`.

    Elevating by building a command line that downloads and executes inside
    the elevated process -

        -Command &([ScriptBlock]::Create((irm 'https://...')))

    - is wrong twice. It runs unverified bytes with administrator rights, so
    what actually gets privilege is not provably what the user read - a second
    fetch is a second opportunity to serve something different. And it is the
    textbook fileless-downloader shape, which Microsoft Defender flags as
    Trojan:Win32/Commando.A!ml, a detection on the command line rather than on
    any file.

    Fetching once here, unelevated, and handing over a path plus the hash it
    must match avoids both.
#>
function Get-StagedSelf {
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("trim_$([Guid]::NewGuid().ToString('N')).ps1")

    try {
        Invoke-WebRequest -Uri $script:SelfUrl -OutFile $stage -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Host "  Could not download the script to elevate: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $staged = (Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash

    # Compared against the published fingerprint before anything is elevated. A
    # mismatch is the one case where stopping is the only correct behaviour.
    try {
        $sidecarUrl = ($script:SelfUrl -replace '/go$', '/sha256')
        $published  = ((Invoke-RestMethod -Uri $sidecarUrl -UseBasicParsing -ErrorAction Stop) -split '\s+')[0]
        if ($published -and $published.Trim() -ne $staged) {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
            Write-Host '  The downloaded script does not match the published fingerprint.' -ForegroundColor Red
            Write-Host "    downloaded $staged" -ForegroundColor DarkGray
            Write-Host "    published  $($published.Trim())" -ForegroundColor DarkGray
            Write-Host '  Refusing to run it as administrator.' -ForegroundColor Red
            return $null
        }
    } catch {
        # An unreachable fingerprint is not evidence of tampering, and failing
        # closed on a flaky network would be its own fault. The elevated side
        # still verifies against the hash computed here.
        Write-Host '  Could not reach the published fingerprint; continuing with the local hash.' -ForegroundColor DarkYellow
    }

    return [pscustomobject]@{ Path = $stage; Hash = $staged }
}

<#
.SYNOPSIS
    What someone sees when they paste the one-liner.

.DESCRIPTION
    A person who runs `irm ... | iex` asked for an application. Scrolling a
    build transcript past them is not a status report, it is noise they cannot
    act on. The log file keeps everything.
#>
function Show-TrimBanner {
    # The wordmark is drawn with box-drawing characters, but this file has to
    # stay pure ASCII: a non-ASCII source means the compiled script needs a
    # UTF-8 byte order mark, and Invoke-RestMethod passes that mark through as a
    # literal character that Invoke-Expression cannot parse. It broke
    # `irm https://trimbloat.com/go | iex` outright.
    #
    # So the art is written with ASCII stand-ins and translated at runtime. It
    # is spelled out rather than hidden in a base64 blob, because this script is
    # served as plain text specifically so people can read it, and an encoded
    # payload in a script you are asked to trust looks exactly like the thing
    # you should not trust.
    #
    #   F  full block          a  top-left corner       c  bottom-left corner
    #   H  horizontal line     b  top-right corner      d  bottom-right corner
    #   V  vertical line
    $glyph = @{
        'F' = 0x2588; 'H' = 0x2550; 'V' = 0x2551
        'a' = 0x2554; 'b' = 0x2557; 'c' = 0x255A; 'd' = 0x255D
    }
    $art = @(
        '  FFFFFFFFb FFFFFFb  FFb FFFb   FFFb',
        '  cHHFFaHHd FFaHHFFb FFV FFFFb FFFFV',
        '     FFV    FFFFFFad FFV FFaFFFFaFFV',
        '     FFV    FFaHHFFb FFV FFVcFFadFFV',
        '     FFV    FFV  FFV FFV FFV cHd FFV',
        '     cHd    cHd  cHd cHd cHd     cHd'
    )

    # Box-drawing characters only render if the console is in a code page that
    # has them. Setting UTF-8 output is what makes that true, and it throws on
    # hosts with no real console attached - in which case the plain version is
    # used instead of printing a row of question marks.
    $unicode = $false
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $unicode = $true
    } catch { }

    $mark = if ($unicode) {
        foreach ($line in $art) {
            $sb = New-Object System.Text.StringBuilder
            foreach ($ch in $line.ToCharArray()) {
                if ($ch -eq ' ') { [void]$sb.Append(' ') }
                else             { [void]$sb.Append([char]$glyph["$ch"]) }
            }
            $sb.ToString()
        }
    } else {
        @(
            '  ########  ######   ##  ###    ###',
            '     ##     ##   ##  ##  ####  ####',
            '     ##     ######   ##  ## #### ##',
            '     ##     ##  ##   ##  ##  ##  ##',
            '     ##     ##   ##  ##  ##      ##'
        )
    }

    Write-Host ''
    foreach ($l in $mark) { Write-Host $l -ForegroundColor Cyan }
    Write-Host ''
    Write-Host '  Reversible Windows tuning' -ForegroundColor White
    Write-Host ''
}

# Published fallback for `irm | iex`, where there is no script directory to look
# beside. Also the URL used to re-fetch this script when self-elevating.
$script:PublishedConfigUrl = 'https://trimbloat.com/config/winutil-tweaks.json'
$script:SelfUrl            = 'https://trimbloat.com/go'

if (-not $WinUtilConfigUrl) {
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'config\winutil-tweaks.json' } else { $null }
    $WinUtilConfigUrl = if ($local -and (Test-Path -LiteralPath $local)) { $local } else { $script:PublishedConfigUrl }
}

<#
.SYNOPSIS
    Identify this build, including the fingerprint of the file that is running.

.DESCRIPTION
    `irm <url> | iex` runs whatever the host returns. That is a trust
    relationship with the host and no amount of code here changes it - but a
    person who saved the file first can compare this against the published
    hash and know they have the real thing.
#>
function Show-TrimVersion {
    Show-TrimBanner
    Write-Host "  Version   : $($script:TrimVersion)"
    Write-Host "  Canonical : $($script:SelfUrl)"
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $h = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
        Write-Host "  SHA256    : $h"
        Write-Host ''
        Write-Host '  Compare that against the hash published alongside the download.' -ForegroundColor DarkGray
        Write-Host '  If they differ, do not run it.' -ForegroundColor DarkGray
    } else {
        Write-Host '  SHA256    : not available - this was piped, not saved to a file.'
        Write-Host ''
        Write-Host '  To verify before running:' -ForegroundColor DarkGray
        Write-Host "    irm $($script:SelfUrl) -OutFile trim.ps1" -ForegroundColor DarkGray
        Write-Host '    Get-FileHash .\trim.ps1 -Algorithm SHA256' -ForegroundColor DarkGray
        Write-Host '    .\trim.ps1 -Version' -ForegroundColor DarkGray
    }
    Write-Host ''
}

if ($Version) { Show-TrimVersion; return }

# ---------------------------------------------------------------------------
# Self-elevate. Preserves all bound parameters across the elevation boundary.
# ---------------------------------------------------------------------------
# Before anything reads them, and before the relaunch below re-joins them:
# see Split-PhaseList. @() keeps an empty list a list rather than $null.
$Skip = @(Split-PhaseList $Skip)
$Only = @(Split-PhaseList $Only)

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Elevate up front, before anything is shown.
#
# The earlier design built the plan unelevated and only asked for rights at
# Apply. It read better on paper and was worse in practice: several HKLM keys
# cannot even be READ without administrator, so the preview was subtly wrong,
# and the run opened with a pair of access-denied failures before the window
# appeared. A tool that needs administrator to do its job should ask once, at
# the start, and then work.
#
# -DryRun is the exception. It genuinely only reads, and being able to inspect
# the plan without granting anything is worth keeping.
if (-not $isAdmin -and $DryRun) {
    Write-Host 'Dry run without administrator rights. A few machine-wide values' -ForegroundColor Yellow
    Write-Host 'cannot be read, so the preview may be incomplete. Nothing is changed.' -ForegroundColor DarkGray
    Write-Host ''
}
elseif (-not $isAdmin) {
    Show-TrimBanner
    Write-Host '  Administrator rights are needed. Approve the prompt to continue.' -ForegroundColor Yellow
    Write-Host ''

    # Both branches below elevate with -File, so the elevated process is handed
    # a script path and arguments rather than code. Start-Process still joins
    # them into one command line that the new process splits again, so they
    # go through Join-CommandLine first.
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

    if ($PSCommandPath) {
        # -File hands over a path and arguments rather than code. Strictly
        # safer than -Command and used whenever there is a file to point at.
        $fileArgs = @('-ExecutionPolicy','Bypass','-NoProfile','-File', $PSCommandPath)
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Key -notmatch '^[A-Za-z][A-Za-z0-9]*$') { continue }
            if ($kv.Value -is [switch]) {
                if ($kv.Value.IsPresent) { $fileArgs += "-$($kv.Key)" }
            } elseif ($kv.Value -is [array]) {
                $fileArgs += @("-$($kv.Key)", (($kv.Value | ForEach-Object { "$_" }) -join ','))
            } elseif ($null -ne $kv.Value -and "$($kv.Value)" -ne '') {
                $fileArgs += @("-$($kv.Key)", "$($kv.Value)")
            }
        }
        # Declining the UAC prompt throws, and an unhandled one surfaces a raw
        # "Start-Process : ... Access is denied" at somebody who simply chose
        # not to continue. That is not an error on their part.
        try { Start-Process $shell -Verb RunAs -ArgumentList (Join-CommandLine $fileArgs) }
        catch {
            Write-Host ''
            Write-Host '  Administrator rights were declined. Nothing has been changed.' -ForegroundColor Yellow
            Write-Host '  Trim needs them to write machine-wide settings.' -ForegroundColor DarkGray
            Write-Host ''
        }
    } else {
        # No file on disk to point at, so stage one and pin it by hash rather
        # than building a command line that downloads and executes.
        $self = Get-StagedSelf
        if (-not $self) { return }
        $stage  = $self.Path
        $staged = $self.Hash

        $fileArgs = @('-ExecutionPolicy','Bypass','-NoProfile','-NoExit','-File', $stage, '-ElevationHash', $staged)
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Key -notmatch '^[A-Za-z][A-Za-z0-9]*$') { continue }
            if ($kv.Value -is [switch]) {
                if ($kv.Value.IsPresent) { $fileArgs += "-$($kv.Key)" }
            } elseif ($kv.Value -is [array]) {
                $fileArgs += @("-$($kv.Key)", (($kv.Value | ForEach-Object { "$_" }) -join ','))
            } elseif ($null -ne $kv.Value -and "$($kv.Value)" -ne '') {
                $fileArgs += @("-$($kv.Key)", "$($kv.Value)")
            }
        }
        # Declining the UAC prompt throws, and an unhandled one surfaces a raw
        # "Start-Process : ... Access is denied" at somebody who simply chose
        # not to continue. That is not an error on their part.
        try { Start-Process $shell -Verb RunAs -ArgumentList (Join-CommandLine $fileArgs) }
        catch {
            Write-Host ''
            Write-Host '  Administrator rights were declined. Nothing has been changed.' -ForegroundColor Yellow
            Write-Host '  Trim needs them to write machine-wide settings.' -ForegroundColor DarkGray
            Write-Host ''
        }
    }
    return
}
