/*
 * mode-fixup -- make a game's fullscreen resolution switch land correctly.
 *
 * FOUR PROBLEMS, ONE HELPER
 *
 * 1. THE STRETCHED / CUT-OFF WINDOW
 *    A game going fullscreen calls ChangeDisplaySettings; winemac.drv honours
 *    it and the display really switches. But the game's window is sized against
 *    wine's *cached* display info, refreshed asynchronously from macOS's
 *    reconfiguration callback (winemac.so: cgDisplay:wasReconfiguredWithFlags:).
 *    If the window is sized before that callback lands, it keeps the OLD
 *    desktop's width while the game renders at the NEW mode's width -- a
 *    stretched, cut-off image that nothing later corrects.
 *
 *    Re-applying a display mode fires that callback again, so wine refreshes
 *    its display info and re-lays out its fullscreen window against the mode
 *    actually in effect. One redundant mode application is the entire fix.
 *
 * 2. THE REFRESH RATE
 *    A game requests a resolution only; the driver then picks the HIGHEST
 *    refresh at it. Where the link cannot carry that (2560x1440@240 in 10-bit
 *    RGB), the display renegotiates to 8-bit YCbCr 4:2:2 and the picture is cut
 *    off for an unrelated reason. Capping at an integer multiple of the frame
 *    rate (120Hz for 60fps) keeps full colour depth and clean pacing. wine
 *    RE-ASSERTS its mode seconds later, so the cap must be maintained, not
 *    applied once.
 *
 * 3. THE 21:9 STRETCH (added 2026-09-20)
 *    On an ultrawide (AW3425DW: 3440x1440) running a 16:9 game at 2560x1440,
 *    wine's window/layer ends up 3440x1440 while the game's Metal drawable is a
 *    correct 2560x1440 -- non-uniform compositor gravity then stretches the 16:9
 *    frame across the 21:9 surface. Root cause is
 *    win32u/sysparams.c:3102-3131 map_window_rects_virt_to_raw(): "if the
 *    visible rect is fullscreen, make it cover the full raw monitor, regardless
 *    of aspect ratio" -- and the RAWs here are the desktop's, because the game's
 *    mode request never actually lands (see 4).
 *
 *    The lever that sidesteps all of that: put the ACTUAL macOS display into a
 *    true 1:1 mode at the game's own resolution for the duration of the game.
 *    Then the raw-monitor union is a no-op (full raw monitor == the game's own
 *    resolution), the layer and the drawable match exactly, and the monitor's
 *    own scaler pillarboxes the 16:9 signal inside the 21:9 panel -- hardware
 *    behaviour, not something wine has to get right.
 *
 * 4. THE SWITCH THAT NEVER LANDS, AND WHY THE RESTORE IS NOT SYMMETRIC
 *    wine's ChangeDisplaySettings for 2560x1440 is PARKED, not rejected:
 *    cocoa_app.m setMode:forDisplay: takes the `else` branch whenever
 *    [NSApp isActive] is false and stores the mode in latentDisplayModes
 *    instead of applying it (line ~1026). The display therefore stays on the
 *    desktop mode, the game renders 2560x1440 into a 3440x1440 layer, and the
 *    stretch above follows. This helper applies the mode itself.
 *
 *    The restore cannot use the same public API the switch uses. The desktop
 *    here is a SCALED mode -- 6880x2880 pixel presenting as 3440x1440 @240 --
 *    and that mode object is NOT in CGDisplayCopyAllDisplayModes; re-applying a
 *    pre-captured copy of it fails with kCGErrorFailure (1000). Measured both
 *    ways. The mode IS in the private SkyLight list as a mode NUMBER, and
 *    CGSConfigureDisplayMode(config, display, modeNumber) sets it. So: switch
 *    away with public CG (session scope), switch back with the mode NUMBER
 *    captured before we ever touched anything. Verified round trip, including
 *    the scaled desktop returning byte-for-byte.
 *
 * WHY THIS IS THREE PROCESSES AND NOT ONE
 * A process that has called CGCompleteDisplayConfiguration becomes a
 * configuration owner, and from then on CGDisplayCopyDisplayMode serves it that
 * owned state instead of the live display. It stops seeing mode changes made by
 * other processes -- permanently.
 *
 * Measured directly: after this helper capped 240->120, an independent reader
 * reported the display back at 240Hz while the capping process still reported
 * 120Hz on 17 consecutive polls over 8.5s. A process that never configures
 * tracks every external change perfectly (verified across a
 * 3440@120 -> 2560@240 -> 2560@120 sequence). Neither kCGConfigureForSession
 * nor kCGConfigureForAppOnly avoids it, and draining the CFRunLoop for
 * reconfiguration notifications does not either: the state is server-side.
 *
 * So the supervisor NEVER configures a display. It spawns a short-lived child
 * for each read and each apply; every child starts with a clean view. Children
 * use kCGConfigureForSession because kCGConfigureForAppOnly reverts when the
 * configuring process exits -- which for a spawn-and-exit applier would undo
 * the change immediately. Session means WE own restoration, so the supervisor
 * records the desktop mode at startup and restores it when the game exits.
 *
 * SAFETY
 *   - Never kCGConfigurePermanently: the saved desktop mode is never rewritten.
 *   - Acts only when the live resolution differs from the desktop resolution
 *     captured at startup, i.e. only on a game-set mode.
 *   - The resolution switch (3) is OPT-IN and per-game: it needs a target
 *     resolution from WHISKY_GAME_RESOLUTION or from the game's own
 *     GraphicsConfig.xml. With neither, this helper behaves exactly as before.
 *   - Exits when the watched pid exits, and restores the desktop on every exit
 *     path including signals.
 *   - Rate-limited: stops re-capping after kMaxCaps corrections at one
 *     resolution, so a driver that fights back cannot cause an endless
 *     mode-change ping-pong.
 *   - Never touches window geometry; it re-applies display modes and lets wine
 *     run its own re-layout, the same path wine uses for any display change.
 *   - CRASH-SAFETY: a detached guardian process is spawned for the lifetime of
 *     any resolution switch. It holds the desktop's mode number and restores it
 *     if the supervisor dies without restoring -- including SIGKILL, which no
 *     signal handler can catch. The user cannot be left on the game's mode.
 *
 * PIXEL SIZE ALONE DOES NOT IDENTIFY A MODE (found 2026-09-16, the hard way)
 *    A Retina/HiDPI main display offers multiple distinct modes that report
 *    the IDENTICAL pixel width, pixel height, AND refresh rate -- e.g. this
 *    MacBook's panel has both a 3024x1964-pixel / 1512x982-point (2x scaled,
 *    normal Retina desktop) mode AND a 3024x1964-pixel / 3024x1964-point (1x,
 *    unscaled) mode, both "3024x1964 @ 120Hz" by pixel dims. They render
 *    completely differently -- the 1x mode is what "DPI scaling is all
 *    fucked" looks like. Matching on pixel width/height/refresh alone is
 *    ambiguous on any such display and can silently apply the WRONG one.
 *
 *    This bit twice in one evening: first a live diagnostic script restored
 *    "3024x1964 @ 120" after a capture/kill test and landed on the unscaled
 *    1x variant instead of the desktop's actual 2x Retina mode; the following
 *    manual fix had to explicitly match point size to land on the right one.
 *    That same ambiguity was latent in THIS file's own matching logic
 *    (child_apply / best_hz_under_cap), it just never manifested here because
 *    it had only ever been exercised against the AW3425DW, a non-HiDPI
 *    external monitor where pixel size and point size are identical and the
 *    ambiguity cannot arise. The MacBook's own built-in panel is HiDPI by
 *    definition, so the very first time this binary runs its own
 *    self-restore against the built-in panel, it was one CGDisplayCopyAllDisplayModes
 *    enumeration-order accident away from doing the same thing to the user's
 *    live desktop.
 *
 *    Fix: every mode this file reads, remembers, or matches against is now a
 *    5-tuple (pixel W, pixel H, point W, point H, refresh) sourced from
 *    CGDisplayCopyAllDisplayModes with kCGDisplayShowDuplicateLowResolutionModes
 *    set, so the full set of same-pixel-size variants is visible and matched
 *    unambiguously by ALL FIVE fields together, not pixel dims and refresh
 *    alone. A mode that doesn't match on every field is not applied -- there
 *    is no "close enough" fallback, because a close-enough pixel match is
 *    exactly the bug.
 *
 *    The scaled desktop mode is the extreme case of the same problem: it is not
 *    in the list AT ALL, which is why the restore path carries its CGS mode
 *    NUMBER rather than a tuple.
 *
 * Build: clang -O2 -o mode-fixup mode-fixup.c \
 *            -framework CoreGraphics -framework CoreFoundation
 *        (arm64, like every other deployed copy of this binary: it is a native
 *         helper talking to CoreGraphics, running alongside the translated game
 *         rather than inside it. An x86_64 build would be dead weight.)
 * Usage: mode-fixup <max-hz> [watch-pid] [lock-file] [game-pid] [game-exe]
 *        mode-fixup --read                         (child: prints "pxW pxH ptW ptH HZ")
 *        mode-fixup --apply <pxW> <pxH> <ptW> <ptH> <hz>   (child: applies, exits 0/1)
 *        mode-fixup --readcgs                      (child: prints the CGS mode number)
 *        mode-fixup --cgsapply <modeNumber>        (child: applies by mode number)
 *        mode-fixup --guard <sup-pid> <cgs-num> <pxW> <pxH>  (detached crash guardian)
 */
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>   /* strcasecmp */
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <dlfcn.h>
#include <dirent.h>
#include <ctype.h>

