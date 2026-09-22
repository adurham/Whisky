/*
 * Per-process env + Game Mode identity for a Whisky/Wine bottle.
 *
 * TWO JOBS
 *   1. Metal HUD scoping: set MTL_HUD_ENABLED for games, clear it for Steam's
 *      own UI (which renders via DXVK->MoltenVK and must stay clean).
 *   2. macOS Game Mode: give GAME processes a LaunchServices app identity in a
 *      games-category bundle, so gamepolicyd tracks them.
 *
 * WHY THIS WORKS (all verified live on macOS 27 before writing this)
 *   - A .app with LSApplicationCategoryType=public.app-category.games, launched
 *     through LaunchServices, is recognised:
 *       gamepolicyd: Found game GameProcess("gmtest", pid=..., 
 *                    labelReason=Plist category type)
 *     Works with an unsigned, ad-hoc binary.
 *   - Identity is pinned to the PID, NOT the executable path. A process that
 *     execv()s a different binary - even one entirely OUTSIDE the bundle -
 *     keeps it. gamepolicyd says so explicitly:
 *       "pid N still alive after exit - process likely exec'd a new binary.
 *        Keeping GameProcess(...) tracked."
 *     That is exactly wine's pattern: exec the loader, keep the identity.
 *   - Direct exec of a bundled binary does NOT register (stays anon<>); the
 *     first launch must go through LaunchServices. Hence: for game processes
 *     we hand off via `open -a <bundle> --args ...`, which runs the bundle's
 *     stub, which execs the real loader with argv intact.
 *
 * DESIGN CONSTRAINTS learned the hard way
 *   - The loader resolves ntdll.so RELATIVE TO ITS OWN PATH, so the real
 *     loader must stay in x86_64-unix/ and bin/'s symlinks must stay symlinks.
 *   - A #! script cannot do this job: the kernel rebuilds argv for an
 *     interpreter and DISCARDS argv[0], which is the token identifying the
 *     process. Hence C.
 *   - _NSGetExecutablePath returns the SYMLINK path used to invoke us, so
 *     realpath() it before deriving sibling paths.
 *
 * SAFETY
 *   Game Mode handoff only engages when WINE_GAMEMODE_BUNDLE points at an
 *   existing bundle AND the exe is not on the exclusion list. If anything is
 *   missing we fall through to a plain exec of the real loader - i.e. exactly
 *   the previous, known-good behaviour. Never fails closed onto a broken path.
 *
 * Build:  clang -arch x86_64 -O2 -o wine-hudwrap wine-hudwrap.c
 * Deploy: real loader -> x86_64-unix/wine-real ; this binary -> x86_64-unix/wine
 * Debug:  WINE_HUDWRAP_LOG=/tmp/hudwrap.log
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <stdarg.h>
#include <unistd.h>
#include <libgen.h>
#include <limits.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>

/* Refresh-rate cap for game-set fullscreen modes, and the helper that applies
 * it. Override the cap with WHISKY_MAX_REFRESH_HZ; set it empty to disable. */
#ifndef kDefaultMaxRefreshHz
/* "auto": cap at the desktop's own refresh, whatever display is attached.
 * A hardcoded rate is wrong the moment the machine is undocked or a
 * different monitor is plugged in. */
#define kDefaultMaxRefreshHz "auto"
#endif
#ifndef kModeFixupLock
#define kModeFixupLock "/tmp/.whisky-mode-fixup.lock"
#endif
#ifndef kModeFixupLog
#define kModeFixupLog "/tmp/mode-fixup.log"
#endif
#ifndef kModeFixupPath
#define kModeFixupPath \
    "/Users/adam.durham/Library/Application Support/com.franke.Whisky/Libraries/Wine/bin/mode-fixup"
#endif

/* Processes that must NOT get the HUD and must NOT be treated as games:
 * Steam's own UI plus wine's service/helper processes. */
