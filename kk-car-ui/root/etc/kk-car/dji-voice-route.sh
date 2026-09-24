#!/bin/sh
# Start the module's temporary D4/UAC route only after a voice call is active.
# The module-side helper is a separately verified runtime dependency; this
# script never changes USB composition, firmware, SIM or network settings.
set -eu
marker=/tmp/kk-car-voice-ready
health=/etc/kk-car/dji-voice-health.sh

case "${1:-}" in
    start)
        "$health" prepared || exit 1
        if "$health" active; then
            : > "$marker"
            exit 0
        fi
        # USB audio_enable may briefly re-enumerate after launch. Verify the
        # resulting state rather than trusting the ADB command's reply alone.
        adb -d shell /tmp/kkcar-voice/start-route.sh >/dev/null 2>&1 || true
        n=0
        while [ "$n" -lt 60 ]; do
            if "$health" active; then
                : > "$marker"
                exit 0
            fi
            n=$((n + 1))
            # OpenWrt's BusyBox sleep rejects fractions; ucode supports them.
            ucode -e 'sleep(0.1)' >/dev/null 2>&1 || sleep 1
        done
        rm -f "$marker"
        logger -t kk-car-voice "route start timed out; host_audio=$(test -e /proc/asound/Baiwang && echo yes || echo no)" 2>/dev/null || true
        exit 1
        ;;
    stop)
        rm -f "$marker"
        # Module script validates PID, process start time and argv before
        # sending SIGTERM, then rolls back the voice mixer route.
        n=0
        while [ "$n" -lt 6 ]; do
            if adb -d shell /tmp/kkcar-voice/stop-route.sh >/dev/null 2>&1; then
                exit 0
            fi
            n=$((n + 1))
            ucode -e 'sleep(0.5)' >/dev/null 2>&1 || sleep 1
        done
        exit 1
        ;;
    *) exit 2 ;;
esac
