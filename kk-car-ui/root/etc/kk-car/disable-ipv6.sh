#!/bin/sh
# Reinforce the persistent sysctl settings after netifd creates a device.
for setting in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [ -f "$setting" ] && printf '1\n' > "$setting"
done
for name in forwarding accept_ra autoconf; do
    for setting in /proc/sys/net/ipv6/conf/*/"$name"; do
        [ -f "$setting" ] && printf '0\n' > "$setting"
    done
done
exit 0
