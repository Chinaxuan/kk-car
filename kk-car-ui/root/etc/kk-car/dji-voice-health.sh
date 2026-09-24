#!/bin/sh
# Read-only checks for the prepared modem audio resources and the per-call route.
card=$(readlink -f /proc/asound/Baiwang 2>/dev/null | sed -n 's|.*/card\([0-9][0-9]*\)$|\1|p')
case "$card" in ''|*[!0-9]*) exit 1 ;; esac
test -c "/dev/snd/pcmC${card}D0c" && test -c "/dev/snd/pcmC${card}D0p" || exit 1
command -v adb >/dev/null 2>&1 || exit 1
if [ "${1:-active}" = prepared ]; then
    result=$(adb -d shell 'test -c /dev/snd/pcmC0D4c && test -c /dev/snd/pcmC0D4p && grep -q "^qdc507_voice " /proc/modules && grep -q "^qdc507_aprv3 " /proc/modules && test -x /tmp/kkcar-voice/mavo-pcm-bridge.armv7 && echo ready' 2>/dev/null | tr -d '\r')
    test "$result" = ready
    exit
fi
result=$(adb -d shell 'test "$(cat /sys/class/android_usb/f_audio/audio_enable 2>/dev/null)" = 1 && grep -q "^state: RUNNING" /proc/asound/card0/pcm4p/sub0/status && grep -q "^state: RUNNING" /proc/asound/card0/pcm4c/sub0/status && ps | grep -q "[m]avo-pcm-bridge.armv7 --voice-route-session" && echo ready' 2>/dev/null | tr -d '\r')
test "$result" = ready
