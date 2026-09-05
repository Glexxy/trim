# One definition, dot-sourced by the exporter that writes the screenshot stamp
# and by the harness that checks it.
#
# A shared file rather than two copies on purpose: this project spent a day
# fixing rules that had been written into one of two places and not the other,
# and a fingerprint that two callers compute differently is worse than no
# fingerprint at all.

function Get-GuiFingerprint {
    <#
    .SYNOPSIS
        A fingerprint of a source file that means the same thing everywhere.

    .DESCRIPTION
        Line-ending normalised, deliberately. .gitattributes marks sources
        eol=crlf, so a fresh clone and a working copy hold identical text in
        different bytes. Hashing the bytes made the screenshot stamp agree with
        this machine and disagree with CI - the same LF/CRLF divergence that
        once made the published build differ from a fresh clone of the same
        commit.

        ReadAllText also drops a byte order mark, so a file gains or loses one
        without changing its fingerprint. That is correct here: neither changes
        what the window looks like.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
    } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-', '')
}
