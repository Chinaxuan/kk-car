#!/bin/sh
for file in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [ "$(cat "$file" 2>/dev/null)" = 1 ] || exit 1
done
for file in /proc/sys/net/ipv6/conf/*/forwarding; do
    [ "$(cat "$file" 2>/dev/null)" = 0 ] || exit 1
done
[ -z "$(ip -6 addr show 2>/dev/null)" ] || exit 1
[ -z "$(ip -6 route show table all 2>/dev/null)" ] || exit 1
echo disabled
