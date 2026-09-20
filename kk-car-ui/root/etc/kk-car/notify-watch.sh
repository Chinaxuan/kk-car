#!/bin/sh
umask 077
trap 'exit 0' TERM INT
while :; do
    rm -rf /tmp/kk-car-notify-lock
    ucode /etc/kk-car/notify-worker.uc
    sleep 10 &
    wait $!
done
