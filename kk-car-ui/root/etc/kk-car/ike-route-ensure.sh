#!/bin/sh
# Keep our rule outside PBR's managed priority range (29745-30000).
rule_count=$(ip -4 rule show | grep -c '^10000:.*fwmark 0x20000/0xff0000.*lookup 300')
if [ "$rule_count" -eq 0 ]; then
    ip -4 rule add priority 10000 fwmark 0x20000/0xff0000 lookup 300
fi
# netifd may reinstall its identical rule after an interface event.
while [ "$rule_count" -gt 1 ]; do
    ip -4 rule del priority 10000 fwmark 0x20000/0xff0000 lookup 300 || break
    rule_count=$((rule_count - 1))
done
if ip link show dev ikecar >/dev/null 2>&1; then
    ip -4 route show table 300 | grep -q '^default dev ikecar ' ||
        ip -4 route replace default dev ikecar table 300 metric 10
fi
