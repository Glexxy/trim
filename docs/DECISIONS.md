# Design decisions and their trade-offs

Notes for anyone reading or changing the source. Every entry here is a judgement
call rather than a fact, written down so you can change it deliberately instead
of discovering it by surprise.

If you disagree with one of these, you are probably not wrong — these are the
places where reasonable people land differently.

---

## Game Mode is turned off

Genuinely contested. On 22H2 and later, Game Mode mostly suppresses background
scheduling and blocks Windows Update from restarting mid-session, and on most
machines it is neutral to helpful.

It is off because that is the behaviour this project was asked for, not because
the evidence is one-sided.

**To change it:** flip `$script:DisableGameMode` in [`../src/06-gaming.ps1`](../src/06-gaming.ps1).

## Threaded Optimization is Auto, not Off

The reference NVIDIA profile this was derived from had it Off. Off disables
driver-side multithreading and costs real frames in most modern engines — it is
a per-game workaround that got applied globally somewhere along the way.

Shipping Off to strangers would measurably hurt them, so the default is Auto.

**To change it:** setting `549528094` in [`../src/11-gpu.ps1`](../src/11-gpu.ps1).

## Start's "most used apps" fights the privacy phase

Showing most-used apps requires app launch tracking (`Start_TrackProgs=1`),
which is telemetry-adjacent and something the privacy phase would otherwise turn
off. The explicit personalisation instruction wins, but it is a real conflict
rather than an oversight.

**To change it:** set `Start_TrackProgs` to `0` in
[`../src/08-personalisation.ps1`](../src/08-personalisation.ps1).

## SystemResponsiveness is 10, not 0

Most guides say 0. The Windows default is 20, which reserves 20% of CPU for
background tasks. 10 is the trade; 0 starves audio and can produce crackle under
load, which is a worse experience than the frames it buys.

## Most "network optimisation" is placebo

The network phase does four things with a measurable effect and deliberately
nothing else. If it looks thin next to the registry-key lists people paste
around, that is the point — most of those keys have not done anything since
Windows 7, and several were never read by any version of Windows.

## Removing Edge is available, but off by default

It used to be refused outright, on the grounds that removal takes WebView2 with
it and breaks Widgets, parts of Teams and Office, and any desktop app that
renders with it.

That objection turns out to be avoidable. Edge and the WebView2 runtime are
separate products sharing one installer, and `setup.exe --uninstall --msedge`
removes the browser while leaving the runtime in place.

What stays true: on most builds Windows Update reinstates Edge later, and
outside the EEA Windows refuses the uninstall outright. Both are reported rather
than worked around. It is Risky tier and never selected by default.

## Memory Integrity ships on

Turning HVCI off measurably helps some CPU-bound games and measurably weakens
the machine. It is available under the Risky tier, off by default, with the cost
stated at the point of decision rather than buried.

---

## Things that are deliberately not implemented

**AutoLogon.** WinUtil offers it. It writes the account password to
`HKLM\...\Winlogon\DefaultPassword` in a form anything running on the box can
read back, and leaves the machine booting straight to an unlocked desktop.

**Fan curves, BIOS, undervolting, overclocking.** Out of scope. Nothing here
should be able to damage hardware or leave a machine unbootable.

**Touching camera, microphone, screenshots or screen recording.** These four
capabilities are on a never-touch list that is enforced at runtime and asserted
by the test suite, so a careless edit to the privacy deny-list cannot switch off
someone's webcam.

**Removing load-bearing AppX packages.** `Microsoft.VCLibs`, `UI.Xaml`,
`NET.Native` and `WindowsAppRuntime` are frameworks other applications link
against. `DesktopAppInstaller` *is* winget. `XboxIdentityProvider` is how a large
number of PC games sign in — removing it produces launch failures that look
nothing like an AppX problem. All protected, prefix-matched, and unit-tested
against the removal list so the two can never overlap.

---

## WinUtil cannot run under our strict mode

This script sets `Set-StrictMode -Version 2.0`, and anything it invokes
inherits it. WinUtil reads `$sync.runspace` on a hashtable that does not always
carry the key — `$null` under normal rules, a terminating error under strict
mode. The phase died on its first statement every time it ran:

```
WinUtil failed: The property 'runspace' cannot be found on this object.
```

It read like WinUtil breaking. It was us. The handoff turns strict mode off and
turns it back on afterwards, so the rest of the run keeps the protection. A
harness guard asserts both halves, and checks on the host that strict mode
still throws there at all — if it ever stops, the guard says so rather than
passing quietly.

Anything else invoked from a third party needs the same treatment.

## Two WinUtil behaviours worth knowing

Verified against WinUtil v26.08.19 by reading the source rather than the docs.

1. **`Invoke-WinUtilAutoRun` never processes toggles.** It runs Tweaks,
   Features, Apps and AppX. Any `WPFToggle*` key in a `-Config` file is imported
   and then silently ignored. That is why the entire "Customize Preferences"
   column is implemented here as direct registry writes instead.
2. **The Fixes panel entries are Buttons, not checkboxes.** `WPFPanelAutologin`,
   `WPFPanelDISM` and `WPFWinUtilInstallPSProfile` are not valid config keys —
   `Update-WinUtilSelections` throws `Unsupported selection key` on them.

`-Config` accepts an https URL as well as a local path, which is what makes the
handoff possible from a script that was itself piped in.
