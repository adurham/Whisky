# FORK.md — what this fork adds to frankea/Whisky

This is `adurham/Whisky`, a downstream fork of `frankea/Whisky`. The rule for every
merge, the same as the other forks: **when upstream catches up, take upstream.** A fork
change is carried only while upstream does not do the job; when upstream ships its own
form of the same behaviour, upstream wins and the fork's version is dropped or
re-layered as a thin addition on top. This file is the canonical inventory of everything
below that is NOT upstream (as of `main` @ 56a10606, upstream @ 3abfbae9).

Sync procedure: see the `whisky-fork-upstream-sync` skill (hunk-level merges, the
`swift test --package-path WhiskyKit` + unsigned `xcodebuild` gates, and the
`swiftlint --strict` build phase that fails on lint warnings). Merges are hunk-level:
never `git checkout --theirs` a diverged file.

## Engine and tooling

- **`wine/` submodule** points at `adurham/winecx` (branch `fix/calayerhost-stale-context`),
  carrying the display-capture fix and the Wine-side pieces the display work needs.
  Edits under `Libraries/` are wiped by engine updates; never hand-edit them.
- **`tools/whisky-gptk/`** — the engine-side helpers, tracked in-repo because losing them
  lost the fixes. They install into the engine tree, which an engine update replaces
  wholesale, so they must be re-installed after one. `README.md` there has the build lines.
  - `wine-hudwrap.c` → installed AS the wine loader; per-process routing: HUD env, Game
    Mode bundle, forks `mode-fixup`. Matched pair with mode-fixup (specific argv).
  - `mode-fixup.c` → `bin/mode-fixup`: holds the game's display mode for its lifetime
    (true native 2560x1440@240 on the AW3425DW), restores the scaled desktop on exit,
    with a detached crash-guardian.
  - `ds3-display-watch.c` → LaunchAgent that detects and self-heals the post-quit
    display fault (the WindowServer capture-recovery stall).
  - `ds3-hang-watch.sh` → LaunchAgent that captures per-pid evidence when a game wedges
    on quit. Never force-quit a hung game before sampling it.
  - `faultprobe.c`, `linkrate.c` → diagnostics for the display fault and the dock link.

## Display and VRR

- Single-writer display mode: only the helper switches modes; probes and refresh
  helpers live beside it (8b49026d).
- Frame-rate cadence declaration (cda45f23, 0b7b0793): `BottleMetalConfig`
  `declareFrameRateRange` / `declaredFrameRate`; the engine declares the cadence so the
  panel can follow it (the VRR route). Verified live: the engine path holds ~58 Hz on a
  synthetic 60 fps source.
- Per-program refresh cap (868adb0a): `WHISKY_MAX_REFRESH_HZ` resolved per program and
  handed to mode-fixup; the variable must be ABSENT (not empty) when unset, which is
  what makes the wrapper fall back to `auto`.

## Health monitor

- `GameHealthMonitor` (+Shared, +Display) inside the app (9f85dba8): game sessions are
  monitored from the AppDelegate; external LaunchAgents were deliberately removed — the
  GUI is the only entry point. Never restores a display when the game list is empty
  (b10efcdf); density offset and lint fixed (936e1661). Logs via
  `log show --predicate 'subsystem == "com.whisky.GameHealthMonitor"'`.

## Overrides and per-program settings

- **User-managed DLL overrides** (58d1ed32 and its guards): `dllOverridesAreUserManaged`
  (`graphicsConfig.dllOverridesUserManaged`) — a launch then writes no `DllOverrides`
  key at all and leaves the prefix's `dxgi.dll` alone, for configurations the
  one-backend-per-bottle model cannot express. Re-layered onto upstream's evolved
  registry at the 2026-10-16 sync: the guards live in
  `WineDLLOverrideRegistry.applyDLLOverrides` (skip the sync) and before
  `reconcileDXGIForDXVK` in `Wine.enableDXVK` (leave dxgi), plus the `BottleSettings`
  accessor.
- **Registry readback** (`WineDLLOverrideRegistry+Readback.swift`): reads the prefix's
  `DllOverrides` back (`reg query /s`) so a launch writes only what differs.
- **Per-program Metal HUD** (84f4731d): `ProgramOverrides.metalHud` — measure one title
  without the HUD sitting over the launcher's own windows. Unset inherits the bottle;
  the variable is removed rather than set to "0" (the HUD reads presence).
- **Per-program refresh cap** (868adb0a) and the programUser layer wiring in
  `WineEnvironment.swift`.
- `ProgramOverrides` also carries the fork's decode leniency and isEmpty wiring for the
  above.

## Tests added by the fork

`DLLOverrideSyncSafetyTests`, `RefreshCapWiringProbe`, the fork's
`DLLOverrideRegistryTests` extensions, the HUD + cap blocks in
`EnvironmentVariablesTests`, and the `ProgramOverridesTests` additions.

## Superseded by upstream (kept for history; do not re-derive)

- **Launcher-scoped DXVK** (e3f2c244): upstream absorbed this as #276/#302 ("scope the
  launcher dxvk preset to steam's own processes"); the fork's branch is superseded, and
  upstream's code carries the fork's own commentary.
- **Non-destructive override sync** (58d1ed32): upstream's authorship model ("removes
  only names DLLOverrideAuthorship says it wrote") is the canonical form of the same fix.
- **DXGI residue handling**: upstream's `reconcileDXGIForDXVK` + builtin-restore (#251)
  supersedes the fork's payload-gated removal, and `requiresDXVK` is Rockstar-only
  upstream (Steam's DXVK is deployed through the launch path's descendants clause).

## Log

- 2026-10-16 — synced to upstream/main (38 commits ⇒ 5ffb2f7b); merged
  `feat/per-program-metal-hud` (a382f9c3); culled its stale performance-preset line
  (that feature was removed upstream) ⇒ 56a10606. Kit: 1424 tests / 0 failures; app
  build green including the `swiftlint --strict` phase.
- 2026-09-10 … 2026-09-23 — the display/VRR/health/overrides/tooling work listed above.
