// ds3-display-watch.c — always-on watcher for the post-DS3-quit display fault.
//
// THE FAULT (user, 2026-09-21): after quitting Dark Souls III the desktop is
// squeezed into roughly the right quarter of the ultrawide and the rest of the
// panel is black; the built-in panel goes black too.  The user CANNOT INTERACT
// while this is happening, so a watcher that only records is useless — it has
// to recover the machine as well.
//
// WHAT IT IS NOT: mode-fixup's restore demonstrably works.  Measured live:
//   [mode-fixup] restored desktop via cgs mode 149
//   [mode-fixup] restore re-layout nudge via cgs mode 149
// and modes 149/150 are BOTH density=2.0 flags=0x00200001 (the correct scaled
// HiDPI desktop), so "restored to the wrong mode number" is ruled out.
//
// WHAT IT PROBABLY IS: a wine-owned window/capture outliving the game pid.
// 2560/3440 = 74.4% covered, leaving 25.6% visible — exactly the right-hand
// strip the user photographed, with content at NORMAL size (not a shrunken
// desktop).  winemac.drv re-applies its mode on applicationDidBecomeActive and
// restores on resign, which is exactly the 21:9 -> 16:9 -> fullscreen flicker
// the user sees when alt-tabbing.  So: a live wine process still owns a
// 2560x1440 mode after mode-fixup has already declared "game gone".
//
// DETECTION (no user interaction required), any of:
//   A. a window owned by a bottle process, onscreen, >= 2000 wide, while NO
//      game process is alive        -> stale covering window
//   B. CGDisplayIsCaptured() on either display with no game alive
//   C. the main display is not on a density=2.0 mode
//   D. display bounds and the current mode disagree
//
// RECOVERY, in escalating order, only after evidence is captured:
//   1. if a bottle pid owns the covering window and it is NOT the game, kill
//      that pid (this is the targeted version of "kill the bottle", which is
//      what the user is reduced to doing by hand)
//   2. re-assert the desktop mode by DESCRIPTION-matched number via a fresh
//      child process (never in-process: CGCompleteDisplayConfiguration blinds
//      the calling process permanently)
//   3. verify by read-back; if still wrong, stop and leave evidence — never
//      loop reconfigures, that is how a display gets stranded
//
// Build:  clang -o ds3-display-watch ds3-display-watch.c -framework ApplicationServices
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
#include <sys/stat.h>

typedef int CGSError;
typedef struct {
    uint32_t modeNumber, flags, width, height, depth;
    uint8_t  unknown[170];
    uint16_t freq;
    uint8_t  more[16];
    float    density;
} ModeDesc;

static CGSError (*GetNumberOfDisplayModes)(CGDirectDisplayID, int *);
static CGSError (*GetDisplayModeDescription)(CGDirectDisplayID, int, ModeDesc *, int);
static CGSError (*GetCurrentDisplayMode)(CGDirectDisplayID, int *);

#define EVID "/Users/adam.durham/whisky-gptk-writeup/ds3-hang-evidence"
#define POLL_SECONDS       3
#define CONFIRM_SAMPLES    2      /* ~6s: long enough to skip a transient */
#define COVER_MIN_WIDTH    2000

static void ts(char *out, size_t n)
{
    time_t t = time(NULL);
    strftime(out, n, "%Y%m%d-%H%M%S", localtime(&t));
}

static void logline(const char *fmt, ...)
{
    FILE *f = fopen(EVID "/display-watch.log", "a");
    if (!f) return;
    char stamp[32]; time_t t = time(NULL);
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(f, "%s ", stamp);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fclose(f);
}

/* Is a pid one of the bottle's wine processes? Wine reports WINDOWS paths in
 * argv, so match the unix executable path instead via ps. */
static int pid_is_bottle(pid_t pid)
{
    char cmd[256], line[512];
    snprintf(cmd, sizeof cmd, "ps -p %d -o command= 2>/dev/null", (int)pid);
    FILE *p = popen(cmd, "r");
    if (!p) return 0;
    int hit = 0;
    if (fgets(line, sizeof line, p))
        hit = (strstr(line, "com.franke.Whisky") != NULL) ||
              (strstr(line, "whisky-rig")        != NULL) ||
              (strstr(line, "\\Steam\\")          != NULL) ||
              (strstr(line, "wine")              != NULL);
    pclose(p);
    return hit;
}

static int game_alive(void)
{
    FILE *p = popen("ps ax -o command= | grep -ci '[D]arkSoulsIII.exe'", "r");
    if (!p) return 0;
    char b[32] = {0}; if (fgets(b, sizeof b, p)) {} pclose(p);
    return atoi(b) > 0;
}

