#!/bin/sh
while :; do
    /usr/bin/ucode -e 'import { run } from "/etc/kk-car/ups-watch.uc"; run();' >/dev/null 2>&1
    sleep 10
done