extern char **environ;

static volatile sig_atomic_t running = 1;
static void stop(int s) { (void)s; running = 0; }

/* Damping, NOT a give-up limit. wine re-applies its fullscreen mode on every
 * window activation, so a long session legitimately needs many corrections; an
 * earlier build capped at 12 and then left the display uncapped for the rest of
 * the session. The counter resets after kStableTicks quiet ticks, so only a
 * genuine rapid fight (many corrections with no stable period) is damped. */
static const int kMaxRapidCaps = 8;
static const int kStableTicks = 10;   /* ~5s at the poll interval */

/* ---------- mode identity: pixel size ALONE is not unique, see header ---------- */

/* Every mode enumeration in this file requests the full set including
 * same-pixel-size HiDPI/1x duplicates. Omitting this option can hide the
 * exact variant we need to match against, silently narrowing the candidate
 * set rather than erroring -- worse than including "too many" modes, since
 * every match below is still exact on all five fields regardless of how many
 * candidates are in play. */
static CFArrayRef copy_all_modes(CGDirectDisplayID d) {
    CFDictionaryRef opts = CFDictionaryCreate(NULL,
        (const void **)&kCGDisplayShowDuplicateLowResolutionModes, (const void **)&kCFBooleanTrue,
        1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, opts);
    if (opts) CFRelease(opts);
    return modes;
}

/* ---------- private SkyLight: the ONLY way back to a scaled desktop mode ----------
 *
 * CGSConfigureDisplayMode(CGDisplayConfigRef config, CGDirectDisplayID display,
 * int modeNum) -- note the first argument is a CONFIG REF, not a display id.
 * Passing a display id there is an immediate segfault (learned in the rig).
 *
 * Signatures from displayplacer's Header.h, which is the working prior art for
 * this exact call on modern macOS. The mode description is a fixed 0xDC-byte
 * struct; the field offsets used here (mode, flags, width, height, depth) are
 * shared by every published layout and are all this file needs. */
typedef union {
    uint8_t raw[0xDC];
    struct {
        uint32_t mode; uint32_t flags; uint32_t width; uint32_t height; uint32_t depth;
        uint32_t dc2[42]; uint16_t dc3; uint16_t freq; uint32_t dc4[4]; float density;
    } d;
} modes_D4;

static void *g_sl;
static void  (*pCGSGetCurrentDisplayMode)(CGDirectDisplayID, int *);
static void  (*pCGSGetNumberOfDisplayModes)(CGDirectDisplayID, int *);
static void  (*pCGSGetDisplayModeDescriptionOfLength)(CGDirectDisplayID, int, modes_D4 *, int);
static void  (*pCGSConfigureDisplayMode)(CGDisplayConfigRef, CGDirectDisplayID, int);
/* Variable-refresh query. THE SIGNATURE MATTERS: it is
 *     int SLSIsDisplayModeVRR(CGDirectDisplayID display, int IODisplayModeID)
 * and NOT SLSIsDisplayModeVRR(CGDisplayModeRef).  Declaring it against a
 * CGDisplayModeRef makes every call return 0, which reads as "this display
 * has no VRR at all" -- a false conclusion that cost hours once already. */
static int   (*pSLSIsDisplayModeVRR)(CGDirectDisplayID, int);

static int load_cgs(void);   /* defined below; used by the VRR lookup */

/* Find the VRR-capable SkyLight mode matching a 5-tuple description.
 *
 * Several modes can describe identically to public CoreGraphics while only one
 * of them offers variable refresh, so the 5-tuple alone cannot pick correctly.
 * Returns the mode NUMBER, or -1 when SkyLight is unavailable or nothing
 * matches. Read-only: enumerating modes is not configuring one. */
static int sky_vrr_mode_number(CGDirectDisplayID d, size_t pw, size_t ph,
                               size_t ptw, size_t pth, double hz) {
    if (!load_cgs()) return -1;
    if (!pSLSIsDisplayModeVRR) {
        pSLSIsDisplayModeVRR = dlsym(g_sl, "SLSIsDisplayModeVRR");
        if (!pSLSIsDisplayModeVRR) return -1;
    }
    int total = 0;
    pCGSGetNumberOfDisplayModes(d, &total);
    for (int i = 0; i < total; i++) {
        modes_D4 m; memset(&m, 0, sizeof m);
        pCGSGetDisplayModeDescriptionOfLength(d, i, &m, sizeof m);
        if (m.d.width != pw || m.d.height != ph) continue;
        if (m.d.width != ptw || m.d.height != pth) continue;   /* 1:1 only */
        if (hz > 0 && (double)m.d.freq != hz) continue;
        if (pSLSIsDisplayModeVRR(d, i)) return i;
    }
    return -1;
}

