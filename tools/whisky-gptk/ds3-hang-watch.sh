#!/bin/bash
# ds3-hang-watch.sh — always-on watcher for the DS3 hang-on-quit fault.
#
# THE FAULT (observed 2026-09-21): the user quits Dark Souls III, the game
# window goes away, but DarkSoulsIII.exe stays alive.  Steam keeps reporting
# the game as running and mode-fixup keeps holding the display resolution,
# because from its point of view the game is still there.  The process
# ignores SIGTERM and only dies to SIGKILL.
#
# Evidence was destroyed the first time by killing it immediately, so this
# watcher exists to capture the wedged state BEFORE anyone kills anything.
#
# IT NEVER KILLS, SIGNALS, OR LAUNCHES ANYTHING.  It only observes and
# writes files.  All of its tools are sudo-free.
#
# Trigger: DarkSoulsIII.exe alive with near-zero CPU for a sustained window.
# A live DS3 renders continuously (tens to hundreds of % CPU); a wedged one
# parks its threads and drops to ~0.  One capture per pid, so a long wedge
# does not spam.

set -uo pipefail

EVIDENCE="$HOME/whisky-gptk-writeup/ds3-hang-evidence"
LOG="$EVIDENCE/watch.log"
GAME_MATCH='DarkSoulsIII.exe'

POLL_SECONDS=3
IDLE_CPU_THRESHOLD=5      # percent; below this counts as "not rendering"
IDLE_SAMPLES_TO_TRIGGER=7 # ~21s of sustained idle before we believe it

mkdir -p "$EVIDENCE"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# pid -> consecutive idle sample count
declare -a IDLE_PIDS=()
declare -a IDLE_HITS=()
declare -a CAPTURED=()

idx_of() {
    local want="$1" i
    for i in "${!IDLE_PIDS[@]}"; do
        [ "${IDLE_PIDS[$i]}" = "$want" ] && { echo "$i"; return 0; }
    done
    return 1
}

already_captured() {
    local want="$1" p
    for p in "${CAPTURED[@]:-}"; do [ "$p" = "$want" ] && return 0; done
    return 1
}

capture() {
    local pid="$1" cpu="$2"
    local stamp; stamp="$(date '+%Y%m%d-%H%M%S')"
    local dir="$EVIDENCE/hang-$stamp-pid$pid"
    mkdir -p "$dir"

    log "CAPTURE pid=$pid cpu=$cpu -> $dir"

    # 1. The main artifact: where every thread is parked.  This is the one
    #    that answers "what is it waiting on".
    sample "$pid" 5 -file "$dir/sample.txt" >/dev/null 2>&1 \
        || log "  sample failed (pid gone?)"

    # 2. Full process table for the bottle: what else is still alive, and
    #    when each started.  Wine processes report WINDOWS paths, so match
    #    broadly rather than on unix paths.
    ps ax -o pid,ppid,lstart,%cpu,%mem,state,command > "$dir/ps-all.txt" 2>&1
    ps ax -o pid,ppid,lstart,%cpu,state,command \
        | grep -iE 'DarkSouls|steam|wine|explorer\.exe|services\.exe|winedevice|plugplay|rpcss|conhost' \
        | grep -v grep > "$dir/ps-bottle.txt" 2>&1

    # 3. Thread-level state for the wedged pid.
    ps -M "$pid" > "$dir/threads.txt" 2>&1

    # 4. Open files / sockets can show a stuck server round-trip.
    lsof -p "$pid" > "$dir/lsof.txt" 2>&1

    # 5. Display state — the hang leaves the resolution held, so record
    #    what the display is actually on at the moment of the wedge.
    /usr/bin/python3 -c "
import ctypes, ctypes.util
cg = ctypes.CDLL(ctypes.util.find_library('CoreGraphics'))
cg.CGMainDisplayID.restype = ctypes.c_uint32
cg.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p
cg.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
for f in ('CGDisplayModeGetWidth','CGDisplayModeGetHeight','CGDisplayModeGetPixelWidth','CGDisplayModeGetPixelHeight'):
    getattr(cg,f).restype = ctypes.c_size_t; getattr(cg,f).argtypes = [ctypes.c_void_p]
cg.CGDisplayModeGetRefreshRate.restype = ctypes.c_double
cg.CGDisplayModeGetRefreshRate.argtypes = [ctypes.c_void_p]
d = cg.CGMainDisplayID(); m = cg.CGDisplayCopyDisplayMode(d)
print('point %dx%d pixel %dx%d @%.0fHz' % (
    cg.CGDisplayModeGetWidth(m), cg.CGDisplayModeGetHeight(m),
    cg.CGDisplayModeGetPixelWidth(m), cg.CGDisplayModeGetPixelHeight(m),
    cg.CGDisplayModeGetRefreshRate(m)))
" > "$dir/display.txt" 2>&1

    # 6. mode-fixup's own log: is it still holding, and does it think the
    #    game is alive?
    cp /tmp/mode-fixup.log "$dir/mode-fixup.log" 2>/dev/null

    # 7. Recent system-side view of the game process and the window server.
    /usr/bin/log show --last 3m --predicate 'process == "gamepolicyd"' \
        > "$dir/gamepolicyd.txt" 2>&1
    /usr/bin/log show --last 3m --predicate 'eventMessage CONTAINS[c] "DarkSouls"' \
        > "$dir/syslog-darksouls.txt" 2>&1

    # 8. Any crash/hang report macOS produced on its own.
    ls -la "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null \
        | grep -iE 'darksouls|wine|steam' > "$dir/diagnostic-reports.txt" 2>&1

    {
        echo "pid:              $pid"
        echo "cpu at trigger:   $cpu"
        echo "captured:         $(date)"
        echo "idle samples:     $IDLE_SAMPLES_TO_TRIGGER x ${POLL_SECONDS}s"
        echo
        echo "The process was ALIVE and NOT killed by this watcher."
        echo "If it is still wedged, it is safe to inspect further before killing."
    } > "$dir/README.txt"

    log "CAPTURE complete -> $dir"
}

log "watcher started (poll ${POLL_SECONDS}s, trigger <${IDLE_CPU_THRESHOLD}% for $((POLL_SECONDS*IDLE_SAMPLES_TO_TRIGGER))s)"

while true; do
    # Wine reports Windows paths, so match the exe name, not a unix path.
    while read -r pid cpu; do
        [ -z "${pid:-}" ] && continue

        # integer compare without bc
        cpu_int="${cpu%%.*}"; [ -z "$cpu_int" ] && cpu_int=0

        if [ "$cpu_int" -lt "$IDLE_CPU_THRESHOLD" ]; then
            if i="$(idx_of "$pid")"; then
                IDLE_HITS[$i]=$(( ${IDLE_HITS[$i]} + 1 ))
            else
                IDLE_PIDS+=("$pid"); IDLE_HITS+=(1); i=$(( ${#IDLE_PIDS[@]} - 1 ))
            fi

            if [ "${IDLE_HITS[$i]}" -ge "$IDLE_SAMPLES_TO_TRIGGER" ] \
               && ! already_captured "$pid"; then
                CAPTURED+=("$pid")
                capture "$pid" "$cpu"
            fi
        else
            # rendering again -> reset its idle streak
            if i="$(idx_of "$pid")"; then IDLE_HITS[$i]=0; fi
        fi
    done < <(ps ax -o pid,%cpu,command | grep -F "$GAME_MATCH" | grep -v grep | awk '{print $1, $2}')

    sleep "$POLL_SECONDS"
done
