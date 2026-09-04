# Trim

Reversible Windows 11 tuning, distributable as a one-liner. Built to run on a
machine you have never seen: it detects laptop vs desktop and GPU vendor, and
skips what does not apply rather than guessing.

> ### Built on WinUtil by [Chris Titus Tech](https://github.com/ChrisTitusTech/winutil)
>
> The debloat and tweak engine here is **not** ours. This tool invokes
> [christitus.com/win](https://christitus.com/win) and lets WinUtil do that work;
> what this project adds is a reversible wrapper around it — a recorded undo path,
> a dry-run manifest, and hardware gating.
>
> **If you want a Windows utility, go use WinUtil.** It is more capable and better
> maintained than this. See [NOTICE.md](NOTICE.md) for full attribution and licences.

```powershell
irm https://trimbloat.com/go | iex
```

**Run it with `-DryRun` first. Always.** It prints every change it would make,
alongside the value currently there, and touches nothing.

```powershell
.\trim.ps1 -DryRun
```

---

## What it does

| Phase | What |
|---|---|
| `WinUtil` | Chris Titus' winutil, headless, with a pinned selection config |
| `Fixes` | DISM `/RestoreHealth` then `sfc /scannow`; CTT PowerShell profile |
| `Gaming` | Game Bar, Captures, Game Mode off; windowed-game optimisations on; discovered games set to the high-performance GPU |
| `Privacy` | Advertising ID, suggested content, inking/typing, speech, feedback, app permissions |
| `Appx` | Named-list bloatware removal with a protected list |
| `Network` | Multimedia scheduling, Nagle, TCP defaults, NIC power saving |
| `Nvidia` | Curated global profile via NVIDIA Profile Inspector |
| `Personalisation` | Start, taskbar, background |

Skip or isolate phases:

```powershell
.\trim.ps1 -Skip Appx,Network
.\trim.ps1 -Only Gaming,Nvidia
```

---

## Undo

Every registry write goes through one function that records the prior value
first. At the end of the run — including after a crash — that ledger is emitted
as a standalone rollback script:

```
C:\ProgramData\Trim\undo\undo_<timestamp>.ps1
```

Run it to put every registry value back exactly as it was. A restore point is
also taken before anything runs, unless you pass `-NoRestorePoint`.

**Three things the undo script cannot reverse**, called out because pretending
otherwise is worse than the limitation:

1. **AppX removals.** Reinstall from the Store.
2. **WinUtil's changes.** Use its own restore point, or the one taken at the
   start of this run.
3. **`netsh` TCP settings.** Reverse manually:
   `netsh int tcp set global autotuninglevel=normal`

NVIDIA settings are separately backed up: the previous profile is exported to
`C:\ProgramData\Trim\nvidia\before_<timestamp>.nip` before the import,
and the log prints the exact command to restore it.

---

## Things you should disagree with me about

Every one of these is a judgement call, not a fact. They are listed so you can
change them rather than discover them.

**Game Mode is turned off.** That is what was asked for, but it is genuinely
contested — on 22H2 and later Game Mode mostly suppresses background scheduling
and blocks Windows Update restarts mid-session, and on most machines it is
neutral to helpful. Flip `$script:DisableGameMode` in `src/06-gaming.ps1`.

**Threaded Optimization is set to Auto, not Off.** The reference profile this was
built from had it Off. Off disables driver-side multithreading and costs real
frames in most modern engines; it is a per-game workaround that got applied
globally. Shipping Off to strangers would measurably hurt them, so it is Auto.
If you want the reference behaviour, change setting `549528094` to `0` in
`src/11-gpu.ps1`.

**Start's "most used apps" fights the privacy phase.** Showing it requires app
launch tracking (`Start_TrackProgs=1`), which is a telemetry-adjacent setting the
privacy phase would otherwise turn off. The explicit Start instruction wins. Set
`Start_TrackProgs` to `0` in `src/08-personalisation.ps1` if you would rather have
the privacy.

**`SystemResponsiveness` is set to 10, not 0.** Most guides say 0. The default is
20, which reserves 20% of CPU for background tasks. 10 is the trade; 0 starves
audio and can produce crackle under load.

**Most "network optimization" is placebo.** The network phase does four things
with a measurable effect and deliberately nothing else. If it looks thin next to
the registry-key lists people paste around, that is the point.

---

## Things it deliberately will not do

**AutoLogon.** It writes the account password to
`HKLM\...\Winlogon\DefaultPassword` in a form anything running on the box can
read back, and leaves the machine booting straight to an unlocked desktop. Not a
trade worth making on a machine you hand back to someone else.

**Remove Edge.** Debloat only. Removal breaks WebView2 dependents (Widgets, some
Teams and Office panes, third-party apps that embed it) and Windows Update puts
it back on most builds anyway.

**Touch camera, microphone, screenshots or screen recording.** Those four
capabilities are on a never-touch list, and the deny list is checked against it
at runtime — a typo cannot turn off someone's webcam.

**Remove load-bearing AppX packages.** `Microsoft.VCLibs`, `UI.Xaml`,
`NET.Native` and `WindowsAppRuntime` are frameworks other apps link against.
`DesktopAppInstaller` *is* winget. `XboxIdentityProvider` is how a large number
of PC games sign in — removing it produces launch failures that look nothing
like an AppX problem. All protected, prefix-matched, and unit-tested.

**Fan curves, BIOS, undervolting, overclocking.** Out of scope by design.

---

## Two winutil behaviours worth knowing

Verified against winutil v26.08.19 by reading the source, not the docs.

1. **`Invoke-WinUtilAutoRun` never processes toggles.** It runs Tweaks, Features,
   Apps and AppX. Any `WPFToggle*` key in a `-Config` file is imported and then
   silently ignored. That is why the entire "Customize Preferences" column is
   reimplemented here as direct registry writes.
2. **The Fixes panel entries are Buttons, not checkboxes.** `WPFPanelAutologin`,
   `WPFPanelDISM` and `WPFWinUtilInstallPSProfile` are not valid config keys —
   `Update-WinUtilSelections` throws `Unsupported selection key` on them. The
   `Fixes` phase reimplements the ones worth having.

`-Config` accepts an https URL as well as a local path, which is what makes the
whole thing distributable as a single line.

---

## Layout

```
src/            numbered modules, concatenated in filename order
  01-header     param block, TLS, banner, self-elevation
  02-core       logging, the undo ledger, the guarded registry writer
  03-detect     hardware and OS facts
  04..12        phases
  13-gui        the window
  14..18        performance, scheduled tasks, cleanup, uninstall, extras
  99-main       orchestration
config/         winutil selection config
test/           dry-run harness, undo round-trip, GUI and VM verification
tools/          Repair-Encoding.ps1 - the build's encoding guard
docs/           generated: full-size screenshots, coverage report
hosting/        Cloudflare Worker, the landing page in site/, publish script
build.ps1       concatenates src/ into trim.ps1
```

`irm | iex` can only fetch one file, so the modular source is compiled into a
single script. Same pattern winutil uses.

```powershell
.\build.ps1
```

The build parses its own output and fails if concatenation produced anything
that does not compile.

---

## Testing

Three tiers, cheapest first. All of them are safe to run on your own machine
except the last, which refuses to start outside a VM.

### 1. Dry-run harness — seconds, host-safe

```powershell
.\test\Invoke-DryRunHarness.ps1
```

Runs every phase's dry-run path unelevated, plus guards on the pieces most
likely to be broken by a careless edit:

- the undo generator produces parseable PowerShell, in reverse order, with
  quotes escaped
- no AppX removal-list entry collides with the protected list
- camera / microphone / screen capture are absent from the deny list and present
  in the never-touch list

### 2. Undo round-trip — seconds, host-safe

```powershell
.\test\Test-UndoRoundTrip.ps1
```

Applies real changes and really runs the undo script, confined to a throwaway
key (`HKCU:\Software\TrimRoundTripTest`) that is created and deleted by
the test. It never touches a real setting.

This is the one that proves the safety claim rather than asserting it. It covers
the cases a naive implementation gets wrong:

- every registry type, including `MultiString` and `QWord`
- values containing single quotes and semicolons
- a value that did **not** exist before — undo must *remove* it, not write zero
- a key that did not exist at all
- an explicit removal, which undo must put back
- no stray values left behind afterwards

### 3. Full verification — needs a disposable VM

```powershell
.\test\Invoke-SandboxTest.ps1              # Windows Sandbox, ~5 min
.\test\New-TestVm.ps1 -IsoPath <win11.iso> # Hyper-V, ~20 min to build
```

`Invoke-VmVerification.ps1` applies the optimizer for real, reads the run's own
ledger, and asserts that (a) every recorded change is actually present, (b) the
undo script returns every one to its prior value, and (c) a second consecutive
run is a complete no-op. It **refuses to run** unless it detects a VM or Sandbox
container.

Sandbox is the fast loop: disposable, boots in seconds, no ISO needed. It cannot
cover restore points (System Protection is off), reboots (single session), or the
full consumer AppX set — that is what the Hyper-V VM is for.

Both need Hyper-V and Windows Sandbox enabled:

```powershell
.\test\Enable-VirtualisationFeatures.ps1   # elevated, then reboot
```

### What no amount of VM testing will cover

**The NVIDIA phase.** There is no GPU passthrough in Sandbox and none in Hyper-V
without DDA on a server SKU, so the phase detects no NVIDIA card and skips. It
has to be validated on real hardware, against a machine whose profile you have
exported first.

---

## Publishing

One command, which builds, runs the whole suite, stages, verifies the staged
bytes against the fingerprint it is about to publish, and only then uploads:

```powershell
.\hosting\Publish-Trim.ps1 -DryRun   # everything except the upload
.\hosting\Publish-Trim.ps1           # for real
```

It refuses to publish a build that does not parse, does not pass the suite,
still contains a placeholder URL, or whose staged bytes do not match the hash
in its own sidecar.

Live at **https://trimbloat.com**, served by a Cloudflare Worker in
`hosting/worker.js`. The script is deliberately served as `text/plain` so that
anyone can read it in a browser before piping it into an elevated shell, and
the fingerprint is published at `/sha256`.

The landing page is a static page in `hosting/site/`, not markup inside the
Worker. The Worker substitutes one token, `{{SHA256}}`, from the sidecar of the
script that deployment is actually serving, so the hash shown on the page cannot
drift from the script sitting next to it. The publish script substitutes the
other, `{{V}}`, which versions every asset URL.

**That second one matters more than it looks.** Assets are served
`immutable` for a year, so if a redeploy did not change their URLs, a returning
visitor would get new HTML against a year-old cached stylesheet. The version is a
hash of the asset bytes themselves - not of the compiled script, which was the
first attempt and is wrong in a way that is easy to miss: editing only the CSS
leaves the script's fingerprint unchanged, so the URL would not move.

It is served under `default-src 'none'` with `script-src 'self'` and no inline
script, which is why the copy handler lives in `site/app.js`. JSON-LD is exempt
and has to be - a script block with a non-executable type is never run. The
publish script fails if an executable inline `<script>` or an inline event
handler reappears, if a referenced asset is missing or unrouted, or if a
placeholder is left unsubstituted.

### Screenshots

The site's screenshots are rendered from the real window, not mocked up:

```powershell
.	est\Export-GuiScreenshots.ps1     # docs\screenshots\*.png, 2320px
.\hosting\Build-SiteAssets.ps1       # -> hosting\site\img\*.webp, 1x and 2x
.\hosting\Build-OgImage.ps1          # -> og.png and the touch icon
```

`Export-GuiScreenshots.ps1` builds the genuine window from a real dry-run
manifest and renders each pane with `RenderTargetBitmap`, so a screenshot cannot
quietly stop matching the product. It defaults to a **representative demo
machine** rather than the one it is running on: the Overview pane prints the
motherboard, BIOS version, disk models and volume labels of whoever generated
it, and the phase panes list the full path of every installed game. Pass `-Real`
to render your own. `Build-SiteAssets.ps1` needs `cwebp` or `ffmpeg` on PATH and
does nothing without them - the encoded files are committed, so publishing never
depends on either being installed.

`$script:SelfUrl` is how the script re-fetches itself when elevating from a
piped invocation — there is no file on disk to re-invoke in that case. Get it
wrong and elevation from `irm | iex` fails.
