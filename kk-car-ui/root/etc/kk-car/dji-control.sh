#!/bin/sh
# DJI management actions intentionally leave LAN, Wi-Fi, firewall and VPN alone.
umask 077
kind=$1
job=/tmp/kk-car-dji-job.json
result() {
    json_init
    json_add_string kind "$kind"
    json_add_string state "$1"
    json_add_string message "$2"
    json_add_int timestamp "$(date +%s)"
    json_dump > "$job.new"
    mv "$job.new" "$job"
}
. /usr/share/libubox/jshn.sh
case "$kind" in refresh|reconnect) ;; *) exit 2;; esac
if ! mkdir /tmp/kk-car-dji-control-lock 2>/dev/null; then
    [ "$kind" = reconnect ] && rmdir /tmp/kk-car-ui-lock 2>/dev/null
    exit 2
fi
cleanup() {
    rmdir /tmp/kk-car-dji-control-lock 2>/dev/null
    [ "$kind" = reconnect ] && rmdir /tmp/kk-car-ui-lock 2>/dev/null
}
trap cleanup EXIT
result running '操作正在进行'
if [ "$kind" = reconnect ]; then
    [ "$(uci -q get network.wan.proto)" = qmi ] || { result error '当前蜂窝接口不是 QMI'; exit 1; }
    ifdown wan
    sleep 2
    ifup wan || { result error '蜂窝接口启动失败'; exit 1; }
    i=0
    while [ "$i" -lt 20 ]; do
        if [ "$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.up')" = true ]; then break; fi
        sleep 2; i=$((i+1))
    done
    [ "$i" -lt 20 ] || { result error '蜂窝数据连接尚未恢复'; exit 1; }
fi
/etc/kk-car/modem-poll.sh once >/dev/null 2>&1
if [ -x /etc/kk-car/dji-at-status.sh ]; then
    /etc/kk-car/dji-at-status.sh > /tmp/kk-car-dji-at.json.new 2>/dev/null &&
        mv /tmp/kk-car-dji-at.json.new /tmp/kk-car-dji-at.json || rm -f /tmp/kk-car-dji-at.json.new
fi
if [ -f /etc/kk-car/dji-sms.uc ]; then
    /usr/bin/ucode /etc/kk-car/dji-sms.uc storage > /tmp/kk-car-dji-sms-storage.json.new 2>/dev/null &&
        mv /tmp/kk-car-dji-sms-storage.json.new /tmp/kk-car-dji-sms-storage.json || rm -f /tmp/kk-car-dji-sms-storage.json.new
fi
result done 'DJI 状态已更新'
