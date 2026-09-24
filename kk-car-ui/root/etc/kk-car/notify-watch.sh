#!/bin/sh
umask 077
trap 'exit 0' TERM INT
while :; do
    rm -rf /tmp/kk-car-notify-lock
    ucode /etc/kk-car/notify-worker.uc
    # A short ring can be missed by a ten-second sample interval. Five
    # seconds also leaves the serial interface free for SMS/user requests.
    sleep 5 &
    wait $!
done