static const char *kNoHud[] = {
    "steam.exe", "steamwebhelper.exe", "steamservice.exe",
    "steamerrorreporter.exe", "steamerrorreporter64.exe",
    "gameoverlayui.exe", "gameoverlayui64.exe", "gldriverquery.exe",
    "streaming_client.exe", "html5app_steam.exe",
    /* Steam helper processes that ALSO look like games to the wrapper. Each one
     * that slips through claims the one-helper-per-bottle lock, and the helper
     * is then seeded with that exe's name and pid -- so the game the user
     * actually launches never gets its resolution held. steamsysinfo.exe was
     * doing exactly this (observed in the rig: the helper came up watching
     * "steamsysinfo.exe"). Any new Steam helper that appears with an .exe name
     * belongs here. */
    "steamsysinfo.exe", "steam_monitor.exe", "steamsetup.exe",
    "gldriverquery64.exe", "vulkandriverquery.exe", "vulkandriverquery64.exe",
    "streaming_client.exe",
    "wineboot.exe", "winedevice.exe", "explorer.exe", "services.exe",
    "plugplay.exe", "rpcss.exe", "conhost.exe", "cmd.exe", "start.exe",
    /* Whisky.app polls the bottle with `start.exe /exec tasklist.exe /FO CSV`
     * every few seconds to refresh its running-programs list.  argv is scanned
     * for the FIRST .exe token, which is tasklist.exe here, so leaving it off
     * this list made every poll look like a game launch: it claimed the
     * one-helper lock, forked a mode-fixup, held the game resolution and
     * released it a moment later.  With the app open the display flapped
     * between 2560x1440 and the desktop mode continuously (57 hold/release
     * cycles observed).  start.exe being listed does not help -- only the
     * first .exe in argv is compared. */
    "tasklist.exe",
    "winemenubuilder.exe", "rundll32.exe", "svchost.exe", "tabtip.exe",
    "wineconsole.exe", "winedbg.exe", "regedit.exe", "reg.exe",
    NULL
};

static int exe_basename(const char *path, char *out, size_t n)
{
    if (!path || !*path) return 0;
    const char *p = path, *last = path;
    for (; *p; p++)
        if (*p == '\\' || *p == '/') last = p + 1;
    if (!*last) return 0;
    size_t i = 0;
    for (; last[i] && i + 1 < n; i++)
        out[i] = (char)tolower((unsigned char)last[i]);
    out[i] = 0;
    return i > 0;
}

static int ends_with_exe(const char *s)
{
    size_t n = s ? strlen(s) : 0;
    return n > 4 && strcasecmp(s + n - 4, ".exe") == 0;
}

static void logf_maybe(const char *fmt, ...)
{
    const char *p = getenv("WINE_HUDWRAP_LOG");
    if (!p || !*p) return;
    FILE *f = fopen(p, "a");
    if (!f) return;
    va_list ap; va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fclose(f);
}

