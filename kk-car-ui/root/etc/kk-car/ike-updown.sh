#!/bin/sh
# Keep the dedicated policy route after strongSwan replaces the virtual address.
[ "$PLUTO_CONNECTION" = "kk-car" ] || [ "$PLUTO_CONNECTION" = "kk-car-internet" ] || exit 0
case "$PLUTO_VERB" in
    up-client|up-host)
        /etc/kk-car/ike-route-ensure.sh || exit 1
        /usr/bin/killall -HUP dnsmasq 2>/dev/null || true
        logger -t kk-car-ike "VPN route restored on ikecar"
        ;;
esac
exit 0
