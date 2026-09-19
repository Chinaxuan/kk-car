#!/bin/sh
# Numeric target and explicit XFRM interface: never retry over the physical WAN.
umask 077
trap 'rm -f /tmp/kk-car-vpn-ping.raw /tmp/kk-car-vpn-ping.json.new; exit' TERM INT
while :; do
    read started rest < /proc/uptime
    started=${started%%.*}
    : > /tmp/kk-car-vpn-ping.raw
    reason=probe
    if [ ! -e /var/run/charon.pid ] || ! ip -4 addr show dev ikecar 2>/dev/null | grep -q 'inet '; then
        reason=vpn_down
    else
        # At most 7 seconds per batch, including an unresponsive peer.
        ping -4 -I ikecar -c 3 -W 2 -w 7 10.8.8.8 > /tmp/kk-car-vpn-ping.raw 2>&1
    fi
    ucode /etc/kk-car/vpn-ping-write.uc "$reason"
    ucode /etc/kk-car/history-write.uc
    read ended rest < /proc/uptime
    ended=${ended%%.*}
    delay=$((10 - ended + started))
    [ "$delay" -ge 1 ] && [ "$delay" -le 10 ] || delay=1
    sleep "$delay" &
    wait $!
done
