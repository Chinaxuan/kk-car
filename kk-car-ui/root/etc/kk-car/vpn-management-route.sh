#!/bin/sh
# Reply over the same tunnel that received a management connection.
# Tables 302/303 never fall back to the physical WAN.
umask 077
exec 9>/var/lock/kk-car-vpn-management.lock || exit 1
flock -n 9 || exit 0
state=/tmp/kk-car-vpn-management-sources
next=$(mktemp /tmp/kk-car-vpn-management.XXXXXX) || exit 1
trap 'rm -f "$next"' EXIT

for spec in 'ovpncar 302 9980' 'wgcar 303 9981'; do
    set -- $spec
    device=$1 table=$2 priority=$3
    ip -4 route replace unreachable default table "$table" metric 32767 || exit 1
    if ip -o -4 addr show dev "$device" 2>/dev/null | grep -q ' inet '; then
        ip -4 route replace default dev "$device" table "$table" metric 10 || exit 1
        if [ "$(uci -q get firewall.kk_vpn_admin.enabled)" = 1 ]; then
            ip -o -4 addr show dev "$device" | awk '{sub(/\/.*/, "", $4); print $4 "/32"}' | sort -u |
                while read -r source; do printf '%s %s %s\n' "$source" "$table" "$priority"; done >> "$next"
        fi
    else
        ip -4 route show table "$table" | grep -q "^default dev $device " &&
            ip -4 route del default dev "$device" table "$table" metric 10
    fi
done

# Migrate the former single-VPN rule (the old state stored only its source).
if [ -f "$state" ]; then
    while read -r source table priority; do
        [ -n "$source" ] || continue
        [ -n "$table" ] || table=300
        [ -n "$priority" ] || priority=9980
        grep -Fqx "$source $table $priority" "$next" && continue
        ip -4 rule del priority "$priority" from "$source" lookup "$table" 2>/dev/null || true
    done < "$state"
fi

while read -r source table priority; do
    [ -n "$source" ] || continue
    ip -4 rule show | awk -v p="$priority:" -v s="$source" -v t="$table" \
        '$1==p && $2=="from" && ($3==s || $3 "/32"==s) && $4=="lookup" && $5==t {f=1} END {exit !f}' && continue
    ip -4 rule add priority "$priority" from "$source" lookup "$table" || exit 1
done < "$next"
mv "$next" "$state"
