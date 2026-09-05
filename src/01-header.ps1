#Requires -Version 5.1
<#
.SYNOPSIS
    Trim - opinionated, reversible Windows 11 tuning.

.DESCRIPTION
    Applies a curated set of debloat, privacy, gaming and personalisation changes
    to a Windows 11 machine. Every registry write is recorded before it is made,
    and an undo script is emitted at the end of the run.

    Designed to be run on someone else's machine: it detects laptop vs desktop and
    GPU vendor, and skips anything that does not apply rather than guessing.

.PARAMETER DryRun
    Show every change that would be made without making any of them. Still writes
    a log. Use this first, always.

.PARAMETER Skip
    Phases to skip. Valid: WinUtil, Fixes, Gaming, Privacy, Personalisation,
    Appx, Network, Nvidia.

.PARAMETER Only
    Run only these phases. Overrides -Skip.

.PARAMETER NoRestorePoint
    Skip creating a system restore point. Not recommended.

.PARAMETER Aggressive
    Include changes that are effective but more likely to surprise the user:
    removing more AppX packages, disabling more background services.

.EXAMPLE
    .\trim.ps1 -DryRun

.EXAMPLE
    .\trim.ps1 -Skip Appx,Network

.EXAMPLE
    irm https://example.com/opt.ps1 | iex
#>
[CmdletBinding()]
param(
    [switch]$DryRun,

    [ValidateSet('WinUtil','Fixes','Performance','Gaming','Graphics','Privacy','Background','Appx','Network','Security','Personalisation','Extras','Extras')]
    [string[]]$Skip = @(),

    [ValidateSet('WinUtil','Fixes','Performance','Gaming','Graphics','Privacy','Background','Appx','Network','Security','Personalisation','Extras')]
    [string[]]$Only = @(),

    # Show the window instead of running straight through. Builds the plan
    # unelevated, then asks for administrator rights only at Apply.
    [switch]$Gui,

    # Internal: apply a selection saved by an earlier, unelevated window.
    [string]$ApplySelection = '',

    # Run the disk cleanup sweep from the command line. Never part of a preset.
    [switch]$Cleanup,
    [switch]$IncludeDuplicates,

    # Report the biggest files on every drive. Report only - nothing here is
    # ever deleted, because a large file and a junk file look identical from
    # the outside.
    [switch]$LargeFiles,

    # Internal: delete a cleanup selection saved by an earlier window.
    [string]$CleanupSelection = '',

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
    Make a value safe to embed inside a single-quoted PowerShell string.

.DESCRIPTION
    This program relaunches itself elevated by composing a -Command string. Any
    argument interpolated into that string crosses a privilege boundary, so an
    unescaped quote is not a formatting bug - it is arbitrary code execution as
    administrator, running immediately after the user approves the UAC prompt
    that they believe they are granting to this program.

    Doubling the quote is the correct escape for a single-quoted PowerShell
    string. Control characters are rejected outright rather than escaped:
    nothing this program legitimately passes contains one, so their presence
    means somebody is trying something.
#>
function ConvertTo-SafeArgument {
    param([AllowEmptyString()][AllowNull()][string]$Value = '')
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value -match '[\x00-\x1F]') {
        throw "Refusing to pass an argument containing control characters: '$Value'"
    }
    return ($Value -replace "'", "''")
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

    # Parameter names are our own, from the param block, so they need no
    # escaping. Every VALUE does: it crosses into an elevated process.
    $argList = @()
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Key -notmatch '^[A-Za-z][A-Za-z0-9]*$') { continue }   # cannot happen; cheap to assert

        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
        }
        elseif ($kv.Value -is [array]) {
            # ValidateSet already constrains these, and they are joined into one
            # quoted token rather than spliced in bare.
            $joined = ConvertTo-SafeArgument (($kv.Value | ForEach-Object { "$_" }) -join ',')
            $argList += "-$($kv.Key) '$joined'"
        }
        elseif ($null -ne $kv.Value -and "$($kv.Value)" -ne '') {
            $argList += "-$($kv.Key) '$(ConvertTo-SafeArgument "$($kv.Value)")'"
        }
    }

    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }

    if ($PSCommandPath) {
        # -File takes the script and its arguments as separate array elements,
        # so nothing is parsed out of a composed string at all. Strictly safer
        # than -Command and used whenever there is a file to point at.
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
        Start-Process $shell -Verb RunAs -ArgumentList $fileArgs
    } else {
        # Running from `irm | iex`: there is no file on disk to re-invoke, so it
        # is re-fetched from source. Every value here has been escaped above.
        $inner = "&([ScriptBlock]::Create((irm '$(ConvertTo-SafeArgument $script:SelfUrl)'))) $($argList -join ' ')"
        Start-Process $shell -Verb RunAs -ArgumentList @(
            '-ExecutionPolicy','Bypass','-NoProfile','-NoExit','-Command', $inner
        )
    }
    return
}
