#!/bin/sh
umask 077
trap 'exit 0' TERM INT
while :; do
    # A killed worker may leave only root-owned temporary files in tmpfs.
    rm -rf /tmp/kk-car-sms-forward
    ucode /etc/kk-car/dji-sms-forward.uc >/dev/null 2>&1
    flock -n /tmp/kk-car-dji-traffic.lock ucode /etc/kk-car/dji-traffic.uc tick >/dev/null 2>&1
    sleep 30 & wait $!
done
