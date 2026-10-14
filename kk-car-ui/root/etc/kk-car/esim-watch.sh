#!/bin/sh
umask 077
trap 'exit 0' TERM INT
while :; do
    /etc/kk-car/esim-bind.sh once >/dev/null 2>&1 || true
    /etc/kk-car/esim-data-guard.sh
    /usr/bin/python3 /etc/kk-car/esim-manager.py tick >/tmp/kk-car-esim-tick.json.new 2>/dev/null &&
        mv /tmp/kk-car-esim-tick.json.new /tmp/kk-car-esim-tick.json ||
        rm -f /tmp/kk-car-esim-tick.json.new
    flock -n /tmp/kk-car-esim-operation.lock env KK_CAR_SMS_ROLE=secondary \
        ucode /etc/kk-car/dji-sms-forward.uc >/dev/null 2>&1 || true
    sleep 60 & wait $!
done
