#!/bin/sh
# Address replacement during MOBIKE may remove a route without a CHILD_SA event.
while :; do
    /etc/kk-car/ike-route-ensure.sh
    sleep 5
done
