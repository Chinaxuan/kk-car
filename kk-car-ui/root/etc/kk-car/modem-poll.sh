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
active= timer= deadline=
cleanup() {
    [ -z "$active" ] || kill "$active" 2>/dev/null
    [ -z "$timer" ] || kill "$timer" 2>/dev/null
    [ -z "$deadline" ] || kill "$deadline" 2>/dev/null
    rm -f "$lock/pid" /tmp/kk-car-modem.raw
    rmdir "$lock" 2>/dev/null
}
trap cleanup EXIT
# Also bounds driver/tool failures that ignore their own per-request timeout.
trap 'ucode /etc/kk-car/modem-parse.uc 124; exit 124' TERM INT
(sleep 30; kill -TERM $$ 2>/dev/null) & deadline=$!
bounded() {
    seconds="$1"; shift
    "$@" & active=$!
    (sleep "$seconds"; kill "$active" 2>/dev/null; sleep 1; kill -9 "$active" 2>/dev/null) & timer=$!
    wait "$active"; rc=$?
    kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
    active= timer=
    return "$rc"
}
bounded 27 sh /etc/kk-car/modem-qmi-read.sh > /tmp/kk-car-modem.raw 2>/dev/null
rc=$?
if [ "$rc" -eq 3 ]; then
    # Only a validated private default gateway on logical WAN can be an ADB
    # target. A public/carrier-assigned gateway must never receive ADB probes.
    gateway=$(bounded 2 ubus call network.interface.wan status 2>/dev/null |
        ucode -e 'import { readfile } from "fs";
            let s; try { s=json(readfile("/dev/stdin")); } catch(e) { exit(1); }
            for (let r in s.route || []) {
                if (r.target != "0.0.0.0" || +r.mask != 0) continue;
                let p=split(r.nexthop || "", ".");
                if (length(p)!=4) continue;
                let valid=true;
                for (let n in p) if (!match(n,/^[0-9]{1,3}$/) || +n>255) valid=false;
                if (valid && (+p[0]==10 || (+p[0]==172 && +p[1]>=16 && +p[1]<=31) || (+p[0]==192 && +p[1]==168))) { print(r.nexthop); break; }
            }' 2>/dev/null)
    [ -n "$gateway" ] || gateway=192.168.0.1
    target="$gateway:5555"
    if ! bounded 3 adb -s "$target" get-state 2>/dev/null | grep -q '^device'; then
        bounded 8 adb connect "$target" >/dev/null 2>&1
    fi
    printf 'transport=ADB\nmanagement_ip=%s\n' "$gateway" > /tmp/kk-car-modem.raw
    bounded 10 adb -s "$target" shell "$(cat /etc/kk-car/modem-read.sh)" >> /tmp/kk-car-modem.raw 2>/dev/null
    rc=$?
fi
ucode /etc/kk-car/modem-parse.uc "$rc"
[ "$(jsonfilter -i /tmp/kk-car-modem.json -e '@.online')" = true ]
