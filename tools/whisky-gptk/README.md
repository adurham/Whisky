# whisky-gptk helpers

The engine-side pieces that make Windows Steam and its games behave on macOS.
They live outside Whisky.app itself: each is installed into the *engine* tree
(`~/Library/Application Support/com.franke.Whisky/Libraries/Wine/`), which an
engine update replaces wholesale — so they must be re-installed after one.

Tracked here because they were previously only deployed binaries with no
source in any repository. Losing them meant losing the fixes.

## The parts

| File | Installed as | Does |
|---|---|---|
| `wine-hudwrap.c` | `lib/wine/x86_64-unix/wine` | per-process routing: HUD env, Game Mode bundle, forks `mode-fixup` |
| `mode-fixup.c` | `bin/mode-fixup` | holds the game's display mode for its lifetime, restores on exit |
| `ds3-display-watch.c` | LaunchAgent | detects + self-heals the post-quit display fault |
| `ds3-hang-watch.sh` | LaunchAgent | captures evidence when a game wedges on quit |

`wine-hudwrap` is installed **as** the wine loader, with the real loader moved
aside to `wine-real`. Every launch therefore goes through it automatically —
there is no launch script, and the Whisky GUI is the only entry point.

## Building

```sh
clang -arch x86_64 -O2 -o wine-hudwrap wine-hudwrap.c
clang -arch x86_64 -O2 -o mode-fixup   mode-fixup.c \
      -framework CoreGraphics -framework CoreFoundation
clang        -O2 -o ds3-display-watch  ds3-display-watch.c \
      -framework ApplicationServices
```

x86_64 for the first two: they run inside the bottle under Rosetta and must
match the engine's architecture.

## The one rule

**`wine-hudwrap` and `mode-fixup` are a matched pair.** The wrapper spawns the
helper with a specific argv, and a wrapper built against a *different* helper
will hang every game launch — the helper exits 127 immediately and the game
sits at 0% CPU forever. This happened on 2026-09-21: a wrapper carrying a
`--preapply-all` pre-apply (which belongs to a generalized helper with a
per-exe resolution cache) was installed against the shipped helper, and Dark
Souls III stopped launching entirely.

Deploy both, or neither.

## Why `tasklist.exe` is on the exclusion list

Whisky.app polls the bottle with `start.exe /exec tasklist.exe /FO CSV` every
few seconds to refresh its running-programs list. The wrapper identifies a
process by the first `.exe` token in argv, which is `tasklist.exe` here, so
without that entry every poll looked like a game launch: it claimed the
one-helper lock, forked a helper, held the game resolution, and released it a
moment later. With the app open the display flapped between 2560x1440 and the
desktop mode continuously — 57 hold/release cycles observed.

This only appears when launching from the GUI. A launch script exits, leaving
no app to poll.

## Display restore is not symmetric

A scaled HiDPI desktop mode (point 3440x1440 backed by a 6880x2880 framebuffer)
is **absent from `CGDisplayCopyAllDisplayModes`**, and re-applying a captured
`CGDisplayModeRef` for it fails with `kCGErrorFailure`.
`CGRestorePermanentDisplayConfiguration()` does not restore it either.

The only thing that works is the private SkyLight
`CGSConfigureDisplayMode(config, display, modeNumber)` with the mode *number*
captured before anything is touched.

Measured on an AW3425DW: modes 149 and 150 are both the correct scaled desktop
(3440x1440, density 2.0, flags `0x00200001`); modes 99–103 are the 1x variants
and are the wrong target. The mode table's size changes between sessions
(219 vs 209 observed on the same day), so a number is not guaranteed to
describe the same mode later — prefer matching on the description.

`CGCompleteDisplayConfiguration` also **blinds the calling process**: afterwards
`CGDisplayCopyDisplayMode` serves that process its own owned state rather than
the live display, permanently. `mode-fixup` therefore never configures a
display in-process; it spawns itself as `--read` and `--apply` children.
