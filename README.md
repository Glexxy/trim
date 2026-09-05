<div align="center">

# Trim

**Debloat Windows 10 and 11 without breaking it.**

Trim rips out the ads, telemetry and preinstalled junk, then tunes what's left
for games. You see the whole list before anything happens.
Hate the result? One file puts it all back.

[![Licence: MIT](https://img.shields.io/badge/licence-MIT-4FE0B0?style=flat-square)](LICENSE)
[![Windows 10 and 11](https://img.shields.io/badge/Windows-10%20%7C%2011-4FE0B0?style=flat-square)](#requirements)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-4FE0B0?style=flat-square)](#requirements)
[![trimbloat.com](https://img.shields.io/badge/web-trimbloat.com-4FE0B0?style=flat-square)](https://trimbloat.com)

```powershell
irm https://trimbloat.com/go | iex
```

</div>

![The Trim window on its Overview screen](docs/screenshots/overview.png)

---

## What this is

A single PowerShell script that cleans up a Windows install. It runs from one
line, installs nothing, and opens a window listing every change it proposes —
the setting, what it is now, and what it would become — with a risk label on
each one.

Nothing on your machine changes until you click **Apply**. When you do, a System
Restore point is taken first, and every registry write is recorded beforehand so
the run can hand you a script that reverses all of it.

It is not a competitor to [WinUtil](https://github.com/ChrisTitusTech/winutil).
It *uses* WinUtil. See [attribution](#built-on-winutil).

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (ships with Windows) or PowerShell 7+
- Administrator rights to apply changes. **A dry run needs none** — you can
  inspect the entire plan before granting anything.

---

## What it does

| | |
|---|---|
| **Takes out the junk** | Advertising ID, telemetry, suggested content, Copilot, Widgets, Bing in Start, and the preinstalled apps you have never opened |
| **Sets it up for games** | Game Bar and background capture off, windowed-game optimisations on, foreground CPU priority, every installed game pointed at the high-performance GPU |
| **Finds wasted space** | 14 categories across *every* drive, each itemised with its size and location before anything is deleted |
| **Uninstalls properly** | Runs the app's own uninstaller, then finds the folders, registry keys, services and tasks it left behind. You approve each one |
| **Manages startup** | Everything that runs at sign-in, from all four places Windows keeps it, disabled the same way Task Manager does it |

Plus a curated NVIDIA global profile, network tuning that does the four things
with a measurable effect and nothing else, and the WinUtil tweak set.

---

## Screenshots

<table>
<tr>
<td width="50%"><img src="docs/screenshots/changes.png" alt="Every proposed change, with its current and new value"></td>
<td width="50%"><img src="docs/screenshots/startup.png" alt="Startup apps, with publisher and origin for each"></td>
</tr>
<tr>
<td><b>Every change, itemised.</b> Old value, new value, and a SAFE / CAUTION / RISKY label. Only SAFE is ticked when it opens.</td>
<td><b>Startup apps.</b> Who published it and where it is configured — neither of which Task Manager tells you.</td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/cleanup.png" alt="Disk cleanup categories with sizes"></td>
<td width="50%"><img src="docs/screenshots/uninstall.png" alt="Installed applications ready to uninstall"></td>
</tr>
<tr>
<td><b>Disk cleanup.</b> Every drive, not just C:. You are never agreeing to delete something described only as "temporary files".</td>
<td><b>Deep uninstall.</b> The app, then the mess it leaves behind — with registry keys exported to a <code>.reg</code> before deletion.</td>
</tr>
</table>

*(These are rendered from the running window by
[`test/Export-GuiScreenshots.ps1`](test/Export-GuiScreenshots.ps1), against a
representative demo machine. They cannot quietly stop matching the product.)*

---

## Should you trust this?

You are about to pipe a stranger's script into an admin shell. No, you should
not — and that includes trusting this README. Three ways to check, from easiest
to most convincing:

**1. Read it.** The script is served as plain text, not a download:
<https://trimbloat.com/go>

**2. Check the fingerprint.** Every build publishes its SHA256 at
<https://trimbloat.com/sha256>, and `-Version` prints the fingerprint of the
file actually on your machine.

```powershell
irm https://trimbloat.com/go -OutFile trim.ps1
Get-FileHash .\trim.ps1 -Algorithm SHA256
.\trim.ps1 -Version
```

**3. Build it yourself.** A hash we publish only proves nobody altered the file
in transit. It says nothing about whether the published script matches this
source. So **the build is reproducible** — same commit, same bytes:

```powershell
git clone https://github.com/Glexxy/trim
cd trim
.\build.ps1
```

If your fingerprint differs from the published one at the same commit, the
published script contains something this source does not. Don't run it.

Security reporting and the threat model: [SECURITY.md](SECURITY.md).

---

## Usage

**Run the dry run first.** It prints every change it would make alongside the
value currently there, needs no administrator rights, and touches nothing.

```powershell
.\trim.ps1 -DryRun
```

| Flag | What it does |
|---|---|
| `-DryRun` | Print the plan, change nothing |
| `-Gui` | Open the window |
| `-Skip Appx,Network` | Leave those phases out |
| `-Only Gaming,Nvidia` | Run only those phases |
| `-Cleanup` | Include the disk cleanup scan |
| `-NoRestorePoint` | Skip the restore point (not advised) |
| `-Version` | Print the version and this file's SHA256 |

### Undo

Every registry write goes through one function that records the prior value
first. At the end of the run — including after a crash — that ledger is written
out as a standalone rollback script:

```
C:\ProgramData\Trim\undo\undo_<timestamp>.ps1
```

Run it and every value goes back exactly as it was, including values that did
not exist before, which are *removed* rather than set to zero. A restore point
is taken before anything runs unless you pass `-NoRestorePoint`.

**Three things it cannot reverse**, said plainly because pretending otherwise is
worse than the limitation:

1. **Removed Store apps.** Reinstall them from the Store.
2. **WinUtil's own changes.** Use its restore point, or the one taken at the
   start of this run.
3. **`netsh` TCP settings.** One command, printed in the log:
   `netsh int tcp set global autotuninglevel=normal`

NVIDIA settings are backed up separately — the previous profile is exported to
`C:\ProgramData\Trim\nvidia\before_<timestamp>.nip` before the import, and the
log prints the command to restore it.

---

## Built on WinUtil

> **The debloat and tweak engine here is not ours.**
>
> Trim invokes [WinUtil by Chris Titus Tech](https://github.com/ChrisTitusTech/winutil)
> and lets it do that work. What this project adds is the wrapper around it: a
> recorded undo path, a dry run you can read, hardware detection, and a risk
> label on every change.
>
> **If you want a full Windows toolbox, go and use WinUtil.** It is more capable
> and better maintained than this. Full attribution and licences:
> [NOTICE.md](NOTICE.md).

---

## Things it deliberately will not do

**Touch your camera, microphone, screenshots or screen recording.** Those four
capabilities are on a never-touch list, and the deny list is checked against it
at runtime — a typo cannot switch off someone's webcam.

**Fan curves, BIOS, undervolting, overclocking.** Out of scope by design.

**AutoLogon.** WinUtil offers it. It writes the account password to
`HKLM\...\Winlogon\DefaultPassword` where anything running on the box can read
it back, and leaves the machine booting to an unlocked desktop.

**Remove Edge.** Debloat only. Removal breaks WebView2 dependents — Widgets,
some Teams and Office panes, third-party apps that embed it — and Windows Update
puts it back on most builds anyway.

**Remove load-bearing AppX packages.** `Microsoft.VCLibs`, `UI.Xaml`,
`NET.Native` and `WindowsAppRuntime` are frameworks other apps link against.
`DesktopAppInstaller` *is* winget. `XboxIdentityProvider` is how a large number
of PC games sign in — removing it produces launch failures that look nothing
like an AppX problem. All protected, prefix-matched and unit-tested.

**Phone home.** No analytics, no account, no telemetry of its own. The only
things it fetches are the script and, on NVIDIA machines, a pinned copy of
Profile Inspector.

---

## Things you should disagree with me about

Every one of these is a judgement call, not a fact. They are listed so you can
change them rather than discover them.

**Game Mode is turned off.** Genuinely contested — on 22H2 and later Game Mode
mostly suppresses background scheduling and blocks Windows Update restarts
mid-session, and on most machines it is neutral to helpful. Flip
`$script:DisableGameMode` in [`src/06-gaming.ps1`](src/06-gaming.ps1).

**Threaded Optimization is Auto, not Off.** The reference profile this was built
from had it Off. Off disables driver-side multithreading and costs real frames
in most modern engines; it is a per-game workaround that got applied globally.
Shipping Off to strangers would measurably hurt them. Change setting `549528094`
in [`src/11-gpu.ps1`](src/11-gpu.ps1) for the reference behaviour.

**Start's "most used apps" fights the privacy phase.** Showing it requires app
launch tracking (`Start_TrackProgs=1`), which is telemetry-adjacent. Set it to
`0` in [`src/08-personalisation.ps1`](src/08-personalisation.ps1) if you would
rather have the privacy.

**`SystemResponsiveness` is 10, not 0.** Most guides say 0. The default is 20,
which reserves 20% of CPU for background tasks. 10 is the trade; 0 starves audio
and can produce crackle under load.

**Most "network optimisation" is placebo.** The network phase does four things
with a measurable effect and deliberately nothing else. If it looks thin next to
the registry-key lists people paste around, that is the point.

---

<details>
<summary><b>For developers — layout, building and testing</b></summary>

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
docs/           generated screenshots and coverage report
hosting/        Cloudflare Worker, the landing page in site/, publish script
build.ps1       concatenates src/ into trim.ps1
```

`irm | iex` can only fetch one file, so the modular source is compiled into a
single script — the same pattern WinUtil uses.

```powershell
.\build.ps1
```

The build parses its own output and fails if concatenation produced anything
that does not compile. It also refuses to run if any source file is non-ASCII
without a UTF-8 BOM, because Windows PowerShell reads those as ANSI and
silently corrupts them.

### Testing

Three tiers, cheapest first. All are safe on your own machine except the last,
which refuses to start outside a VM.

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
and nothing hardcodes a drive letter, `WOW6432Node`, or `ProgramFiles(x86)`.

`Test-UndoRoundTrip.ps1` is the one that proves the safety claim rather than
asserting it. It applies real changes and really runs the undo script, confined
to a throwaway key (`HKCU:\Software\TrimRoundTripTest`), covering every registry
type including `MultiString` and `QWord`, values containing quotes and
semicolons, values that did not exist before, keys that did not exist at all,
and explicit removals.

`Invoke-VmVerification.ps1` applies for real, reads the run's own ledger, and
asserts that every recorded change is present, that undo returns each to its
prior value, and that a second consecutive run is a complete no-op.

**What no VM will cover: the NVIDIA phase.** There is no GPU passthrough in
Sandbox and none in Hyper-V without DDA on a server SKU, so it detects no card
and skips. It has to be validated on real hardware against a machine whose
profile you exported first.

### Two WinUtil behaviours worth knowing

Verified against WinUtil v26.08.19 by reading the source, not the docs.

1. **`Invoke-WinUtilAutoRun` never processes toggles.** It runs Tweaks,
   Features, Apps and AppX. Any `WPFToggle*` key in a `-Config` file is imported
   and then silently ignored. That is why the entire "Customize Preferences"
   column is reimplemented here as direct registry writes.
2. **The Fixes panel entries are Buttons, not checkboxes.** `WPFPanelAutologin`,
   `WPFPanelDISM` and `WPFWinUtilInstallPSProfile` are not valid config keys —
   `Update-WinUtilSelections` throws `Unsupported selection key` on them.

`-Config` accepts an https URL as well as a local path, which is what makes the
whole thing distributable as a single line.

### Publishing

One command builds, runs the whole suite, stages, verifies the staged bytes
against the fingerprint it is about to publish, and only then uploads:

```powershell
.\hosting\Publish-Trim.ps1 -DryRun   # everything except the upload
.\hosting\Publish-Trim.ps1           # for real
```

It refuses to publish a build that does not parse, does not pass the suite,
still contains a placeholder URL, or whose staged bytes do not match the hash in
its own sidecar.

The site is a static page in `hosting/site/`, not markup inside the Worker. The
Worker substitutes one token, `{{SHA256}}`, from the sidecar of the script that
deployment actually serves, so the hash on the page cannot drift from the script
beside it. The publish script substitutes `{{V}}`, which versions every asset
URL — assets are served `immutable` for a year, so if a redeploy did not change
their URLs a returning visitor would get new HTML against a year-old cached
stylesheet. That version hashes the asset bytes, *not* the compiled script,
which was the first attempt and is wrong in a way that is easy to miss: editing
only the CSS leaves the script's fingerprint unchanged.

The page is served under `default-src 'none'` with `script-src 'self'` and no
inline script, which is why the copy handler lives in `site/app.js`.

### Regenerating the screenshots

```powershell
.\test\Export-GuiScreenshots.ps1     # docs\screenshots\*.png, 2320px
.\hosting\Build-SiteAssets.ps1       # -> hosting\site\img\*.webp, 1x and 2x
.\hosting\Build-OgImage.ps1          # -> og.png and the touch icon
```

`Export-GuiScreenshots.ps1` builds the genuine window from a real dry-run
manifest and renders each pane with `RenderTargetBitmap`. It defaults to a
**representative demo machine** rather than the one it is running on: the
Overview pane prints the motherboard, BIOS version, disk models and volume
labels of whoever generated it, and the phase panes list the full path of every
installed game. Pass `-Real` to render your own.

`Build-SiteAssets.ps1` needs `cwebp` or `ffmpeg` on PATH and does nothing
without them — the encoded files are committed, so publishing never depends on
either being installed.

</details>

---

## Contributing

Issues and pull requests are welcome. Two things worth knowing before you open
one:

- **Run `.\test\Invoke-DryRunHarness.ps1` and `.\test\Test-UndoRoundTrip.ps1`.**
  The build also refuses source files that are non-ASCII without a UTF-8 BOM.
- **New registry writes need a `-Because` and a tier**, and if the setting only
  exists on one Windows version, a `-MinBuild` or `-MaxBuild`. The harness
  checks this.

## Licence

[MIT](LICENSE). WinUtil, the CTT PowerShell profile and NVIDIA Profile Inspector
are third-party and separately licensed — see [NOTICE.md](NOTICE.md).
