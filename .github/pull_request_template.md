## What this changes

<!-- and why -->

## Checks

- [ ] `.\test\Invoke-DryRunHarness.ps1` passes
- [ ] `.\test\Test-UndoRoundTrip.ps1` passes
- [ ] New registry writes carry a `-Because` and a tier
- [ ] Anything that exists on only one Windows version carries `-MinBuild` / `-MaxBuild`

<!--
If this adds a setting, say what it measurably does. A tweak that has not
actually been read by Windows since 7 is the most common thing this project
turns down.
-->
