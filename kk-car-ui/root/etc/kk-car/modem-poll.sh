#!/bin/sh
umask 077
if [ "$1" != once ]; then
    while :; do "$0" once; sleep 30; done
fi
lock=/tmp/kk-car-modem-lock
if ! mkdir "$lock" 2>/dev/null; then
    owner=$(cat "$lock/pid" 2>/dev/null)
    # An empty lock may belong to a collector that is still starting.
    [ -z "$owner" ] && exit 2
    kill -0 "$owner" 2>/dev/null && exit 2
    rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null
    mkdir "$lock" 2>/dev/null || exit 2
fi
echo $$ > "$lock/pid"
trap 'rm -f "$lock/pid" /tmp/kk-car-modem.raw; rmdir "$lock" 2>/dev/null' EXIT
bounded() {
    seconds="$1"; shift
    "$@" & child=$!
    (sleep "$seconds"; kill "$child" 2>/dev/null; sleep 1; kill -9 "$child" 2>/dev/null) & timer=$!
    wait "$child"; rc=$?
    kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
    return "$rc"
}
if ! bounded 3 adb -s 192.168.0.1:5555 get-state 2>/dev/null | grep -q '^device'; then
    bounded 8 adb connect 192.168.0.1:5555 >/dev/null 2>&1
fi
bounded 10 adb -s 192.168.0.1:5555 shell "$(cat /etc/kk-car/modem-read.sh)" > /tmp/kk-car-modem.raw 2>/dev/null
rc=$?
ucode /etc/kk-car/modem-parse.uc "$rc"
[ "$(jsonfilter -i /tmp/kk-car-modem.json -e '@.online')" = true ]
