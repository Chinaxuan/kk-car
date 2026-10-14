#!/bin/sh
# Bind only the stock USB serial ID of the secondary DJI modem. Never register
# a network driver, bring up a PDP context, or touch OpenWrt WAN configuration.
[ "$1" = once ] || exit 2
sysfs=${KK_CAR_SYSFS_ROOT:-/sys}
for usb in "$sysfs"/bus/usb/devices/*; do
    [ -f "$usb/idVendor" ] && [ -f "$usb/idProduct" ] || continue
    [ "$(cat "$usb/idVendor")" = 2ca3 ] || continue
    [ "$(cat "$usb/idProduct")" = 4006 ] || continue
    [ "$(tr '[:lower:]' '[:upper:]' < "$usb/manufacturer" 2>/dev/null)" = BAIWANG ] || continue
    # If a network driver has already claimed this device, refuse rather than
    # silently accepting a costly data-capable setup.
    for iface in "$usb":1.*; do
        driver=$(readlink -f "$iface/driver" 2>/dev/null)
        case "${driver##*/}" in qmi_wwan|qmi_wwan_q|cdc_ether|cdc_ncm|cdc_mbim|rndis_host)
            exit 4;;
        esac
    done
    [ -e "$usb:1.2/driver" ] && exit 0
    [ -w "$sysfs/bus/usb-serial/drivers/option1/new_id" ] || exit 3
    printf '2ca3 4006\n' > "$sysfs/bus/usb-serial/drivers/option1/new_id" || exit 3
    exit 0
done
exit 1
