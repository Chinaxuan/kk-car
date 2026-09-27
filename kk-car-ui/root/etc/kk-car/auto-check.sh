#!/bin/sh
# Device-local monotonic scheduler. Uses the same RPC lock as the manual button.
umask 077
. /usr/share/libubox/jshn.sh
exec 9>/var/lock/kk-car-auto-check.lock || exit 1
flock -n 9 || exit 0
interval=600
last_started=0
state=waiting
now_up() { read -r seconds rest < /proc/uptime; echo "${seconds%.*}"; }
read_interval() {
    value=$(jsonfilter -i /etc/kk-car/private/device-settings.json -e '@.check_interval_seconds' 2>/dev/null)
    case "$value" in 300|600|900|1800|3600) echo "$value" ;; *) echo 600 ;; esac
}
started=$(now_up)
last_up=0
next=$((started + 15))
[ "$next" -ge 60 ] || next=60
publish() {
    wall=$(date +%s)
    remaining=$((next - $(now_up)))
    [ "$remaining" -ge 0 ] || remaining=0
    json_init
    json_add_boolean enabled 1
    json_add_int interval_seconds "$interval"
    json_add_int updated "$wall"
    json_add_int next_run "$((wall + remaining))"
    json_add_int last_started "$last_started"
    json_add_string state "$state"
    json_dump > /tmp/kk-car-auto-check.json.new
    mv /tmp/kk-car-auto-check.json.new /tmp/kk-car-auto-check.json
}
while :; do
    now=$(now_up)
    configured=$(read_interval)
    if [ "$configured" -ne "$interval" ]; then
        interval=$configured
        [ "$last_up" -eq 0 ] || next=$((last_up + interval))
    fi
    if [ "$now" -ge "$next" ]; then
        reply=$(ubus -t 5 call kkcar action '{"action":"diagnose"}' 9>&- 2>/dev/null)
        accepted=$(printf '%s' "$reply" | jsonfilter -e '@.accepted' 2>/dev/null)
        if [ "$accepted" = true ]; then
            last_started=$(date +%s)
            last_up=$now
            next=$((now + interval))
            state=waiting
        elif [ -d /tmp/kk-car-ui-lock ]; then
            next=$((now + 15))
            state=busy
        else
            next=$((now + 60))
            state=rpc_unavailable
        fi
    fi
    publish
    # A child sleep must not keep the instance lock after procd stops its parent.
    sleep 15 9>&-
done