int main(int argc, char **argv)
{
    char base[PATH_MAX] = {0};
    int found = 0;
    for (int i = 0; i < argc && !found; i++)
        if (ends_with_exe(argv[i]) && exe_basename(argv[i], base, sizeof base))
            found = 1;

    int is_game = 0;
    if (found) {
        is_game = 1;
        for (int i = 0; kNoHud[i]; i++)
            if (strcmp(base, kNoHud[i]) == 0) { is_game = 0; break; }
    }

    if (is_game) {
        setenv("MTL_HUD_ENABLED", "1", 1);

        /* Hand the display mode to mode-fixup alone.
         *
         * Two writers cannot share one display.  mode-fixup switches the
         * display to the game's resolution for the game's lifetime; if wine
         * ALSO manages the mode, its setMode: runs afterwards, finds the game
         * resolution already current, and records THAT as the "original" mode
         * to restore -- so on exit it re-applies the game's mode straight over
         * mode-fixup's correct desktop restore (observed in the log as
         * "game set 2560x1440" immediately after "restored desktop").
         *
         * wine's own restore could not work for this display anyway: it uses
         * CGDisplaySetDisplayMode with a mode ref, which fails with
         * kCGErrorFailure (1000) for the scaled HiDPI desktop mode.
         *
         * With the flag set, winemac.drv leaves display modes alone entirely.
         * It still captures displays, so fullscreen still hides the menu bar
         * and Dock.  Trade-off: a game that changes resolution WHILE running
         * will no longer be honoured by the driver. */
        setenv("WHISKY_EXTERNAL_MODE_CONTROL", "1", 1);

        /* Cap the refresh rate wine picks for this game's fullscreen mode.
         *
         * ONE helper per bottle, not one per exec. The wine loader re-execs
         * many times while a game starts, and forking a helper each time
         * produced dozens of them: each watched a pid that died seconds later,
         * and -- worse -- the ones that started AFTER the game had switched
         * modes recorded 2560x1440@240 as "the desktop" and then defended that
         * as the mode to restore. The helper was holding 240Hz, not capping it.
         * Every one of them also ran a restore on teardown, which is what made
         * quitting take so long.
         *
         * A lock file makes the first helper the only helper. It is created
         * O_EXCL, holds the helper's pid, and is removed by the helper on exit;
         * a stale file whose pid is gone is reclaimed. The helper watches
         * WINESERVER, not this process: wineserver lives for the whole bottle
         * session and exits when the bottle does, which is exactly the lifetime
         * the display correction needs. */
        const char *cap = getenv("WHISKY_MAX_REFRESH_HZ");
        if (!cap) cap = kDefaultMaxRefreshHz;
        if (cap[0] && access(kModeFixupPath, X_OK) == 0) {
            int lock = open(kModeFixupLock, O_CREAT | O_EXCL | O_WRONLY, 0644);
            if (lock < 0 && errno == EEXIST) {
                /* Reclaim the lock if the recorded helper is gone. */
                int old = open(kModeFixupLock, O_RDONLY);
                if (old >= 0) {
                    char buf[16] = {0};
                    ssize_t n = read(old, buf, sizeof buf - 1);
                    close(old);
                    pid_t prev = (n > 0) ? (pid_t)atoi(buf) : 0;
                    if (prev <= 0 || kill(prev, 0) != 0) {
                        unlink(kModeFixupLock);
                        lock = open(kModeFixupLock, O_CREAT | O_EXCL | O_WRONLY, 0644);
                    }
                }
            }
            if (lock >= 0) {
                /* Watch wineserver: it spans the whole bottle session. */
                pid_t server = 0;
                FILE *ps = popen("pgrep -n wineserver", "r");
                if (ps) {
                    char line[32] = {0};
                    if (fgets(line, sizeof line, ps)) server = (pid_t)atoi(line);
                    pclose(ps);
                }
                if (server <= 0) server = getppid();   /* fallback */

                char server_pid[16];
                snprintf(server_pid, sizeof server_pid, "%d", (int)server);

                /* NOTE: a `--preapply-all` launch-intercept pre-apply used to
                 * run here.  It belongs to the GENERALIZED mode-fixup (the one
                 * with a per-exe resolution cache) and calling it against the
                 * shipped helper makes the helper exit 127 immediately, which
                 * leaves the game wedged at 0% CPU and never launching.  Keep
                 * the wrapper and the helper as a matched pair: do not
                 * reintroduce this without deploying the matching mode-fixup.
                 * The supervisor's adopt scan below covers the shipped case. */

        /* THIS process is the one that becomes the game: the wrapper
                 * execv()s the real loader, so the pid survives the exec. It is
                 * therefore both the lifetime handle for the 21:9 resolution
                 * hold (the display goes back the moment the game dies) and, by
                 * basename, the thing that decides WHICH game gets that
                 * treatment -- the helper only acts on a resolution it can
                 * resolve for this exe name. */
                char game_pid[16];
                snprintf(game_pid, sizeof game_pid, "%d", (int)getpid());

                pid_t child = fork();
                if (child == 0) {
                    int devnull = open("/dev/null", O_RDWR);
                    if (devnull >= 0) {
                        dup2(devnull, STDIN_FILENO);
                        dup2(devnull, STDOUT_FILENO);
                        if (devnull > STDERR_FILENO) close(devnull);
                    }
                    int logfd = open(kModeFixupLog,
                                     O_WRONLY | O_CREAT | O_APPEND, 0644);
                    if (logfd >= 0) {
                        dup2(logfd, STDERR_FILENO);
                        if (logfd > STDERR_FILENO) close(logfd);
                    }
                    /* Drop any dyld injection before exec'ing the helper. It is
                     * not wine, it does not need a debug/probe dylib, and an
                     * injected dylib built for the OTHER architecture makes dyld
                     * refuse to start it at all -- so a rig run with a probe
                     * injected into wine silently loses the refresh cap and the
                     * resolution hold. Costs nothing when nothing is injected. */
                    unsetenv("DYLD_INSERT_LIBRARIES");
                    unsetenv("DYLD_FORCE_FLAT_NAMESPACE");
                    /* argv[0] is a bare "mode-fixup" on purpose -- the helper
                     * resolves its own path, and passing the real path here
                     * would only invite someone to trust it. */
                    execl(kModeFixupPath, "mode-fixup", cap, server_pid,
                          kModeFixupLock, game_pid, base, (char *)NULL);
                    _exit(127);
                } else if (child > 0) {
                    char buf[16];
                    int n = snprintf(buf, sizeof buf, "%d\n", (int)child);
                    ssize_t unused = write(lock, buf, (size_t)n);
                    (void)unused;
                }
                close(lock);
            }
        }
    } else {
        unsetenv("MTL_HUD_ENABLED");
    }

    /* D3DMetal's HUD block -- the "Game Porting Toolkit <ver>" header plus its
     * per-frame rows (Draw / Clear Resource / Copy Resource) -- is off by
     * request: it is clutter during play and carries no Game Mode line.
     *
     * Cleared in BOTH branches, not just left unset. Steam spawns the games and
     * they inherit its environment, so a value picked up anywhere upstream
     * would otherwise ride down into the game and put the block back.
     *
     * To re-enable for a profiling session, change this to
     * setenv("D3DM_SHOW_HUD_STATS", "1", 1) in the is_game branch and re-run
     * install-hud-wrapper.sh. */
    /* Explicitly "0", not unset: the GPTK block still rendered with the
     * variable absent from the game env (verified on DS3 via KERN_PROCARGS2),
     * so unsetting is not the lever -- D3DMetal defaults it on. */
    setenv("D3DM_SHOW_HUD_STATS", "0", 1);

    /* Resolve the real loader beside us. realpath() first: we may have been
     * invoked through bin/wine64, whose dirname is bin/ where no wine-real is. */
    char self[PATH_MAX]; uint32_t sz = sizeof self;
    if (_NSGetExecutablePath(self, &sz) != 0) {
        fprintf(stderr, "wine-hudwrap: cannot resolve own path\n");
        return 127;
    }
    char resolved[PATH_MAX];
    if (!realpath(self, resolved)) snprintf(resolved, sizeof resolved, "%s", self);
    char dircopy[PATH_MAX]; snprintf(dircopy, sizeof dircopy, "%s", resolved);
    char real[PATH_MAX];
    snprintf(real, sizeof real, "%s/wine-real", dirname(dircopy));

    /* Game Mode: exec a loader that lives inside a games-category .app.
     *
     * gamepolicyd reads the Info.plist of the bundle containing the RUNNING
     * BINARY - no LaunchServices launch required. Verified live: a directly
     * exec'd binary inside a games-category .app is picked up immediately as
     *   "Found game GameProcess(..., labelReason=Plist category type)".
     *
     * So for game processes we simply exec the bundle's copy of the loader
     * instead of the normal one. Process lineage is untouched, which keeps
     * Steam's tracking and overlay intact - unlike an `open`-based handoff,
     * which detaches the process (and with -W never execs at all).
     *
     * The bundle's MacOS/ dir symlinks the rest of x86_64-unix/, so the
     * loader still resolves ntdll.so beside itself. */
    /* Default the game-loader path to the bundle beside the engine, so the
     * feature works without anyone having to export WINE_GAME_LOADER. */
    char gl_default[PATH_MAX];
    {
        char d2[PATH_MAX]; snprintf(d2, sizeof d2, "%s", resolved);
        char *ud = dirname(d2);                 /* .../lib/wine/x86_64-unix */
        char d3[PATH_MAX]; snprintf(d3, sizeof d3, "%s", ud);
        snprintf(gl_default, sizeof gl_default,
                 "%s/WhiskyGame.app/Contents/MacOS/wine", dirname(d3));
    }
    const char *game_loader = getenv("WINE_GAME_LOADER");
    if (!game_loader || !*game_loader) game_loader = gl_default;
    if (is_game && game_loader && *game_loader) {
        struct stat gst;
        if (stat(game_loader, &gst) == 0 && (gst.st_mode & S_IXUSR)) {
            logf_maybe("pid=%d -> game loader %s\n", getpid(), game_loader);
            execv(game_loader, argv);
            /* fall through to the normal loader if that failed */
            logf_maybe("pid=%d game loader exec FAILED, using default\n", getpid());
        } else {
            /* Losing this is silent otherwise, and its only visible symptom is
             * "Game Mode is off" -- which is indistinguishable from Game Mode
             * simply not qualifying. An engine update replaces Libraries/ and
             * takes the bundle with it (see the skill: re-run
             * make-game-bundle.sh after any engine change). Say so on stderr,
             * once per process, so the reason is in the launch log. */
            fprintf(stderr, "wine-hudwrap: game bundle missing (%s) -- this game will"
                            " NOT be recognised as a game (no Game Mode)."
                            " Run make-game-bundle.sh.\n", game_loader);
        }
    }

    execv(real, argv);
    perror("wine-hudwrap: execv");
    return 127;
}
