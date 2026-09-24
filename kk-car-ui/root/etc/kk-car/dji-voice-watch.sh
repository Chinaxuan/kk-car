#!/bin/sh
umask 077
trap 'exit 0' TERM INT
while :; do
    if ! /etc/kk-car/dji-voice-health.sh prepared >/dev/null 2>&1; then
        /etc/kk-car/dji-voice-prepare.sh >/dev/null 2>&1 || true
    fi
    sleep 30 & wait $!
done
