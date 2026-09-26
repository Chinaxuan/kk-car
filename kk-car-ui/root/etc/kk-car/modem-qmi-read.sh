#!/bin/sh
# Read-only QMI telemetry. Discovery associates control and network nodes by USB
# ancestor, never by ttyUSB/cdc-wdm numbering. No SIM or equipment identifiers.
umask 077
sysfs=${KK_CAR_SYSFS_ROOT:-/sys}
devroot=${KK_CAR_DEV_ROOT:-/dev}
usb_parent() {
    node=$(readlink -f "$1" 2>/dev/null) || return 1
    while [ "$node" != / ] && [ -n "$node" ]; do
        if [ -f "$node/idVendor" ] && [ -f "$node/idProduct" ]; then
            printf '%s\n' "$node"; return 0
        fi
        node=${node%/*}
    done
    return 1
}
device= network= usb=
for control in "$sysfs"/class/usbmisc/cdc-wdm*; do
    [ -e "$control/device" ] || continue
    candidate=$(usb_parent "$control/device") || continue
    vid=$(cat "$candidate/idVendor" 2>/dev/null)
    pid=$(cat "$candidate/idProduct" 2>/dev/null)
    case "$vid:$pid" in 2ca3:4006|2c7c:0125) ;; *) continue ;; esac
    interface=$(readlink -f "$control/device" 2>/dev/null)
    [ "$(cat "$interface/bInterfaceNumber" 2>/dev/null)" = 04 ] || continue
    # Only QMI drivers are safe to query with uqmi; MBIM/ECM are separate paths.
    driver=$(readlink -f "$control/device/driver" 2>/dev/null)
    case "${driver##*/}" in qmi_wwan|qmi_wwan_q) ;; *) continue ;; esac
    for net in "$sysfs"/class/net/*; do
        [ -e "$net/device" ] || continue
        [ "$(readlink -f "$net/device" 2>/dev/null)" = "$interface" ] || continue
        network=${net##*/}; break
    done
    [ -n "$network" ] || continue
    device="$devroot/${control##*/}"; usb=$candidate; break
done
[ -n "$device" ] || exit 3
printf 'transport=QMI\nkkcar_probe=1\n'
printf 'model='; tr '\r\n=' '   ' < "$usb/product" 2>/dev/null; printf '\n'
printf 'network_device=%s\n' "$network"
for direction in rx tx; do
    printf 'cellular_%s=' "$direction"
    cat "$sysfs/class/net/$network/statistics/${direction}_bytes" 2>/dev/null
    printf '\n'
done
if [ "$1" = discover ]; then exit 0; fi
command -v uqmi >/dev/null 2>&1 || exit 1
active= timer=
cleanup() {
    [ -z "$active" ] || kill "$active" 2>/dev/null
    [ -z "$timer" ] || kill "$timer" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 143' TERM INT
query() {
    key=$1; shift
    printf '%s=' "$key"
    uqmi -s -t 3000 -d "$device" "$@" 2>/dev/null & active=$!
    (sleep 4; kill "$active" 2>/dev/null; sleep 1; kill -9 "$active" 2>/dev/null) & timer=$!
    wait "$active"
    kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
    active= timer=
    printf '\n'
}
query qmi_signal --get-signal-info
query qmi_data --get-data-status
query qmi_serving --get-serving-system
query qmi_capabilities --get-capabilities
query qmi_sim --uim-get-sim-state
