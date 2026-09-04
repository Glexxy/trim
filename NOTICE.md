# Third-party software and attribution

Trim itself is MIT licensed - see [LICENSE](LICENSE). The same licence its
largest dependency uses, so nothing downstream has to reason about two.

This tool orchestrates other people's work. It does not replace it, and it does not
try to hide it. This file exists so that anyone who finds this project can find the
projects it depends on and go use them directly.

---

## WinUtil — Chris Titus Tech

**The single largest dependency.** The debloat, telemetry and tweak engine is
WinUtil. This tool does not reimplement it: it invokes the official hosted script
at `https://christitus.com/win` with a generated selection config, and WinUtil does
the work.

- Project: <https://github.com/ChrisTitusTech/winutil>
- Author: Chris Titus (@christitustech), CT Tech Group LLC
- Site: <https://christitus.com/win>
- Runspace author: @DeveloperDurp

**If you want a Windows utility, go use WinUtil.** It is more capable than this,
it is better maintained than this, and it has an enormous amount of careful work in
it. This project exists to wrap it in a specific, opinionated, reversible workflow —
not to compete with it.

What this project takes from WinUtil:

- The hosted script itself, invoked with `-Config`.
- WinUtil's selection key names (`WPFTweaksTelemetry`, `WPFFeaturesdotnet`, and so
  on), which are reproduced in `config/winutil-tweaks.json`.
- The build pattern of compiling a modular source tree into one distributable
  `.ps1`, which is how WinUtil ships and is the right answer for `irm | iex`.

Licensed MIT:

```
MIT License

Copyright (c) 2022 CT Tech Group LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## CTT PowerShell Profile — Chris Titus Tech

Installed by the `Fixes` phase when running on PowerShell 7 or later.

- Project: <https://github.com/ChrisTitusTech/powershell-profile>
- Author: Chris Titus (@christitustech)
- Licence: MIT

---

## NVIDIA Profile Inspector — Orbmu2k

There is no supported command line for the NVIDIA Control Panel. Profile Inspector
is the only reliable way to read and write the driver's binary profile store, and
the `Nvidia` phase downloads it to apply a `.nip` with `-silentImport`.

- Project: <https://github.com/Orbmu2k/nvidiaProfileInspector>
- Author: Orbmu2k
- Licence: MIT

The `.nip` this project imports is original to it and is composed at runtime in
`src/11-gpu.ps1`, per detected card, rather than shipped as a file. It was derived
by curating a reference profile — machine-specific settings stripped, the frame
limiter made dynamic, and one setting deliberately changed. Each of those decisions
is documented at the setting it applies to.

---

## Prior art this project learned from but does not include

No code from any of these is used. They are listed because they informed which
tweaks were worth including, and — more usefully — which were not.

| Project | What it taught |
|---|---|
| [Win11Debloat](https://github.com/Raphire/Win11Debloat) (Raphire) | The scheduled-task groups worth disabling, and an honest example of documenting a footgun: it says plainly that its notification toggle also silences Discord and WhatsApp. This project declines that tweak for exactly that reason. |
| [privacy.sexy](https://github.com/undergroundwires/privacy.sexy) | The standard / strict / all tiering model, which is the ancestor of this project's Safe / Caution / Risky tiers. |
| [Sophia Script](https://github.com/farag2/Sophia-Script-for-Windows) (farag2) | Granularity as a safety feature — requiring deliberate selection rather than applying a blanket default. |
| [O&O ShutUp10++](https://www.oo-software.com/en/shutup10) | The convention of labelling each setting by risk rather than presenting a flat list. |

---

## What this project is

The parts that are original here are the safety machinery, not the tweaks:

- Every registry write is recorded before it is made, and the run emits a script
  that reverses all of them exactly — including removing values that did not
  previously exist, rather than writing zero over them.
- A dry run produces a complete machine-readable manifest and needs no
  administrator rights, so the plan can be inspected before anything is granted.
- Hardware detection gates every phase, so nothing is written to a machine it does
  not apply to.
- Protected lists for AppX packages and privacy capabilities are enforced at
  runtime and asserted by the test suite, so a careless edit cannot remove winget
  or turn off someone's camera.
