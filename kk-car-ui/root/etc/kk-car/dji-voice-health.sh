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
result=$(adb -d shell '
    file=/run/kkcar-voice-route.pid
    test -s "$file" || exit 1
    read pid expected < "$file" || exit 1
    case "$pid:$expected" in *[!0-9:]*|:*|*:) exit 1;; esac
    test "$(cut -d " " -f 22 "/proc/$pid/stat" 2>/dev/null)" = "$expected" || exit 1
    test "$(tr "\000" "\n" < "/proc/$pid/cmdline" 2>/dev/null | sed -n "1p")" = /tmp/kkcar-voice/mavo-pcm-bridge.armv7 || exit 1
    tr "\000" "\n" < "/proc/$pid/cmdline" 2>/dev/null | grep -qx -- --voice-route-session || exit 1
    grep -q "VoLTE route session active on hw:0,4" /run/kkcar-voice-route.log || exit 1
    test "$(cat /sys/class/android_usb/f_audio/audio_enable 2>/dev/null)" = 1 || exit 1
    grep -q "^state: RUNNING" /proc/asound/card0/pcm4p/sub0/status || exit 1
    grep -q "^state: RUNNING" /proc/asound/card0/pcm4c/sub0/status || exit 1
    echo ready' 2>/dev/null | tr -d '\r')
test "$result" = ready
