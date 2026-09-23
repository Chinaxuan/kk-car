#!/bin/sh
while :; do
    # PBR 1.2.x re-enables the IPv6 forwarding flag when restoring IPv4
    # forwarding. Keep this IPv4-only appliance's policy after async reloads.
    restore_ipv6=0
    for setting in /proc/sys/net/ipv6/conf/*/disable_ipv6 /proc/sys/net/ipv6/conf/*/forwarding; do
        [ -f "$setting" ] || continue
        read -r value < "$setting"
        case "$setting:$value" in
            */disable_ipv6:1|*/forwarding:0) ;;
            *) restore_ipv6=1 ;;
        esac
    done
    if [ "$restore_ipv6" = 1 ]; then
        /etc/kk-car/disable-ipv6.sh
    fi
    ucode /etc/kk-car/uplink-step.uc
    sleep 5
done
