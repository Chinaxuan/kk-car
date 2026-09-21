#!/bin/sh
# Replies sourced from the assigned VPN address must return through the VPN.
# Own only the exact rules recorded here; never flush a routing table or priority.
umask 077
# The route watcher and IPsec up/down hook may run concurrently.
exec 9>/var/lock/kk-car-vpn-management.lock || exit 1
flock -n 9 || exit 0
state=/tmp/kk-car-vpn-management-sources
current=''
if [ "$(uci -q get firewall.kk_vpn_admin.enabled)" = 1 ]; then
    current=$(ip -o -4 addr show dev ikecar 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4 "/32"}' | sort -u)
fi
old=$(cat "$state" 2>/dev/null)
failed=0
for source in $old; do
    printf '%s\n' "$current" | grep -Fxq "$source" && continue
    # A missing old rule is harmless (for example after a netifd reload).
    while ip -4 rule show | awk -v source="$source" '$1=="9980:" && $2=="from" && ($3==source || $3 "/32"==source) && $4=="lookup" && $5=="300" {found=1} END {exit !found}'; do
        ip -4 rule del priority 9980 from "$source" lookup 300 || { failed=1; break; }
    done
done
for source in $current; do
    ip -4 rule show | awk -v source="$source" '$1=="9980:" && $2=="from" && ($3==source || $3 "/32"==source) && $4=="lookup" && $5=="300" {found=1} END {exit !found}' && continue
    ip -4 rule add priority 9980 from "$source" lookup 300 || failed=1
done
# Retain all possibly owned rules after partial failure for later cleanup.
next="$current"
if [ "$failed" != 0 ]; then
    next=$(printf '%s\n%s\n' "$old" "$current" | sed '/^$/d' | sort -u)
fi
if [ "$old" != "$next" ]; then
    printf '%s\n' "$next" > "$state.new" && mv "$state.new" "$state" || failed=1
fi
exit "$failed"
