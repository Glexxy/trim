# Security

Trim runs as administrator and is distributed as a one-line paste. That is a
serious combination, and the honest starting point is what it cannot fix.

## The part no code can solve

```powershell
irm https://example/trim.ps1 | iex
```

runs whatever the host returns, as administrator, with no review. If the host is
compromised, or DNS or TLS is subverted between you and it, you run the
attacker's code. **This is true of every `irm | iex` tool, including the ones you
already trust.** Nothing in this repository changes it.

What it does mean is that the trust boundary is the *host*, so the host is the
thing to secure and the thing to verify.

### Verifying before you run

```powershell
irm https://trimbloat.com/trim.ps1 -OutFile trim.ps1
Get-FileHash .\trim.ps1 -Algorithm SHA256
.\trim.ps1 -Version
```

`-Version` reports the SHA256 of the file that is actually running. Compare it
against `trim.ps1.sha256`, published beside every release and served at
`https://trimbloat.com/sha256`. If they differ, do not run it.

### Verifying against the source, not just against us

Comparing a download to a hash we also publish only proves the file was not
altered in transit. It says nothing about whether the published script matches
the source you can read.

**The build is reproducible**, so you can check that yourself:

```powershell
git clone https://github.com/Glexxy/trim.git
cd trim
.\build.ps1
```

The resulting `trim.ps1.sha256` will match the published fingerprint byte for
byte at the same commit. Two things make that hold, and both are enforced
rather than hoped for: the compiled header stamps the **commit**, not the build
time, and `.gitattributes` pins line endings so a clone and the authoring
machine cannot differ by invisible whitespace.

If a clone at the published commit does not reproduce the published hash, the
published script contains something the source does not. Do not run it.

---

## What is defended, and how

### Elevation cannot be hijacked

Trim relaunches itself elevated. Where a script path exists it uses
`-File` with an argument array, so nothing is parsed out of a composed string at
all. Where it does not — a piped `irm | iex` run — every interpolated value goes
through `ConvertTo-SafeArgument`, which doubles single quotes and **rejects
control characters outright** rather than escaping them.

This was a real hole, not a theoretical one. Before it was fixed, a value
containing a single quote broke out of its quoting and executed arbitrary code
in the elevated process, immediately after the user approved a UAC prompt they
believed they were granting to Trim.

Covered by *Elevation arguments cannot break out of their quoting*, which
rebuilds the exact construction the elevation path uses and asserts the value
survives as a literal.

### No tool is resolved through PATH

Running as administrator means a bare `netsh` executes whatever a writable PATH
entry happens to contain, with those rights. Every external tool goes through
`Get-SystemTool`, which resolves under `System32` (or `Sysnative`) and returns
nothing rather than falling back to something else of the same name.

A test walks the source and fails the build if any file invokes one by bare name.

### The one downloaded binary is pinned by hash

Trim downloads exactly one executable — NVIDIA Profile Inspector — and then runs
it as administrator. It is pinned by release version *and* SHA256, and the
archive is verified **before** extraction. A mismatch is deleted, reported, and
the phase is skipped.

Finding this also found a plain bug: the pinned version had been `2.4.0.14`,
which does not exist. Every download 404'd and the NVIDIA profile silently never
applied on any machine.

### Modern TLS only

TLS 1.2/1.3 is set before the first fetch. Windows PowerShell 5.1 still defaults
to SSL3/TLS1.0 on some builds. A test asserts the shipped script enables it
*before* the first fetch appears, and that no source file references `http://`.

### The selection file is untrusted input

The window writes a selection; an elevated process reads it. Worth being precise
about what that file can do: a selection key only gates whether a change the
phases were **already going to make** actually happens. It cannot introduce a new
change, name a path, or carry a command. A tampered file can at worst toggle
Trim's own options.

Keys are still validated against a strict pattern, and a key matching nothing
produces no changes — asserted by test.

### Deleting things

Two features can destroy data, and both are built guards-first.

**Disk cleanup** never globs a drive. Every path is named. A cleanup tool that
walks the filesystem deciding what looks like junk is how people lose work.

**Deep uninstall** applies six vetoes, default answer no: the path must be under
a real application root; at least three segments deep, so no code path can reach
`C:\Program Files` or `C:\Users\<name>`; the folder name must resemble the app or
publisher; Microsoft, NVIDIA, AMD, Intel and shared runtimes are refused
wholesale; every registry key is exported to `.reg` first; and the guard runs
again immediately before each delete.

The guards fail **closed** — passing an empty path returns false rather than
throwing, because a guard that crashes instead of refusing is a guard that fails
open. That was a real bug, caught by its own test.

Neither feature is reachable from any preset. Tested.

### Everything else is reversible

Every registry write is recorded before it is made and reversed by a generated
undo script — including removing values that did not previously exist, rather
than writing zero over them. Verified end to end in Windows Sandbox: 66 changes
applied, all 66 present, all 66 restored exactly, second run a complete no-op.

---

## Third-party code this runs

Stated plainly, because it is part of the trust decision:

| What | From | Trust |
|---|---|---|
| WinUtil | `christitus.com/win`, fetched and executed | Chris Titus Tech's infrastructure, at administrator level |
| CTT PowerShell profile | GitHub, fetched and executed | same, PowerShell 7+ only, opt-in |
| NVIDIA Profile Inspector | GitHub release, downloaded and executed | pinned by version and SHA256 |

The first two are `iex` of a remote script. That is inherent to using WinUtil at
all — Trim orchestrates it rather than reimplementing it — but you should know
it is happening. Skip them with `-Skip WinUtil,Fixes`.

---

## Reporting a problem

For anything exploitable, use GitHub's private vulnerability reporting on this
repository (**Security -> Report a vulnerability**). That reaches the maintainer
without the report being public while it is being fixed.

If that option is not visible, open a normal issue saying only that you have
found a security problem and need a private channel - no details, no proof of
concept - and one will be arranged. Do not post the details publicly first.

For anything else - a bug, a setting you think is wrong, a machine it behaved
badly on - open a normal issue. Include the log from
`C:\ProgramData\Trim\logs\`, which records every change and every skip.

## Not claimed

- Trim is **not** code-signed. Worth being precise about what that does and
  does not mean here: SmartScreen gates *downloaded executables*, and
  `irm | iex` never writes a file to disk for it to gate. Authenticode on a
  `.ps1` only takes effect under an `AllSigned` execution policy, which piping
  does not go through either. So signing would change very little about this
  distribution method - it would start mattering the day an `.exe` ships.
  Verify the SHA256 and the reproducible build instead; those are the checks
  that actually apply.
- No formal audit has been done.
- The threat model is a careless or malicious *input*, not a hostile
  administrator. Anyone who already has administrator on the machine does not
  need this program.