/* The desktop mode we consider correct: density 2.0 on the main display. */
/* Is the display genuinely usable, not merely on a mode that LOOKS right?
 *
 * The previous check asked only "is the current mode density 2.0", which
 * modes 149 AND 150 both satisfy -- so a display left on the wrong one of
 * them reported "HiDPI restored" while the user still saw a squeezed desktop
 * and had to alt-tab.  Verifying a mode's properties is not verifying the
 * result.
 *
 * What actually distinguishes a healthy desktop:
 *   - a density-2.0 (scaled HiDPI) mode, AND
 *   - no display capture outstanding, AND
 *   - no onscreen window owned by a bottle process covering the desktop, AND
 *   - the menu bar / Dock present at the expected size (WindowServer owns
 *     them; if the compositor is confused they go missing or resize).
 */
static int main_mode_ok(int *cur_out, float *density_out)
{
    CGDirectDisplayID d = CGMainDisplayID();
    int cur = -1, total = 0;
    GetCurrentDisplayMode(d, &cur);
    GetNumberOfDisplayModes(d, &total);
    ModeDesc desc; memset(&desc, 0, sizeof desc);
    if (cur < 0 || GetDisplayModeDescription(d, cur, &desc, sizeof desc) != 0) return -1;
    if (cur_out) *cur_out = cur;
    if (density_out) *density_out = desc.density;
    return (desc.density >= 1.9f) ? 1 : 0;
}

/* The stronger check: mode properties AND the compositor actually being sane.
 * Returns 1 only when the desktop is genuinely back. */
static pid_t find_covering_window(char *owner_out, size_t n, CGRect *rect_out);

static int desktop_really_usable(int *cur_out, float *density_out)
{
    if (main_mode_ok(cur_out, density_out) != 1) return 0;
    if (CGDisplayIsCaptured(CGMainDisplayID())) return 0;

    /* A bottle-owned window covering the display with no game running is the
     * signature of the stale-covering-window fault. */
    char owner[128] = {0}; CGRect r = CGRectZero;
    if (find_covering_window(owner, sizeof owner, &r)) return 0;

    /* The menu bar belongs to "Window Server" -- note the SPACE in the owner
     * name here, unlike the process name "WindowServer".  Measured on a healthy
     * desktop: owner="Window Server", layer=24, bounds=(0,0 3440x30) with the
     * display 3440 wide.  Matching on the process-name spelling found nothing
     * and made this check report the desktop as broken when it was fine. */
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!list) return 0;
    int menubar_ok = 0;
    CGDirectDisplayID main_id = CGMainDisplayID();
    CGRect db = CGDisplayBounds(main_id);
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n && !menubar_ok; i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
        CFStringRef ownerName = CFDictionaryGetValue(w, kCGWindowOwnerName);
        if (!ownerName) continue;
        char on[128] = {0};
        CFStringGetCString(ownerName, on, sizeof on, kCFStringEncodingUTF8);
        if (strcmp(on, "Window Server") != 0 && strcmp(on, "WindowServer") != 0)
            continue;
        CGRect wr = CGRectZero;
        CFDictionaryRef bd = CFDictionaryGetValue(w, kCGWindowBounds);
        if (!bd || !CGRectMakeWithDictionaryRepresentation(bd, &wr)) continue;
        /* the menu-bar strip: full display width, short, at the top */
        if (wr.origin.y <= 2 && wr.size.width >= db.size.width - 2 &&
            wr.size.height > 0 && wr.size.height < 80)
            menubar_ok = 1;
    }
    CFRelease(list);
    return menubar_ok;
}

/* Find an onscreen window wide enough to cover the desktop that belongs to a
 * bottle process. Returns its owner pid, or 0. */
static pid_t find_covering_window(char *owner_out, size_t n, CGRect *rect_out)
{
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!list) return 0;
    pid_t found = 0;
    CFIndex cnt = CFArrayGetCount(list);
    for (CFIndex i = 0; i < cnt && !found; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        CGRect r = CGRectZero;
        CFDictionaryRef bd = CFDictionaryGetValue(d, kCGWindowBounds);
        if (!bd || !CGRectMakeWithDictionaryRepresentation(bd, &r)) continue;
        if (r.size.width < COVER_MIN_WIDTH) continue;
        CFNumberRef pidref = CFDictionaryGetValue(d, kCGWindowOwnerPID);
        if (!pidref) continue;
        int pid = 0; CFNumberGetValue(pidref, kCFNumberIntType, &pid);
        if (pid <= 0 || !pid_is_bottle((pid_t)pid)) continue;
        found = (pid_t)pid;
        if (owner_out) {
            CFStringRef o = CFDictionaryGetValue(d, kCGWindowOwnerName);
            if (o) CFStringGetCString(o, owner_out, n, kCFStringEncodingUTF8);
        }
        if (rect_out) *rect_out = r;
    }
    CFRelease(list);
    return found;
}

