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
# The private OpenVPN profile is selected only when explicitly enabled.
# Keep the unreachable default in table 300 as the VPN kill switch.
device=ikecar
[ "$(uci -q get openvpn.kkcar.enabled)" = 1 ] && device=ovpncar
if ip -o -4 addr show dev "$device" 2>/dev/null | grep -q ' inet '; then
    ip -4 route show table 300 | grep -q "^default dev $device " ||
        ip -4 route replace default dev "$device" table 300 metric 10
else
    for old in ikecar ovpncar; do
        ip -4 route show table 300 | grep -q "^default dev $old " &&
            ip -4 route del default dev "$old" table 300 metric 10
    done
fi
# Optional reverse management tracks the current assigned VPN address.
if [ -x /etc/kk-car/vpn-management-route.sh ]; then
    /etc/kk-car/vpn-management-route.sh
fi
