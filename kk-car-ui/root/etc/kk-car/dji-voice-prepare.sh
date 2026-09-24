#!/bin/sh
# Rebuild the temporary modem-side audio environment after a modem reboot.
# Runtime binaries are pinned and stored privately on the Pi SD card. Nothing
# is flashed to the modem and the QMI/USB composition is never changed here.
set -eu
dir=/etc/kk-car/private/voice-runtime
remote=/tmp/kkcar-voice

/etc/kk-car/dji-voice-health.sh prepared && exit 0
test -c /dev/ttyUSB2 && test -e /proc/asound/Baiwang || exit 1
test "$(adb -d shell uname -r 2>/dev/null | tr -d '\r')" = 3.18.44 || exit 1

check() {
    test -f "$dir/$1" || exit 1
    test "$(sha256sum "$dir/$1" | cut -d ' ' -f 1)" = "$2" || exit 1
}
check qdc507_aprv3.ko 3d82d3dec4f1e323201bba87156df9d41438e08314097353f2607f9117211d4a
check qdc507_voice.ko ed3821682d5309969a01c764192c83feff9669c61ef237c69475cd1619cf296c
check mavo-pcm-bridge.armv7 88d47c15e61d1428a59c821fed804c2e6490e82859a085062f21966b58d167fc

adb -d shell "mkdir -p $remote && chmod 700 $remote" >/dev/null
for name in qdc507_aprv3.ko qdc507_voice.ko mavo-pcm-bridge.armv7; do
    adb -d push "$dir/$name" "$remote/$name" >/dev/null 2>&1
done
adb -d push /etc/kk-car/module-voice-calibrate.sh "$remote/calibrate.sh" >/dev/null 2>&1
adb -d push /etc/kk-car/module-voice-start.sh "$remote/start-route.sh" >/dev/null 2>&1
adb -d push /etc/kk-car/module-voice-stop.sh "$remote/stop-route.sh" >/dev/null 2>&1
adb -d shell "chmod 700 $remote/*" >/dev/null
adb -d shell "grep -q '^qdc507_aprv3 ' /proc/modules || insmod $remote/qdc507_aprv3.ko" >/dev/null
adb -d shell "grep -q '^qdc507_voice ' /proc/modules || insmod $remote/qdc507_voice.ko" >/dev/null
adb -d shell "$remote/calibrate.sh" >/dev/null
adb -d shell "$remote/mavo-pcm-bridge.armv7 --check" >/dev/null
/etc/kk-car/dji-voice-health.sh prepared