static int load_cgs(void) {
    if (g_sl) return 1;
    g_sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!g_sl) return 0;
    pCGSGetCurrentDisplayMode = dlsym(g_sl, "CGSGetCurrentDisplayMode");
    pCGSGetNumberOfDisplayModes = dlsym(g_sl, "CGSGetNumberOfDisplayModes");
    pCGSGetDisplayModeDescriptionOfLength = dlsym(g_sl, "CGSGetDisplayModeDescriptionOfLength");
    pCGSConfigureDisplayMode = dlsym(g_sl, "CGSConfigureDisplayMode");
    if (!pCGSGetCurrentDisplayMode || !pCGSGetNumberOfDisplayModes ||
        !pCGSGetDisplayModeDescriptionOfLength || !pCGSConfigureDisplayMode) {
        /* Partial load is worse than none: a later call would jump through a
         * null pointer. Drop the handle and let callers fall back. */
        dlclose(g_sl); g_sl = NULL;
        return 0;
    }
    return 1;
}

/* ---------- child roles (each runs in a fresh process) ---------- */

static int child_read(void) {
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(CGMainDisplayID());
    if (!m) return 1;
    printf("%zu %zu %zu %zu %.0f\n",
           CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
           (size_t)CGDisplayModeGetWidth(m), (size_t)CGDisplayModeGetHeight(m),
           CGDisplayModeGetRefreshRate(m));
    CGDisplayModeRelease(m);
    return 0;
}

/* Print the SkyLight mode NUMBER of the live mode. This is the restore handle
 * for a scaled desktop mode, which has no enumerable CGDisplayModeRef. */
static int child_readcgs(void) {
    if (!load_cgs()) { printf("-1\n"); return 1; }
    int n = -1;
    pCGSGetCurrentDisplayMode(CGMainDisplayID(), &n);
    printf("%d\n", n);
    return n >= 0 ? 0 : 1;
}

/* Apply a mode by SkyLight mode number. This is the restore path; see header. */
static int child_cgsapply(int modeNum) {
    if (!load_cgs()) {
        fprintf(stderr, "[mode-fixup] --cgsapply: SkyLight unavailable\n");
        return 1;
    }
    CGDisplayConfigRef cfg;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return 1;
    pCGSConfigureDisplayMode(cfg, CGMainDisplayID(), modeNum);
    CGError rc = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    return rc == kCGErrorSuccess ? 0 : 1;
}

/* pw/ph = pixel size, ptw/pth = point (logical/GUI) size. ALL FOUR plus
 * refresh must match exactly -- see the header comment on why pixel size
 * alone is ambiguous on any HiDPI display, which includes every MacBook's
 * own built-in panel. */
static int child_apply(size_t pw, size_t ph, size_t ptw, size_t pth, double hz) {
    CGDirectDisplayID d = CGMainDisplayID();

    /* Prefer a VARIABLE-REFRESH mode when several modes describe identically.
     *
     * Public CoreGraphics cannot tell these apart: on an AW3425DW the four
     * 2560x1440 entries are indistinguishable to CGDisplayCopyAllDisplayModes,
     * yet only ONE of them carries the VRR flag (mode 95 - the others, 96/97/98,
     * are fixed-refresh).  Picking the wrong one costs variable refresh, and
     * without it any frame that runs slightly over budget waits a whole vsync
     * interval instead of being shown when it is ready -- which reads as
     * stuttering plus occasional ~2x frame times.
     *
     * So when SkyLight is available, find the VRR-flagged mode that matches and
     * apply it BY NUMBER.  Fall back to the old first-match behaviour when the
     * private framework cannot be reached, exactly as before. */
    double want_hz = hz;
    int vrr_num = sky_vrr_mode_number(d, pw, ph, ptw, pth, want_hz);
    if (vrr_num >= 0) {
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            /* first arg is the CONFIG REF, never a display id (segfault) */
            pCGSConfigureDisplayMode(cfg, d, vrr_num);
            if (CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession)
                    == kCGErrorSuccess) {
                fprintf(stderr, "[mode-fixup] applied VRR mode %d for %zux%zu\n",
                        vrr_num, ptw, pth);
                return 0;
            }
        }
        /* fall through to the public path if the SkyLight route failed */
    }

    CFArrayRef modes = copy_all_modes(d);
    if (!modes) return 1;
    int rc = 1;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetPixelWidth(m) != pw) continue;
        if (CGDisplayModeGetPixelHeight(m) != ph) continue;
        if ((size_t)CGDisplayModeGetWidth(m) != ptw) continue;
        if ((size_t)CGDisplayModeGetHeight(m) != pth) continue;
        if (CGDisplayModeGetRefreshRate(m) != hz) continue;
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGConfigureDisplayWithDisplayMode(cfg, d, m, NULL);
            /* Session, not AppOnly: AppOnly reverts when this short-lived
             * process exits, undoing the change we just made. */
            rc = (CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession)
                  == kCGErrorSuccess) ? 0 : 1;
        }
        break;
    }
    CFRelease(modes);
    return rc;
}

/* Highest refresh <= cap at EXACTLY (pw,ph,ptw,pth) -- same pixel AND point
 * size as the mode being capped, varying only refresh. This deliberately
 * does not "pick any mode with the right pixel size": that is what silently
 * swaps a game (or the desktop) from its actual scale factor to a different
 * one while changing nothing the caller asked to change. 0 if none. Safe to
 * call from the supervisor: enumerating modes is not configuring one. */
static double best_hz_under_cap(size_t pw, size_t ph, size_t ptw, size_t pth, double cap) {
    CFArrayRef modes = copy_all_modes(CGMainDisplayID());
    if (!modes) return 0;
    double best = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetPixelWidth(m) != pw) continue;
        if (CGDisplayModeGetPixelHeight(m) != ph) continue;
        if ((size_t)CGDisplayModeGetWidth(m) != ptw) continue;
        if ((size_t)CGDisplayModeGetHeight(m) != pth) continue;
        double hz = CGDisplayModeGetRefreshRate(m);
        if (hz > 0 && hz <= cap && hz > best) best = hz;
    }
    CFRelease(modes);
    return best;
}

/* ---------- supervisor ---------- */

/* argv[0] as handed to us is NOT a usable path: wine-hudwrap execl()s this
 * binary with a bare "mode-fixup" argv[0] (readable in `ps`, nothing more),
 * and posix_spawn() -- unlike posix_spawnp() -- never searches $PATH. Every
 * self-respawn in spawn_wait() then fails immediately. This was invisible in
 * manual testing because running the binary from a shell by relative or
 * absolute path makes argv[0] equal to a real, resolvable path for free;
 * only a real exec from the wrapper (a different argv[0]) exposed it.
 * Resolve our own absolute path instead of trusting argv[0], same pattern
 * wine-hudwrap.c already uses for its sibling paths. */