static void capture_evidence(const char *tag, const char *why)
{
    char stamp[32]; ts(stamp, sizeof stamp);
    char dir[512];
    snprintf(dir, sizeof dir, EVID "/display-%s-%s", tag, stamp);
    mkdir(dir, 0755);

    char cmd[2048];
    snprintf(cmd, sizeof cmd,
        "{ echo 'WHY: %s'; echo; "
        "echo '=== faultprobe (mode / bounds / origin / capture / drawn extents) ==='; "
        "  /Users/adam.durham/whisky-gptk-writeup/scripts/faultprobe '%s' '%s' 2>&1; "
        "echo '=== modeprobe ==='; /tmp/modeprobe 3440 2>&1; "
        "echo '=== all onscreen windows ==='; /tmp/winall 2>&1; "
        "echo '=== bottle processes ==='; ps ax -o pid,ppid,lstart,%%cpu,state,command | "
        "  grep -iE 'DarkSouls|steam|wine|mode-fixup|explorer.exe|Whisky' | grep -v grep; "
        "echo '=== does the game process carry WHISKY_EXTERNAL_MODE_CONTROL? ==='; "
        "  ps ax -o pid=,command= | grep -iE 'DarkSouls' | grep -v grep | head -3 | "
        "  while read p c; do printf '  pid %%s: ' \"$p\"; ps eww -p \"$p\" 2>/dev/null | "
        "  tr ' ' '\\n' | grep -c WHISKY_EXTERNAL_MODE_CONTROL; done; "
        "echo '=== mode-fixup log tail ==='; tail -40 /tmp/mode-fixup.log 2>/dev/null; "
        "echo '=== WindowServer last 2m ==='; /usr/bin/log show --last 2m "
        "  --predicate 'process == \"WindowServer\"' 2>/dev/null | tail -60; "
        "} > '%s/snapshot.txt' 2>&1", why, tag, why, dir);
    system(cmd);
    logline("CAPTURE %s -> %s\n", why, dir);
}

/* Release a display capture that outlived the process which took it.
 *
 * MEASURED FAULT: after a game exits, CGDisplayIsCaptured() can still report 1
 * with no game alive, and a CAPTURED display REFUSES mode changes -- an
 * attempt to restore the desktop mode lands on a different mode instead
 * (observed: re-assert mode 149 -> ended up on mode 99, a 1x mode with the
 * same point size).  Wine takes the capture in winemac's cocoa_app.m
 * (CGCaptureAllDisplays) when a window needs the display exclusively, and its
 * release path is conditional on state that can already be cleared by the time
 * the game tears down, so the capture leaks.
 *
 * Releasing it is the prerequisite for restoring the mode.  Done in a child
 * process for the same reason the mode work is: CGCompleteDisplayConfiguration
 * blinds the caller's view of the display permanently. */
static void release_display_capture(void)
{
    system("env -u DYLD_INSERT_LIBRARIES /usr/bin/python3 -c \""
           "import ctypes, ctypes.util;"
           "cg = ctypes.CDLL(ctypes.util.find_library('CoreGraphics'));"
           "cg.CGMainDisplayID.restype = ctypes.c_uint32;"
           "cg.CGReleaseAllDisplays.restype = ctypes.c_int32;"
           "cg.CGReleaseAllDisplays()\" >/dev/null 2>&1");
    logline("RECOVER released display capture\n");
}

/* Re-assert the desktop mode from a FRESH CHILD PROCESS. Never in-process:
 * CGCompleteDisplayConfiguration permanently blinds the caller's view of the
 * display, which is how earlier versions of this work ended up defending the
 * very mode they were meant to correct. */
static void reassert_desktop_mode(int mode_number)
{
    char cmd[512];
    snprintf(cmd, sizeof cmd,
        "env -u DYLD_INSERT_LIBRARIES "
        "'/Users/adam.durham/Library/Application Support/com.franke.Whisky/"
        "Libraries/Wine/bin/mode-fixup' --cgsapply %d >/dev/null 2>&1",
        mode_number);
    system(cmd);
    logline("RECOVER re-asserted cgs mode %d\n", mode_number);
}

