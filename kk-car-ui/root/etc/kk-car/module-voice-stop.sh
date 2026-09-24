#!/bin/sh
# Runs inside the QDC507 root shell. Stop only our own temporary audio helper.
set -eu
file=/run/kkcar-voice-route.pid
helper=/tmp/kkcar-voice/mavo-pcm-bridge.armv7
if test -s "$file"; then
    read pid expected < "$file"
    case "$pid:$expected" in *[!0-9:]*|:*|*:) exit 2 ;; esac
    actual=$(cut -d ' ' -f 22 "/proc/$pid/stat" 2>/dev/null || true)
    argv=$(tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)
    if test "$actual" = "$expected" && printf '%s\n' "$argv" | grep -qx "$helper" &&
       printf '%s\n' "$argv" | grep -qx -- '--voice-route-session'; then
        kill -TERM "$pid"
        n=0
        while kill -0 "$pid" 2>/dev/null && test "$n" -lt 50; do
            sleep 0.1
            n=$((n + 1))
        done
        kill -0 "$pid" 2>/dev/null && exit 3
    fi
    rm -f "$file"
fi
echo 0 > /sys/class/android_usb/f_audio/audio_enable
if test -p /run/voc_svr; then
    printf 'T\n' > /run/voc_svr
    printf 'T\n' > /run/voc_svr
    printf 'B\n' > /run/voc_svr
fi