static char g_self_buf[PATH_MAX];
static const char *g_self;

static void resolve_self(void) {
    char raw[PATH_MAX]; uint32_t sz = sizeof raw;
    if (_NSGetExecutablePath(raw, &sz) == 0 && realpath(raw, g_self_buf)) {
        g_self = g_self_buf;
    } else {
        g_self = "/Users/adam.durham/Library/Application Support/"
                  "com.franke.Whisky/Libraries/Wine/bin/mode-fixup";
        fprintf(stderr,
                "[mode-fixup] could not resolve own path, falling back to %s\n",
                g_self);
    }
}

static int spawn_wait(char *const argv[], char *out, size_t outlen) {
    int fds[2];
    if (out && pipe(fds) != 0) return -1;

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (out) {
        posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
        posix_spawn_file_actions_addclose(&fa, fds[0]);
    }

    pid_t pid;
    int rc = posix_spawn(&pid, g_self, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (rc != 0) { if (out) { close(fds[0]); close(fds[1]); } return -1; }

    if (out) {
        close(fds[1]);
        ssize_t n = read(fds[0], out, outlen - 1);
        out[n > 0 ? n : 0] = '\0';
        close(fds[0]);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* Live display mode, read by a fresh child so it is never a stale owned view.
 * Returns pixel size, point size, and refresh -- all five fields are the
 * mode's actual identity; see the header comment. */
static int read_mode(size_t *pw, size_t *ph, size_t *ptw, size_t *pth, double *hz) {
    char buf[96] = {0};
    char *argv[] = { (char *)g_self, (char *)"--read", NULL };
    if (spawn_wait(argv, buf, sizeof buf) != 0) return 0;
    unsigned long a = 0, b = 0, c = 0, e = 0; double zz = 0;
    if (sscanf(buf, "%lu %lu %lu %lu %lf", &a, &b, &c, &e, &zz) != 5) return 0;
    *pw = a; *ph = b; *ptw = c; *pth = e; *hz = zz;
    return 1;
}

static int apply_mode(size_t pw, size_t ph, size_t ptw, size_t pth, double hz) {
    char s1[16], s2[16], s3[16], s4[16], s5[16];
    snprintf(s1, sizeof s1, "%zu", pw);
    snprintf(s2, sizeof s2, "%zu", ph);
    snprintf(s3, sizeof s3, "%zu", ptw);
    snprintf(s4, sizeof s4, "%zu", pth);
    snprintf(s5, sizeof s5, "%.0f", hz);
    char *argv[] = { (char *)g_self, (char *)"--apply", s1, s2, s3, s4, s5, NULL };
    return spawn_wait(argv, NULL, 0) == 0;
}

/* Live mode number, from a fresh child. -1 when SkyLight is unavailable. */
static int read_cgs_mode(void) {
    char buf[32] = {0};
    char *argv[] = { (char *)g_self, (char *)"--readcgs", NULL };
    if (spawn_wait(argv, buf, sizeof buf) != 0) return -1;
    int n = -1;
    if (sscanf(buf, "%d", &n) != 1) return -1;
    return n;
}

/* Restore a mode by SkyLight mode number, from a fresh child. */
static int apply_cgs_mode(int modeNum) {
    if (modeNum < 0) return 0;
    char s[16];
    snprintf(s, sizeof s, "%d", modeNum);
    char *argv[] = { (char *)g_self, (char *)"--cgsapply", s, NULL };
    return spawn_wait(argv, NULL, 0) == 0;
}

/* ---------- target resolution (the 21:9 fix) ----------
 *
 * Resolution order:
 *   1. WHISKY_GAME_RESOLUTION -- explicit, wins. "WxH" or "WxH@Hz".
 *      Empty or "off" disables the feature for this session.
 *   2. The game's own GraphicsConfig.xml, for the one game known to write its
 *      fullscreen resolution to a file we can read before it starts. Anything
 *      else is untouched: with no env var and no recognised game, this helper
 *      never switches resolution at all.
 * The point of doing it here rather than at launch is that the value the game
 * will ask for is exactly the value it wrote last time it ran, and this helper
 * already starts before the game's window exists.
 *
 * The EXE NAME we were seeded with is a hint, not a contract. Whichever wine
 * process happens to win the one-helper-per-bottle race decides it -- Steam
 * launches helper exes that look like games, and the helper then carries that
 * name for the rest of the session. So a game whose exe name we can resolve a
 * config for is ADOPTED when it shows up, even if we started under another
 * name (see adopt_configured_game below). Without that, the fix silently
 * applies only when DS3 happens to be the first .exe wine runs. */
static int parse_env_res(size_t *w, size_t *h, double *hz, int *have_hz) {
    const char *e = getenv("WHISKY_GAME_RESOLUTION");
    *have_hz = 0;
    if (!e) return 0;
    if (!*e || strcasecmp(e, "off") == 0) return -1;   /* explicitly disabled */
    unsigned a = 0, b = 0; double z = 0;
    int n = sscanf(e, "%ux%u@%lf", &a, &b, &z);
    if (n < 2 || !a || !b) return 0;
    *w = a; *h = b;
    if (n == 3 && z > 0) { *hz = z; *have_hz = 1; }
    return 1;
}

/* UTF-16LE -> ASCII, in place-ish. GraphicsConfig.xml is UTF-16 with a BOM. */
static void utf16le_to_ascii(const unsigned char *in, size_t inlen, char *out, size_t outlen) {
    size_t o = 0;
    for (size_t i = 0; i + 1 < inlen && o + 1 < outlen; i += 2) {
        unsigned char lo = in[i], hi = in[i + 1];
        if (hi != 0) { out[o++] = '?'; continue; }
        out[o++] = (char)lo;
    }
    out[o] = '\0';
}

static int xml_tag_uint(const char *xml, const char *tag, unsigned *val) {
    char open[64], close[64];
    snprintf(open, sizeof open, "<%s>", tag);
    snprintf(close, sizeof close, "</%s>", tag);
    const char *p = strstr(xml, open);
    if (!p) return 0;
    p += strlen(open);
    const char *q = strstr(p, close);
    if (!q) return 0;
    unsigned v = 0; int any = 0;
    for (const char *r = p; r < q; r++) { if (isdigit((unsigned char)*r)) { v = v * 10 + (*r - '0'); any = 1; } }
    if (!any) return 0;
    *val = v;
    return 1;
}

static int xml_tag_str(const char *xml, const char *tag, char *out, size_t n) {
    char open[64], close[64];
    snprintf(open, sizeof open, "<%s>", tag);
    snprintf(close, sizeof close, "</%s>", tag);
    const char *p = strstr(xml, open);
    if (!p) return 0;
    p += strlen(open);
    const char *q = strstr(p, close);
    if (!q || q <= p) return 0;
    size_t len = (size_t)(q - p);
    if (len >= n) len = n - 1;
    memcpy(out, p, len); out[len] = '\0';
    return 1;
}

/* Only ever consulted for the game named here. */
static const char *kConfigGames[] = { "darksoulsiii.exe", NULL };
static const char *kConfigRelPath = "AppData/Roaming/DarkSoulsIII/GraphicsConfig.xml";

static int game_has_config(const char *base) {
    if (!base) return 0;
    for (int i = 0; kConfigGames[i]; i++)
        if (strcasecmp(base, kConfigGames[i]) == 0) return 1;
    return 0;
}

/* $WINEPREFIX/drive_c/users/<any>/AppData/Roaming/DarkSoulsIII/GraphicsConfig.xml */
static int find_config(char *out, size_t n) {
    const char *prefix = getenv("WINEPREFIX");
    if (!prefix || !*prefix) return 0;
    char users[PATH_MAX];
    snprintf(users, sizeof users, "%s/drive_c/users", prefix);
    DIR *d = opendir(users);
    if (!d) return 0;
    struct dirent *de;
    int found = 0;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        snprintf(out, n, "%s/%s/%s", users, de->d_name, kConfigRelPath);
        if (access(out, R_OK) == 0) { found = 1; break; }
    }
    closedir(d);
    return found;
}

/* Returns 1 with (w,h[,hz]) filled, 0 for "no target", -1 for "disabled". */
static int resolve_target(size_t *w, size_t *h, double *hz, int *have_hz, const char *base) {
    int rc = parse_env_res(w, h, hz, have_hz);
    if (rc != 0) return rc;                       /* explicit or disabled */
    if (!game_has_config(base)) return 0;         /* not a game we scope to */
    char path[PATH_MAX];
    if (!find_config(path, sizeof path)) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    unsigned char raw[65536];
    size_t got = fread(raw, 1, sizeof raw, f);
    fclose(f);
    if (got < 8) return 0;
    char *xml = malloc(got + 2);                  /* 1 byte per 2, worst case */
    if (!xml) return 0;
    utf16le_to_ascii(raw, got, xml, got + 1);
    char mode[64] = {0};
    unsigned fw = 0, fh = 0;
    int ok = 0;
    if (xml_tag_str(xml, "ScreenMode", mode, sizeof mode) && strstr(mode, "FULLSCREEN") &&
        xml_tag_uint(xml, "Resolution-FullScreenWidth", &fw) &&
        xml_tag_uint(xml, "Resolution-FullScreenHeight", &fh) && fw && fh) {
        *w = fw; *h = fh; *have_hz = 0; ok = 1;
    }
    free(xml);
    return ok;
}

/* ---------- crash guardian ----------
 * Holds the desktop's mode number and restores it when the supervisor goes
 * away, whatever killed it. SIGKILL cannot be caught, so a signal handler is
 * not enough; a separate process watching the supervisor's pid is.
 *
 * It restores unconditionally on the supervisor's death -- it has no way to
 * know whether the supervisor already restored, and re-applying the mode the
 * user's desktop is ALREADY on is harmless (verified: same tuple back). */
static int cmd_guard(pid_t sup, int cgsNum, size_t gw, size_t gh) {
    if (cgsNum < 0) return 1;
    fprintf(stderr, "[mode-fixup] guard: holding mode %d for supervisor %d\n",
            cgsNum, (int)sup);
    for (;;) {
        usleep(250000);
        if (kill(sup, 0) != 0) break;
    }
    size_t w, h, ptw, pth; double hz;
    if (read_mode(&w, &h, &ptw, &pth, &hz) && w == gw && h == gh) {
        fprintf(stderr, "[mode-fixup] guard: supervisor gone while display still at "
                        "%zux%zu; restoring mode %d\n", gw, gh, cgsNum);
        if (apply_cgs_mode(cgsNum))
            fprintf(stderr, "[mode-fixup] guard: restored mode %d\n", cgsNum);
        else
            fprintf(stderr, "[mode-fixup] guard: FAILED to restore mode %d\n", cgsNum);
    } else {
        fprintf(stderr, "[mode-fixup] guard: supervisor gone; display not at %zux%zu, "
                        "nothing to undo\n", gw, gh);
    }
    return 0;
}

/* ---------- is the watched game actually running? ----------
 *
 * The wrapper hands us the pid of the process that will BECOME the game (it
 * execv()s the loader, so the pid survives). That covers the normal flow.
 *
 * It does not cover the second game of a session: the helper is forked only
 * once per bottle (one helper, not one per exec -- see the lock), so if a
 * different game started first, this helper was seeded with THAT pid and would
 * never notice a later launch of the game we care about. Falling back to a
 * name lookup fixes that while keeping the scoping per-game: the display is
 * only ever touched while a process matching the game's exe name exists.
 *
 * pgrep -f matches this helper's OWN argv (the exe name is argument five), so
 * our pid is filtered out. Polled at most every kNamePollTicks ticks, and only
 * while a resolution hold is actually configured -- it is a fork+exec, not
 * something to run ten times a second for no reason. */
static const int kNamePollTicks = 4;      /* ~2s */
static pid_t g_game_pid = 0;
static int   g_name_ticks = 0;
static int   g_name_alive = 0;

static int game_name_alive(const char *exe) {
    if (!exe || !*exe) return 0;
    /* Match the EXECUTABLE, not the whole command line.
     *
     * This used to be `pgrep -fi <exe>`, and -f matches argv in full -- which
     * includes THIS helper's own argv, since the wrapper spawns it as
     *     mode-fixup auto <server-pid> <lock> <game-pid> darksoulsiii.exe
     * Excluding only our own pid was not enough: any sibling or leftover
     * helper carrying the name made every other helper believe the game was
     * running.  Launching Steam on its own was then enough to adopt a game
     * that did not exist and switch the display to its resolution.
     *
     * `ps -axo command=` plus an explicit basename comparison keeps the match
     * on the process's own image.  Wine reports WINDOWS paths
     * (C:\...\DarkSoulsIII.exe), so compare the last path component of the
     * FIRST argv token only, case-insensitively, and skip any line that is one
     * of our own helpers. */
    char cmd[PATH_MAX];
    snprintf(cmd, sizeof cmd, "ps -axo pid=,command= 2>/dev/null");
    FILE *p = popen(cmd, "r");
    if (!p) return 0;

    size_t exelen = strlen(exe);
    char line[2048];
    int alive = 0;
    pid_t me = getpid();
    while (!alive && fgets(line, sizeof line, p)) {
        pid_t pid = 0;
        char rest[1990] = {0};
        if (sscanf(line, "%d %1989[^\n]", &pid, rest) != 2) continue;
        if (pid <= 0 || pid == me) continue;
        if (strstr(rest, "mode-fixup")) continue;      /* never match ourselves */

        /* Find the exe name as a real PATH COMPONENT.
         *
         * Tokenising on whitespace does not work here: wine reports Windows
         * paths and every Steam one has spaces in it --
         *   C:\Program Files (x86)\Steam\steamapps\common\DARK SOULS III\Game\DarkSoulsIII.exe
         * so the first whitespace-delimited token is "C:\Program".  Instead
         * scan for the name and require it to be preceded by a path separator
         * and followed by end-of-token.  That matches the real image and
         * rejects a mention in someone's arguments (`grep -F DarkSoulsIII.exe`
         * has a SPACE before the name, not a separator). */
        for (const char *s = rest; (s = strcasestr(s, exe)) != NULL; s += 1) {
            char before = (s == rest) ? '\0' : s[-1];
            char after  = s[exelen];
            if ((before == '\\' || before == '/') &&
                (after == '\0' || after == ' ' || after == '\n')) {
                alive = 1;
                break;
            }
        }
    }
    pclose(p);
    return alive;
}

static int game_is_running(const char *exe) {
    if (g_game_pid > 0 && kill(g_game_pid, 0) == 0) return 1;
    if (g_name_ticks-- > 0) return g_name_alive;
    g_name_ticks = kNamePollTicks;
    g_name_alive = game_name_alive(exe);
    return g_name_alive;
}

/* Is any CONFIG-SCOPED game running that we should adopt?
 *
 * Returns 1 and fills base_out with the exe name if so. Only the names in
 * kConfigGames[] can be adopted, so this can never start holding a resolution
 * for an arbitrary wine process. Costs one pgrep, called on the same slow
 * cadence as the liveness check and only when the hold is not already engaged. */
static int adopt_configured_game(char *base_out, size_t n) {
    for (int i = 0; kConfigGames[i]; i++) {
        if (game_name_alive(kConfigGames[i])) {
            snprintf(base_out, n, "%s", kConfigGames[i]);
            return 1;
        }
    }
    return 0;
}

/* Re-run target resolution for a NEWLY adopted exe name. Returns 1 with the
 * globals set if the newly adopted game has a target. */
static int recompute_target(size_t *w, size_t *h, double *hz, int *have_hz, const char *base) {
    int rc = resolve_target(w, h, hz, have_hz, base);
    if (rc != 1) return 0;
    return 1;
}

int main(int argc, char **argv) {
    resolve_self();

    if (argc >= 2 && strcmp(argv[1], "--read") == 0) return child_read();
    if (argc >= 2 && strcmp(argv[1], "--readcgs") == 0) return child_readcgs();
    if (argc >= 3 && strcmp(argv[1], "--cgsapply") == 0) return child_cgsapply(atoi(argv[2]));
    if (argc >= 6 && strcmp(argv[1], "--guard") == 0)
        return cmd_guard((pid_t)atoi(argv[2]), atoi(argv[3]),
                         (size_t)atol(argv[4]), (size_t)atol(argv[5]));
    if (argc >= 7 && strcmp(argv[1], "--apply") == 0)
        return child_apply((size_t)atol(argv[2]), (size_t)atol(argv[3]),
                            (size_t)atol(argv[4]), (size_t)atol(argv[5]), atof(argv[6]));

    if (argc < 2) {
        fprintf(stderr, "usage: %s <max-hz|auto> [watch-pid] [lock-file] [game-pid] [game-exe]\n", argv[0]);
        return 2;
    }
    /* "auto" (the default) means: cap at whatever refresh the desktop is
     * already running. That mode is known-good by definition -- the link
     * carries it at the user's chosen colour depth and it is what they picked.
     * A hardcoded number cannot be right across a docked ultrawide, a built-in
     * panel, and whatever display is attached next. A literal number is still
     * accepted for a deliberate override. */
    const int cap_auto = (strcmp(argv[1], "auto") == 0);
    double cap = cap_auto ? 0 : atof(argv[1]);
    const pid_t watch = (argc > 2) ? (pid_t)atoi(argv[2]) : 0;
    const char *lockfile = (argc > 3) ? argv[3] : NULL;
    g_game_pid = (argc > 4) ? (pid_t)atoi(argv[4]) : 0;
    const char *game_exe = (argc > 5) ? argv[5] : NULL;

    signal(SIGINT, stop);
    signal(SIGTERM, stop);
    signal(SIGHUP, stop);

    size_t desk_w = 0, desk_h = 0, desk_ptw = 0, desk_pth = 0; double desk_hz = 0;
    if (!read_mode(&desk_w, &desk_h, &desk_ptw, &desk_pth, &desk_hz)) {
        fprintf(stderr, "[mode-fixup] FAILED to read desktop mode; exiting\n");
        return 1;
    }
    /* The mode NUMBER of the desktop, captured before anything is touched.
     * This is the only way back to a scaled desktop mode -- see header. */
    const int desk_cgs = read_cgs_mode();
    if (cap_auto) cap = desk_hz;

    fprintf(stderr,
            "[mode-fixup] start: cap %.0fHz%s, watching pid %d, desktop %zux%zu (pt %zux%zu) @ %.0fHz"
            " (cgs mode %d)\n",
            cap, cap_auto ? " (auto, from desktop)" : "", (int)watch,
            desk_w, desk_h, desk_ptw, desk_pth, desk_hz, desk_cgs);

    /* If the refresh is already above the cap at startup, this is NOT a clean
     * desktop -- a game has already switched the mode and we started late.
     * Recording it as the baseline would make this helper defend the very mode
     * it exists to correct, and restore the game's mode as "the desktop" on
     * exit. Both were observed. Cap it now and treat the capped mode as the
     * baseline; if the real desktop was something else the user's own mode is
     * still untouched, because we never write a permanent configuration. */
    if (desk_hz > cap) {
        double under = best_hz_under_cap(desk_w, desk_h, desk_ptw, desk_pth, cap);
        fprintf(stderr, "[mode-fixup] startup mode %.0fHz is above cap -- a game already switched\n",
                desk_hz);
        if (under > 0 && apply_mode(desk_w, desk_h, desk_ptw, desk_pth, under)) {
            fprintf(stderr, "[mode-fixup] capped startup mode to %.0fHz\n", under);
            desk_hz = under;
        }
    }

    /* ---------------- the 21:9 fix: hold the game's own resolution ---------------- */
    size_t tgt_w = 0, tgt_h = 0; double tgt_hz = 0; int tgt_have_hz = 0;
    int tgt = resolve_target(&tgt_w, &tgt_h, &tgt_hz, &tgt_have_hz, game_exe);
    double tgt_rate = 0;
    int env_explicit = 0;
    {   /* an env value, even "off", is an explicit instruction: never adopt past it */
        const char *e = getenv("WHISKY_GAME_RESOLUTION");
        if (e && *e) env_explicit = 1;
    }

    /* Compute the rate and arm the hold. Factored out because a game can be
     * ADOPTED mid-session (see the loop) and needs exactly the same setup. */
    int armed = 0;
    while (tgt == 1) {
        /* Always resolve the actual mode from the display's own list, even when
         * the caller named a rate: a rate that does not exist at this resolution
         * (env typo, a rate the link cannot carry, a monitor swap) would
         * otherwise be applied forever without ever landing. */
        double want = tgt_have_hz ? tgt_hz : cap;
        if (want > cap) want = cap;
        tgt_rate = best_hz_under_cap(tgt_w, tgt_h, tgt_w, tgt_h, want);
        if (tgt_rate <= 0) {
            /* A 1:1 mode at the game's own resolution may simply not exist at a
             * rate at or under the desktop's refresh. Retry above the cap rather
             * than giving up: a true 1:1 mode is the whole point here, and the
             * panel's own pillarboxing is worth more than the rate cap. */
            tgt_rate = best_hz_under_cap(tgt_w, tgt_h, tgt_w, tgt_h, 1e9);
            if (tgt_rate > 0)
                fprintf(stderr, "[mode-fixup] %zux%zu: no mode at or under the %.0fHz cap;"
                                " using %.0fHz (above the cap -- a true 1:1 mode is what"
                                " fixes the aspect ratio)\n", tgt_w, tgt_h, cap, tgt_rate);
        }
        if (tgt_rate <= 0) {
            fprintf(stderr, "[mode-fixup] no true %zux%zu mode at any rate;"
                            " resolution hold disabled\n", tgt_w, tgt_h);
            tgt = 0;
            break;
        }
        if (tgt_have_hz && tgt_rate != tgt_hz)
            fprintf(stderr, "[mode-fixup] requested %.0fHz is not available at %zux%zu;"
                            " using %.0fHz instead\n", tgt_hz, tgt_w, tgt_h, tgt_rate);
        if (tgt_w == desk_w && tgt_h == desk_h) {
            fprintf(stderr, "[mode-fixup] desktop is already %zux%zu; nothing to hold\n",
                    tgt_w, tgt_h);
            tgt = 0;
            break;
        }
        break;
    }
    if (tgt == 1) {
        int cgs_ok = (desk_cgs >= 0);
        armed = 1;
        fprintf(stderr,
                "[mode-fixup] resolution hold: %zux%zu @ %.0fHz for '%s' (pid %d)"
                " while the game runs; restore will use %s\n",
                tgt_w, tgt_h, tgt_rate, game_exe ? game_exe : "(env)", (int)g_game_pid,
                cgs_ok ? "the private SkyLight mode number" : "the public 5-tuple path");
        if (!cgs_ok)
            fprintf(stderr, "[mode-fixup] WARNING: SkyLight unavailable -- a scaled desktop"
                            " mode cannot be restored by the public API\n");

        /* Detached crash guardian: survives this process being SIGKILLed.
         * Spawned whenever a hold is armed, whether or not a game pid was
         * supplied -- what it protects is the DISPLAY, and its restore is
         * conditional on the display still being on the held resolution, so it
         * cannot clobber a mode the user chose while it waited. */
        if (cgs_ok) {
            pid_t g = fork();
            if (g == 0) {
                setsid();
                int devnull = open("/dev/null", O_RDWR);
                if (devnull >= 0) { dup2(devnull, STDIN_FILENO); dup2(devnull, STDOUT_FILENO); }
                char sp[16], sn[16], w[16], h[16];
                snprintf(sp, sizeof sp, "%d", (int)getppid());
                snprintf(sn, sizeof sn, "%d", desk_cgs);
                snprintf(w, sizeof w, "%zu", tgt_w);
                snprintf(h, sizeof h, "%zu", tgt_h);
                char *ga[] = { (char *)g_self, (char *)"--guard", sp, sn, w, h, NULL };
                execv(g_self, ga);
                _exit(127);
            } else if (g > 0) {
                fprintf(stderr, "[mode-fixup] crash guardian spawned as pid %d\n", (int)g);
            }
        }
    } else if (tgt == -1) {
        fprintf(stderr, "[mode-fixup] resolution hold disabled by WHISKY_GAME_RESOLUTION\n");
    }

    size_t cur_w = 0, cur_h = 0, cur_ptw = 0, cur_pth = 0;
    int nudged = 0, caps = 0, ticks = 0;
    int restore_nudge_pending = 0, restore_ticks = 0;
    int res_fixes = 0, holding = 0;
    int adopt_ticks = 0;
    char adopt_base[64] = {0};

    /* The display can change under us: undocking, plugging in another monitor,
     * or a display sleeping. The baseline and the auto cap belong to whatever
     * display we are on now, so track the id and re-derive both when it moves. */
    CGDirectDisplayID base_display = CGMainDisplayID();

    while (running) {
        if (watch && kill(watch, 0) != 0) break;

        CGDirectDisplayID now_display = CGMainDisplayID();
        if (now_display != base_display) {
            /* Different display: the old baseline describes a screen that is no
             * longer here, and restoring it later would be wrong. Adopt the new
             * display's current mode as the baseline. */
            base_display = now_display;
            if (read_mode(&desk_w, &desk_h, &desk_ptw, &desk_pth, &desk_hz)) {
                if (cap_auto) cap = desk_hz;
                fprintf(stderr,
                        "[mode-fixup] display changed; new baseline %zux%zu (pt %zux%zu) @ %.0fHz, cap %.0fHz\n",
                        desk_w, desk_h, desk_ptw, desk_pth, desk_hz, cap);
                if (tgt == 1 && !tgt_have_hz) {
                    double r = best_hz_under_cap(tgt_w, tgt_h, tgt_w, tgt_h, cap);
                    if (r > 0) tgt_rate = r;
                }
            }
            cur_w = cur_h = cur_ptw = cur_pth = 0; nudged = 0; caps = 0; ticks = 0; res_fixes = 0;
            usleep(500000);
            continue;
        }

        /* ---- resolution hold: put the display on the game's true resolution ---- */
        int game_alive = (tgt == 1) ? game_is_running(game_exe) : 0;

        /* Adopt a config-scoped game that appeared after we started -- and only
         * when the caller did not explicitly say what to do. With no env value
         * we are in auto mode, and auto mode's whole purpose is "hold the game's
         * own resolution for the game's own lifetime". Whichever process won the
         * one-helper-per-bottle race, this is the fix actually engaging.
         * Checked on the slow cadence; stops the moment a hold is engaged. */
        if (tgt != 1 && !env_explicit && !holding) {
            if (adopt_ticks-- <= 0) {
                adopt_ticks = kNamePollTicks * 2;
                if (adopt_configured_game(adopt_base, sizeof adopt_base)) {
                    size_t aw = 0, ah = 0; double ahz = 0; int ahave = 0;
                    if (recompute_target(&aw, &ah, &ahz, &ahave, adopt_base)) {
                        double want = ahave ? ahz : cap;
                        if (want > cap) want = cap;
                        double rate = best_hz_under_cap(aw, ah, aw, ah, want);
                        if (rate <= 0) rate = best_hz_under_cap(aw, ah, aw, ah, 1e9);
                        if (rate > 0 && !(aw == desk_w && ah == desk_h)) {
                            game_exe = adopt_base;
                            tgt_w = aw; tgt_h = ah; tgt_hz = ahz;
                            tgt_have_hz = ahave; tgt_rate = rate;
                            tgt = 1;
                            fprintf(stderr, "[mode-fixup] adopting '%s': resolution hold"
                                            " %zux%zu @ %.0fHz (started under '%s')\n",
                                    adopt_base, aw, ah, rate,
                                    game_exe && game_exe != adopt_base ? game_exe : "(none)");
                            game_exe = adopt_base;
                        }
                    }
                }
            }
        }
        if (tgt == 1) {
            if (game_alive) {
                size_t w, h, ptw, pth; double hz;
                if (read_mode(&w, &h, &ptw, &pth, &hz) &&
                    (w != tgt_w || h != tgt_h || ptw != tgt_w || pth != tgt_h)) {
                    if (res_fixes < kMaxRapidCaps) {
                        if (apply_mode(tgt_w, tgt_h, tgt_w, tgt_h, tgt_rate)) {
                            fprintf(stderr, "[mode-fixup] held %zux%zu @ %.0fHz"
                                            " (was %zux%zu pt %zux%zu @ %.0fHz)\n",
                                    tgt_w, tgt_h, tgt_rate, w, h, ptw, pth, hz);
                            holding = 1; res_fixes++; ticks = 0; nudged = 0;
                            usleep(500000);
                            continue;
                        }
                    }
                } else if (w == tgt_w && h == tgt_h) {
                    holding = 1;
                }
            } else if (holding) {
                fprintf(stderr, "[mode-fixup] game gone; releasing resolution hold\n");
                if (apply_cgs_mode(desk_cgs))
                    fprintf(stderr, "[mode-fixup] restored desktop via cgs mode %d\n", desk_cgs);
                holding = 0; nudged = 0; caps = 0; ticks = 0; res_fixes = 0;
                cur_w = cur_h = cur_ptw = cur_pth = 0;
                /* The way IN gets a re-layout nudge (see below) because a mode
                 * change alone does not make anything re-lay-out against it.
                 * The way OUT needs the same thing and never had it: the mode
                 * really is restored here, but WindowServer and the apps on the
                 * desktop keep their old layout, which shows up as black
                 * regions over part of the screen until something forces a
                 * re-layout -- alt-tabbing away and back is what people end up
                 * doing. Schedule one redundant re-apply of the desktop mode a
                 * moment after the restore settles. */
                restore_nudge_pending = 1; restore_ticks = 0;
                usleep(500000);
                continue;
            }
        }

        size_t w, h, ptw, pth; double hz;
        if (!read_mode(&w, &h, &ptw, &pth, &hz)) { usleep(500000); continue; }

        if (w == desk_w && h == desk_h && ptw == desk_ptw && pth == desk_pth) {  /* on the desktop mode */
            cur_w = cur_h = cur_ptw = cur_pth = 0; nudged = 0; caps = 0; ticks = 0; res_fixes = 0;
            /* Re-layout nudge for the RESTORE, mirroring the one on the way in.
             * Only fires when a restore actually armed it, so an idle desktop is
             * never touched. */
            if (restore_nudge_pending) {
                restore_ticks++;
                if (restore_ticks >= 4) {
                    if (apply_cgs_mode(desk_cgs))
                        fprintf(stderr, "[mode-fixup] restore re-layout nudge via cgs mode %d\n", desk_cgs);
                    restore_nudge_pending = 0; restore_ticks = 0;
                }
            }
            usleep(500000);
            continue;
        }

        /* left the desktop mode again -- any pending restore nudge is moot */
        restore_nudge_pending = 0; restore_ticks = 0;

        if (w != cur_w || h != cur_h || ptw != cur_ptw || pth != cur_pth) {   /* new game-set mode */
            cur_w = w; cur_h = h; cur_ptw = ptw; cur_pth = pth;
            nudged = 0; caps = 0; ticks = 0;
            fprintf(stderr, "[mode-fixup] game set %zux%zu (pt %zux%zu) @ %.0fHz\n",
                    w, h, ptw, pth, hz);
        }
        ticks++;
        /* Quiet for a while: forget past corrections, so the damping counter
         * can never accumulate across a whole session into a permanent stop. */
        if (ticks >= kStableTicks) { caps = 0; if (holding) res_fixes = 0; }

        if (hz > cap && caps < kMaxRapidCaps) {
            double target = best_hz_under_cap(w, h, ptw, pth, cap);
            if (target > 0 && apply_mode(w, h, ptw, pth, target)) {
                fprintf(stderr, "[mode-fixup] %zux%zu (pt %zux%zu) %.0fHz -> %.0fHz\n",
                        w, h, ptw, pth, hz, target);
                caps++;
                ticks = 0;      /* let it settle before nudging */
                nudged = 0;
            }
        }

        if (!nudged && ticks >= 4) {
            /* ~2s after the mode settled and the game's window exists: re-apply
             * the mode so wine's reconfiguration callback fires and it re-lays
             * out its fullscreen window.
             *
             * Re-apply the CAPPED rate, not the observed one. Reading `hz` here
             * can catch the instant after wine has re-asserted its own choice,
             * and nudging with that value pushed the display straight back to
             * 240Hz -- the nudge undoing the cap it was supposed to follow. */
            double nudge_hz = hz;
            if (nudge_hz > cap) {
                double under = best_hz_under_cap(w, h, ptw, pth, cap);
                if (under > 0) nudge_hz = under;
            }
            if (apply_mode(w, h, ptw, pth, nudge_hz))
                fprintf(stderr, "[mode-fixup] re-layout nudge at %zux%zu (pt %zux%zu) @ %.0fHz\n",
                        w, h, ptw, pth, nudge_hz);
            nudged = 1;
        }

        usleep(500000);
    }

    /* We changed the mode, so we put it back: kCGConfigureForSession does not
     * revert on its own, and wine's own restore cannot be relied on once we
     * have reconfigured the display underneath it.
     *
     * Order matters. If we were holding a resolution, the desktop mode is the
     * one we captured at startup, and for a scaled desktop only its mode NUMBER
     * can set it. Fall back to the 5-tuple path when SkyLight is unavailable,
     * which is exactly the old behaviour. */
    fprintf(stderr, "[mode-fixup] watched pid gone; restoring\n");
    if (lockfile) unlink(lockfile);
    size_t w, h, ptw, pth; double hz;
    int off_desktop = read_mode(&w, &h, &ptw, &pth, &hz) &&
                      (w != desk_w || h != desk_h || ptw != desk_ptw || pth != desk_pth || hz != desk_hz);
    if (off_desktop) {
        if (holding && desk_cgs >= 0) {
            if (apply_cgs_mode(desk_cgs))
                fprintf(stderr, "[mode-fixup] restored desktop via cgs mode %d"
                                " (%zux%zu pt %zux%zu @ %.0fHz)\n",
                        desk_cgs, desk_w, desk_h, desk_ptw, desk_pth, desk_hz);
            else if (apply_mode(desk_w, desk_h, desk_ptw, desk_pth, desk_hz))
                fprintf(stderr, "[mode-fixup] restored desktop %zux%zu (pt %zux%zu) @ %.0fHz\n",
                        desk_w, desk_h, desk_ptw, desk_pth, desk_hz);
        } else if (apply_mode(desk_w, desk_h, desk_ptw, desk_pth, desk_hz))
            fprintf(stderr, "[mode-fixup] restored desktop %zux%zu (pt %zux%zu) @ %.0fHz\n",
                    desk_w, desk_h, desk_ptw, desk_pth, desk_hz);
    }
    return 0;
}
