#!/bin/sh
# Numeric target and explicit tunnel interface: never retry over the physical WAN.
umask 077
trap 'rm -f /tmp/kk-car-vpn-ping.raw /tmp/kk-car-vpn-ping.json.new; exit' TERM INT
while :; do
    read started rest < /proc/uptime
    started=${started%%.*}
    : > /tmp/kk-car-vpn-ping.raw
    reason=probe
    device=$(uci -q get pbr.kk_global.interface)
    case "$device" in ovpncar|wgcar) ;; *) device=ovpncar ;; esac
    running=1
    if [ "$device" = ovpncar ]; then
        pidof openvpn >/dev/null 2>&1 || running=0
    fi
    if [ "$running" != 1 ] || ! ip -4 addr show dev "$device" 2>/dev/null | grep -q 'inet '; then
        reason=vpn_down
    else
        # At most 7 seconds per batch, including an unresponsive peer.
        ping -4 -I "$device" -c 3 -W 2 -w 7 10.8.8.8 > /tmp/kk-car-vpn-ping.raw 2>&1
    fi
    ucode /etc/kk-car/vpn-ping-write.uc "$reason" "$device"
    ucode /etc/kk-car/history-write.uc
    read ended rest < /proc/uptime
    ended=${ended%%.*}
    delay=$((10 - ended + started))
    [ "$delay" -ge 1 ] && [ "$delay" -le 10 ] || delay=1
    sleep "$delay" &
    wait $!
done
