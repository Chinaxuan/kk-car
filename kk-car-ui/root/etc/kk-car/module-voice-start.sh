#!/bin/sh
set -eu
helper=/tmp/kkcar-voice/mavo-pcm-bridge.armv7
test -x "$helper" && test -c /dev/snd/pcmC0D4p && test -c /dev/snd/pcmC0D4c
nohup "$helper" --voice-route-session --verbose </dev/null >/run/kkcar-voice-route.log 2>&1 &
pid=$!
start=$(cut -d ' ' -f 22 "/proc/$pid/stat" 2>/dev/null || true)
case "$pid:$start" in *[!0-9:]*|:*|*:) exit 2;; esac
printf '%s %s\n' "$pid" "$start" > /run/kkcar-voice-route.pid
echo 'Voice route launched'
