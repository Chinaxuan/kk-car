#!/bin/sh
# Runs on the F30A Pro via ADB. Read only; never dump identifiers or credentials.
echo kkcar_probe=1
for key in network_type network_provider signalbar rssi lte_rsrp simcard_roam ppp_status realtime_time; do
    printf '%s=' "$key"
    nv get "$key" 2>/dev/null
    printf '\n'
done
printf 'uptime='
cut -d ' ' -f 1 /proc/uptime
for direction in rx tx; do
    printf 'cellular_%s=' "$direction"
    cat "/sys/class/net/wan1/statistics/${direction}_bytes" 2>/dev/null
    printf '\n'
done
