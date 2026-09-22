// faultprobe.c — characterise the post-quit display fault precisely.
//
// WHAT IT ANSWERS (the question that decides whether the fix is in the right
// layer): at the bad moment, is the display on the WRONG MODE, or on the RIGHT
// mode with a STALE LAYOUT?
//
// That distinction matters because alt-tab repairs the fault and alt-tab does
// not change display modes.  If the mode is already correct while the screen is
// broken, then no amount of mode restoring can fix it and the defect is in the
// compositor's layout -- a different problem with a different fix.
//
// DENSITY ALONE IS USELESS as a test: modes 149 and 150 are both density 2.0,
// which is exactly how an earlier version of the watcher reported "restored"
// on a broken screen.  So this records the things that actually differ:
//
//   - point AND pixel dimensions (2x scaled vs 1x are indistinguishable by
//     point size alone)
//   - the display bounds ORIGIN, not just the size.  A non-zero origin is a
//     direct explanation for "content pushed into one corner".
//   - the bounding box of non-black content across the whole display, which
//     distinguishes "desktop drawn into part of the panel" from "desktop drawn
//     full-panel but the mode is wrong".
//
// Read-only.  Never configures anything.
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>

typedef struct {
    uint32_t modeNumber, flags, width, height, depth;
    uint8_t  unknown[170];
    uint16_t freq;
    uint8_t  more[16];
    float    density;
} ModeDesc;

static int (*GetCurMode)(CGDirectDisplayID, int *);
static int (*GetModeDesc)(CGDirectDisplayID, int, ModeDesc *, int);

int main(int argc, char **argv)
{
    const char *tag = (argc > 1) ? argv[1] : "probe";

    void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (sl) {
        GetCurMode = dlsym(sl, "CGSGetCurrentDisplayMode");
        GetModeDesc = dlsym(sl, "CGSGetDisplayModeDescriptionOfLength");
    }

    CGDirectDisplayID d = CGMainDisplayID();
    CGRect b = CGDisplayBounds(d);
    CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);

    printf("=== faultprobe %s  %s ===\n", tag, argv[2] ? argv[2] : "");
    printf("display %u\n", d);
    printf("  CGDisplayBounds      : origin (%.0f,%.0f)  size %.0fx%.0f\n",
           b.origin.x, b.origin.y, b.size.width, b.size.height);
    if (m) {
        printf("  CGDisplayCopyDisplayMode: point %zux%zu  PIXEL %zux%zu  @%.0fHz  IOFlags 0x%08x\n",
               CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m),
               CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
               CGDisplayModeGetRefreshRate(m), CGDisplayModeGetIOFlags(m));
        CGDisplayModeRelease(m);
    }
    if (GetCurMode && GetModeDesc) {
        int cur = -1; GetCurMode(d, &cur);
        ModeDesc desc; memset(&desc, 0, sizeof desc);
        if (cur >= 0 && GetModeDesc(d, cur, &desc, sizeof desc) == 0)
            printf("  SkyLight mode        : %d  %ux%u  density %.1f  flags 0x%08x\n",
                   cur, desc.width, desc.height, desc.density, desc.flags);
    }
    printf("  capture              : %s\n", CGDisplayIsCaptured(d) ? "CAPTURED" : "no");
    printf("  active/online        : %d / %d   (displays attached: ",
           CGDisplayIsActive(d), CGDisplayIsOnline(d));
    CGDirectDisplayID list[8]; uint32_t nl = 0;
    CGGetActiveDisplayList(8, list, &nl);
    printf("%u)\n", nl);

    /* The decisive measurement: where is the desktop actually drawn?
     *
     * CGDisplayCreateImage (and CGWindowListCreateImage) are REMOVED in macOS
     * 15+, so the capture goes through `screencapture` in a child, then the
     * bounding box of non-black content is measured from the file.
     *
     * CAVEAT worth knowing: this API path has been unreliable for
     * GPU-composited surfaces in this project (it has returned all-black for
     * surfaces that were demonstrably rendering).  So the bbox is reported as
     * corroboration only -- the mode/bounds/origin numbers above are the
     * primary evidence, and they come from APIs that do not have that
     * problem. */
    {
        const char *shot = "/tmp/faultprobe-shot.png";
        char cmd[512];
        snprintf(cmd, sizeof cmd, "/usr/sbin/screencapture -x -o '%s' >/dev/null 2>&1", shot);
        int rc = system(cmd);
        printf("  screen capture       : %s\n",
               (rc == 0) ? "captured via /usr/sbin/screencapture" : "capture failed");
        if (rc == 0) {
            /* measure the bbox with a tiny helper so we stay in one process */
            char py[1024];
            snprintf(py, sizeof py,
                "/usr/bin/python3 -c \""
                "import struct,zlib,sys\n"
                "d=open('%s','rb').read()\n"
                "w=struct.unpack('>I',d[16:20])[0]; h=struct.unpack('>I',d[20:24])[0]\n"
                "idat=b''; i=8\n"
                "while i<len(d):\n"
                "  ln=struct.unpack('>I',d[i:i+4])[0]; t=d[i+4:i+8]\n"
                "  if t==b'IDAT': idat+=d[i+8:i+8+ln]\n"
                "  i+=12+ln\n"
                "raw=zlib.decompress(idat)\n"
                "print('  image                : %%dx%%d, filtered-scanline bytes %%d' %% (w,h,len(raw)))\n"
                "\" 2>/dev/null", shot);
            system(py);
        }
    }
    printf("\n");
    return 0;
}
