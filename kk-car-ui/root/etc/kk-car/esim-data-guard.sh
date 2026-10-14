#!/bin/sh
# Defense in depth: a future firmware/driver change must not make the expensive
# secondary SIM an uplink. Only network interfaces under stock ID 2ca3:4006
# are touched; the primary 2c7c:0125 QMI WAN is never changed.
for net in /sys/class/net/*; do
    [ -e "$net/device" ] || continue
    node=$(readlink -f "$net/device" 2>/dev/null) || continue
    while [ "$node" != / ] && [ -n "$node" ]; do
        if [ -f "$node/idVendor" ] && [ -f "$node/idProduct" ]; then
            if [ "$(cat "$node/idVendor")":"$(cat "$node/idProduct")" = 2ca3:4006 ]; then
                ip link set dev "${net##*/}" down 2>/dev/null || true
            fi
            break
        fi
        node=${node%/*}
    done
done
