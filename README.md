<div align="center">

# Trim

**Debloat Windows 10 and 11 without breaking it.**

Strips out the ads, telemetry and preinstalled junk. Tunes what's left for games.
Cleans your drives, uninstalls properly, and takes control of what starts with
Windows — showing you every single change before it makes one.

[![Licence: MIT](https://img.shields.io/badge/licence-MIT-4FE0B0?style=flat-square)](LICENSE)
[![Windows 10 and 11](https://img.shields.io/badge/Windows-10%20%7C%2011-4FE0B0?style=flat-square)](#requirements)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-4FE0B0?style=flat-square)](#requirements)
[![Reversible](https://img.shields.io/badge/every%20change-reversible-4FE0B0?style=flat-square)](#everything-is-reversible)

```powershell
irm https://trimbloat.com/go | iex
```

**Free. Open source. Nothing gets installed.**

</div>

![The Trim window on its Overview screen](docs/screenshots/overview.png)

---

## What it does

Six things, and it shows you the full plan for each one before touching
anything.

### Removes the junk
Advertising ID, telemetry, activity history, suggested content, Copilot,
Widgets, Bing wedged into your Start menu, inking and typing data collection,
speech harvesting, feedback prompts, and the preinstalled apps you have never
opened. Around **60 changes on a typical PC**, each one listed with its current
value and its new one.

Edge can go too, if you want it gone — the browser only, leaving WebView2 so the
apps that render with it keep working.

### Sets it up for games
Game Bar and background recording off. Windowed-game optimisations on. CPU
priority weighted to whatever you are actually looking at. Hardware GPU
scheduling. Every installed game — Steam, Epic, Xbox, GOG, EA, Ubisoft,
Battle.net — found and pointed at your real GPU instead of the integrated one.

### Tunes NVIDIA properly
A curated global profile applied through NVIDIA Profile Inspector, composed
**per card**. A 5070 Ti gets multi-frame generation settings a 1660 has never
heard of, and the 1660 does not get sent them — a single unknown setting makes
the driver reject the whole profile.

### Finds wasted space
Fourteen categories across *every* drive you have, not just C:. Update
leftovers, delivery caches, crash dumps, shader caches, thumbnail databases, the
recycle bins you forgot about. Each one itemised with its size and location
before a single file goes. Plus a duplicate finder and a large-file scanner.

### Uninstalls properly
Runs the application's own uninstaller, then goes looking for what it
abandoned — folders, registry keys, services, scheduled tasks — and shows you
each one with its full path. Registry keys are exported to a `.reg` before
deletion. Anything that does not clearly belong to what you just removed is left
alone and reported.

### Controls what starts with Windows
Every program that runs at sign-in, gathered from all four places Windows keeps
them, each with its publisher and where it is configured. Task Manager shows you
a list; this shows you where the list comes from.

Underneath all of that sits a privacy pass, a network phase, scheduled-task and
service tuning, a performance phase, and the WinUtil tweak set
([credited below](#credits)).

---

## Screenshots

<table>
<tr>
<td width="50%"><img src="docs/screenshots/changes.png" alt="Every proposed change, with its current and new value"></td>
<td width="50%"><img src="docs/screenshots/startup.png" alt="Startup apps, with publisher and origin for each"></td>
</tr>
<tr>
<td><b>Every change, itemised.</b> The setting, what it is now, what it becomes, and a SAFE / CAUTION / RISKY label. Only SAFE is ticked when it opens.</td>
<td><b>Startup apps.</b> Who published it and where it is configured — neither of which Task Manager tells you.</td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/cleanup.png" alt="Disk cleanup categories with sizes"></td>
<td width="50%"><img src="docs/screenshots/uninstall.png" alt="Installed applications ready to uninstall"></td>
</tr>
<tr>
<td><b>Disk cleanup.</b> Every drive, not just C:. You are never agreeing to delete something described only as "temporary files".</td>
<td><b>Deep uninstall.</b> The app, then the mess it leaves behind.</td>
</tr>
</table>

*Rendered directly from the running window by
[`test/Export-GuiScreenshots.ps1`](test/Export-GuiScreenshots.ps1), so they
cannot quietly stop matching the product.*

---

## Everything is reversible

This is the part most debloaters get wrong, so it is worth being specific.

Every registry write goes through a single function that records the previous
value **before** it changes anything. At the end of the run — including if it
crashes halfway — that ledger is written out as a standalone rollback script:

```
C:\ProgramData\Trim\undo\undo_<timestamp>.ps1
```

Run it whenever you like, weeks later if you want, and every value returns to
exactly what it was. Values that did not exist before are *removed* rather than
set to zero, which is the single case that makes most "restore" scripts quietly
lie about having worked.

- A **System Restore point** is taken before anything runs.
- Startup shortcuts are **moved, not deleted**.
- Registry keys are **exported to `.reg`** before a deep uninstall removes them.
- NVIDIA's previous profile is **exported to `.nip`** before the new one is
  imported.

The undo path is tested rather than asserted:
[`test/Test-UndoRoundTrip.ps1`](test/Test-UndoRoundTrip.ps1) applies real
changes and really runs the rollback, checking every registry type, values
containing quotes and semicolons, values that did not previously exist, and keys
that did not exist at all.

**Three things it cannot take back**, stated plainly because pretending
otherwise would be worse:

1. **Removed Store apps** — reinstall them from the Store.
2. **WinUtil's own changes** — that is what the restore point is for.
3. **`netsh` TCP settings** — one command, printed in the log.

---

## Safety

- **Nothing happens until you click Apply.** The scan needs no administrator
  rights at all, so you can read the entire plan before granting anything.
- **Only SAFE changes are ticked by default.** CAUTION and RISKY exist, are
  labelled, and are opt-in.
- **Your camera and microphone are never touched.** Those, plus screenshots and
  screen recording, sit on a never-touch list enforced at runtime and asserted
  by the test suite — a careless edit cannot switch off someone's webcam.
- **No fan curves, BIOS, undervolting or overclocking.** Nothing here can damage
  hardware.
- **Load-bearing components are protected.** Shared runtimes, winget and the
  Xbox sign-in service are prefix-matched against the removal list and
  unit-tested so the two can never overlap.
- **Hardware is detected, not assumed.** Laptop or desktop, NVIDIA or AMD or
  Intel, SSD or spinning disk, Windows 10 or 11 — it checks, then skips what
  does not apply rather than writing values nothing reads.
- **No analytics, no account, no telemetry of its own.**

## Verifying it

Piping a script into an administrator shell deserves a check. Three, in
increasing order of thoroughness:

**Read it.** The script is served as plain text, not a download —
<https://trimbloat.com/go> opens in a browser tab.

**Check the fingerprint.** Every build publishes its SHA256 at
<https://trimbloat.com/sha256>, and `-Version` prints the fingerprint of the
file on your machine.

```powershell
irm https://trimbloat.com/go -OutFile trim.ps1
Get-FileHash .\trim.ps1 -Algorithm SHA256
.\trim.ps1 -Version
```

**Build it yourself.** A published hash only proves the file was not altered in
transit. So the build is **reproducible** — the same commit produces byte-identical
output, which means you can confirm the published script is this source:

```powershell
git clone https://github.com/Glexxy/trim
cd trim
.\build.ps1
```

Threat model and vulnerability reporting: [SECURITY.md](SECURITY.md).

---

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (ships with Windows) or PowerShell 7+
- Administrator rights to apply changes — **the dry run needs none**

## Usage

```powershell
.\trim.ps1 -DryRun
```

| Flag | What it does |
|---|---|
| `-DryRun` | Print the full plan, change nothing |
| `-Gui` | Open the window |
| `-Skip Appx,Network` | Leave those phases out |
| `-Only Gaming,Nvidia` | Run only those phases |
| `-Cleanup` | Include the disk cleanup scan |
| `-NoRestorePoint` | Skip the restore point (not advised) |
| `-Version` | Print the version and this file's SHA256 |

---

## Credits

Trim's WinUtil phase invokes
**[WinUtil by Chris Titus Tech](https://github.com/ChrisTitusTech/winutil)** to
apply its tweak set, rather than reimplementing work that already exists and is
well maintained. That phase is one of twelve; everything else here — the undo
ledger, the dry-run manifest, hardware detection, risk labelling, the disk
cleanup, the deep uninstall, the startup manager, the NVIDIA profile and the
interface — is this project's own.

Also used, and separately licensed:

- **[NVIDIA Profile Inspector](https://github.com/Orbmu2k/nvidiaProfileInspector)** by Orbmu2k — the only reliable way to write the driver's binary profile store. Pinned by version *and* SHA256.
- **[CTT PowerShell Profile](https://github.com/ChrisTitusTech/powershell-profile)** by Chris Titus Tech — optional, installed only on PowerShell 7+.

Full attribution and licence texts: [NOTICE.md](NOTICE.md).

---

## Contributing

Issues and pull requests welcome. Before opening one:

- Run `.\test\Invoke-DryRunHarness.ps1` and `.\test\Test-UndoRoundTrip.ps1`.
- New registry writes need a `-Because` and a tier, plus a `-MinBuild` or
  `-MaxBuild` if the setting only exists on one Windows version. The harness
  checks this.
- Source files must be UTF-8 with a BOM — the build refuses otherwise, because
  Windows PowerShell reads BOM-less files as ANSI and silently corrupts them.

The reasoning behind the contested defaults — Game Mode, Threaded Optimization,
`SystemResponsiveness` and the rest — is in
[docs/DECISIONS.md](docs/DECISIONS.md), along with what is deliberately not
implemented and why.

<details>
<summary><b>Layout, building and testing</b></summary>

### Layout

```
src/            numbered modules, concatenated in filename order
  01-header     param block, TLS, banner, self-elevation
  02-core       logging, the undo ledger, the guarded registry writer
  03-detect     hardware and OS facts
  04..12        phases
  13-gui        the window
  14..19        performance, tasks, cleanup, uninstall, extras, startup
  99-main       orchestration
config/         winutil selection config
test/           dry-run harness, undo round-trip, GUI and VM verification
tools/          Repair-Encoding.ps1 - the build's encoding guard
docs/           design decisions, generated screenshots
hosting/        Cloudflare Worker, the landing page in site/, publish script
build.ps1       concatenates src/ into trim.ps1
```

`irm | iex` can only fetch one file, so the modular source compiles into a single
script.

```powershell
.\build.ps1
```

The build parses its own output and fails if concatenation produced anything
that does not compile.

### Testing

```powershell
.\test\Invoke-DryRunHarness.ps1     # seconds, host-safe
.\test\Test-UndoRoundTrip.ps1       # seconds, host-safe
.\test\Test-GuiInteraction.ps1      # needs -STA
.\test\Invoke-SandboxTest.ps1       # Windows Sandbox, ~5 min
.\test\New-TestVm.ps1 -IsoPath ...  # Hyper-V, ~20 min to build
```

The harness runs every phase's dry-run path unelevated, plus guards on the
pieces most likely to be broken by a careless edit: the undo generator produces
parseable PowerShell in reverse order with quotes escaped; no AppX removal
collides with the protected list; camera, microphone and screen capture are
absent from the deny list; every Windows 11-only setting carries a build gate;
and nothing hardcodes a drive letter, `WOW6432Node` or `ProgramFiles(x86)`.

`Invoke-VmVerification.ps1` applies for real, reads the run's own ledger, and
asserts that every recorded change is present, that undo returns each to its
prior value, and that a second consecutive run is a complete no-op. It refuses
to start outside a VM.

**What no VM will cover: the NVIDIA phase.** There is no GPU passthrough in
Sandbox and none in Hyper-V without DDA on a server SKU, so it detects no card
and skips. It has to be validated on real hardware.

### Publishing

```powershell
.\hosting\Publish-Trim.ps1 -DryRun   # everything except the upload
.\hosting\Publish-Trim.ps1           # for real
```

Builds, runs the whole suite, stages, verifies the staged bytes against the
fingerprint it is about to publish, and only then uploads. It refuses a build
that does not parse, does not pass the suite, still contains a placeholder URL,
or whose staged bytes do not match its own sidecar.

### Regenerating the screenshots

```powershell
.\test\Export-GuiScreenshots.ps1     # docs\screenshots\*.png, 2320px
.\hosting\Build-SiteAssets.ps1       # -> hosting\site\img\*.webp, 1x and 2x
.\hosting\Build-OgImage.ps1          # -> og.png and the touch icon
```

`Export-GuiScreenshots.ps1` renders each pane of the genuine window with
`RenderTargetBitmap`, driven by a real dry-run manifest. It defaults to a
representative demo machine rather than the one it runs on, because the Overview
pane prints the motherboard, BIOS version, disk models and volume labels of
whoever generated it, and the phase panes list the full path of every installed
game. Pass `-Real` for your own.

</details>

## Licence

[MIT](LICENSE). Third-party components are separately licensed — see
[NOTICE.md](NOTICE.md).
