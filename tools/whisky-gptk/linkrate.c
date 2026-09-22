// linkrate.c — measure the ACTUAL display link rate, not the mode's nominal rate.
//
// WHY: every other available reading reports the mode's NOMINAL refresh
// (CGDisplayCopyDisplayMode, CGDisplayModeGetRefreshRate) or a CAPABILITY
// (SLSIsDisplayModeVRR, IORegistry SupportsVariableRefreshRate).  None of them
// say whether the link is actually running at a variable rate right now.
//
// CVDisplayLink fires once per display refresh, so the INTERVAL between
// callbacks is the OS's own view of the live link rate:
//     240Hz -> ~4.17 ms      60Hz -> ~16.67 ms
// If VRR engages, that interval must move with the frame rate.  If it stays
// pinned at the max while a 60fps game runs, the compositor is presenting at
// max rate and no variable refresh is happening.
//
// Runs as its own process, so it can observe during gameplay without the user
// touching anything, and without altering the state being measured.
//
// Usage: linkrate [seconds] [output-file]
#include <ApplicationServices/ApplicationServices.h>
#include <CoreVideo/CoreVideo.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static FILE *g_out;
static double g_min = 1e9, g_max = 0, g_sum = 0;
static unsigned long g_n = 0;
static double g_last = 0;

static CVReturn tick(CVDisplayLinkRef link, const CVTimeStamp *now,
                     const CVTimeStamp *outputTime, CVOptionFlags flagsIn,
                     CVOptionFlags *flagsOut, void *ctx)
{
    /* outputTime->hostTime is the host clock time the frame will be shown */
    double t = (double)outputTime->hostTime / CVGetHostClockFrequency();
    if (g_last > 0) {
        double dt = t - g_last;
        if (dt > 0) {
            g_sum += dt; g_n++;
            if (dt < g_min) g_min = dt;
            if (dt > g_max) g_max = dt;
            if (g_out) {
                struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
                fprintf(g_out, "%.6f %.6f %.2f\n", ts.tv_sec + ts.tv_nsec / 1e9,
                        dt, 1.0 / dt);
                fflush(g_out);
            }
        }
    }
    g_last = t;
    return kCVReturnSuccess;
}

int main(int argc, char **argv)
{
    double seconds = (argc > 1) ? atof(argv[1]) : 30.0;
    const char *path = (argc > 2) ? argv[2] : "/tmp/linkrate.log";

    CGDirectDisplayID d = CGMainDisplayID();
    printf("display %u  (nominal per CoreGraphics below -- that is the number\n"
           "that lies; the measured interval is what matters)\n", d);
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
    if (m) {
        printf("  CG nominal: %zux%zu @%.0fHz\n",
               CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
               CGDisplayModeGetRefreshRate(m));
        CGDisplayModeRelease(m);
    }

    g_out = fopen(path, "w");
    if (g_out) { fprintf(g_out, "# epoch interval_s measured_hz\n"); fflush(g_out); }

    CVDisplayLinkRef link;
    if (CVDisplayLinkCreateWithCGDisplay(d, &link) != kCVReturnSuccess) {
        fprintf(stderr, "cannot create display link\n");
        return 1;
    }
    CVDisplayLinkSetOutputCallback(link, tick, NULL);
    CVDisplayLinkStart(link);

    printf("measuring for %.0fs -> %s\n", seconds, path);
    sleep((unsigned)seconds);

    CVDisplayLinkStop(link);
    CVDisplayLinkRelease(link);
    if (g_out) fclose(g_out);

    if (g_n) {
        printf("samples %lu  interval min %.3fms  max %.3fms  mean %.3fms\n",
               g_n, g_min * 1000, g_max * 1000, (g_sum / g_n) * 1000);
        printf("measured rate: mean %.1fHz  (range %.1f - %.1fHz)\n",
               1.0 / (g_sum / g_n), 1.0 / g_max, 1.0 / g_min);
        printf("\nINTERPRETATION: if this is pinned near the mode's max rate\n"
               "while a 60fps game runs, VRR is NOT engaging -- the compositor\n"
               "is presenting at max.  If it tracks the game's rate or varies,\n"
               "VRR is working and only the monitor's OSD is misleading.\n");
    } else {
        printf("no samples\n");
    }
    return 0;
}