int main(void)
{
    void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!sl) { fprintf(stderr, "no SkyLight\n"); return 1; }
    GetNumberOfDisplayModes   = dlsym(sl, "CGSGetNumberOfDisplayModes");
    GetDisplayModeDescription = dlsym(sl, "CGSGetDisplayModeDescriptionOfLength");
    GetCurrentDisplayMode     = dlsym(sl, "CGSGetCurrentDisplayMode");
    if (!GetNumberOfDisplayModes || !GetDisplayModeDescription || !GetCurrentDisplayMode) {
        fprintf(stderr, "missing SkyLight symbols\n"); return 1;
    }

    mkdir(EVID, 0755);

    /* Baseline: the mode number the desktop is on while everything is healthy.
     * Captured once at startup, before any game has run. */
    int good_mode = -1; float dens = 0;
    if (main_mode_ok(&good_mode, &dens) == 1)
        logline("watcher started; healthy desktop = cgs mode %d (density %.1f)\n", good_mode, dens);
    else
        logline("watcher started; desktop NOT on a 2x mode at startup (mode %d density %.1f)\n",
                good_mode, dens);

    int bad_streak = 0, recovered_for_this_fault = 0;

    for (;;) {
        sleep(POLL_SECONDS);

        int alive = game_alive();
        int cur = -1; float d = 0;
        int mode_ok = main_mode_ok(&cur, &d);

        /* While a game runs, a 2560x1440 1x mode and a big wine window are both
         * CORRECT. Track the healthy baseline only when nothing is running. */
        if (alive) { bad_streak = 0; recovered_for_this_fault = 0; continue; }

        char owner[128] = {0}; CGRect r = CGRectZero;
        pid_t coverer = find_covering_window(owner, sizeof owner, &r);
        int captured = CGDisplayIsCaptured(CGMainDisplayID()) ? 1 : 0;

        int faulted = 0; char why[512];
        if (coverer) {
            faulted = 1;
            snprintf(why, sizeof why,
                     "stale covering window: pid %d (%s) bounds=(%.0f,%.0f %.0fx%.0f), no game alive",
                     (int)coverer, owner, r.origin.x, r.origin.y, r.size.width, r.size.height);
        } else if (captured) {
            faulted = 1;
            snprintf(why, sizeof why, "display still CAPTURED with no game alive");
        } else if (mode_ok == 0) {
            faulted = 1;
            snprintf(why, sizeof why,
                     "main display on a non-HiDPI mode %d (density %.1f) with no game alive", cur, d);
        } else if (!desktop_really_usable(&cur, &d)) {
            /* The mode looks right but the desktop is not back: the menu bar is
             * missing or misplaced, or something still covers the display.
             * Checking only the mode's properties previously made this watcher
             * report success while the user still saw a broken screen. */
            faulted = 1;
            snprintf(why, sizeof why,
                     "mode %d is density %.1f but the desktop is not usable "
                     "(menu bar absent/misplaced or a window still covering)", cur, d);
        }

        if (!faulted) { bad_streak = 0; recovered_for_this_fault = 0;
                        if (mode_ok == 1 && good_mode < 0) good_mode = cur;
                        continue; }

        if (++bad_streak < CONFIRM_SAMPLES) continue;        /* skip transients */
        if (recovered_for_this_fault) continue;              /* one attempt per fault */

        capture_evidence("fault", why);

        /* RECOVERY. Evidence is already on disk before anything is touched. */
        if (coverer) {
            logline("RECOVER killing stale window owner pid %d (%s)\n", (int)coverer, owner);
            kill(coverer, SIGTERM);
            sleep(2);
            if (kill(coverer, 0) == 0) { kill(coverer, SIGKILL); sleep(1); }
        }

        /* A leaked capture MUST be released before the mode can be changed:
         * a captured display refuses reconfiguration, and the attempt then
         * lands on some other mode with the same point size (observed: asked
         * for 149, ended up on 99). */
        if (CGDisplayIsCaptured(CGMainDisplayID())) {
            release_display_capture();
            sleep(1);
        }

        if (good_mode >= 0 && main_mode_ok(NULL, NULL) != 1) {
            reassert_desktop_mode(good_mode);
            /* Re-asserting is not always enough on the first try: the mode
             * change lands only once the capture is gone and WindowServer has
             * settled. One retry, then stop -- never loop reconfigures. */
            sleep(2);
            if (main_mode_ok(NULL, NULL) != 1) {
                logline("RECOVER first re-assert did not settle; retrying once\n");
                reassert_desktop_mode(good_mode);
            }
        }

        sleep(2);
        int after = -1; float ad = 0;
        /* Judge by whether the DESKTOP is usable, not by whether the mode's
         * properties look right -- that distinction is the whole point. */
        int ok = desktop_really_usable(&after, &ad);
        if (!ok) {
            /* One more attempt, then stop. Never loop reconfigures: that is how
             * a display gets stranded. */
            logline("RECOVER not usable after first attempt; retrying once\n");
            if (CGDisplayIsCaptured(CGMainDisplayID())) release_display_capture();
            reassert_desktop_mode(good_mode >= 0 ? good_mode : 149);
            sleep(2);
            ok = desktop_really_usable(&after, &ad);
        }
        logline("RECOVER result: mode %d density %.1f -> %s\n", after, ad,
                ok ? "desktop verified usable" : "STILL NOT USABLE -- needs the user's attention");
        recovered_for_this_fault = 1;
    }
    return 0;
}
