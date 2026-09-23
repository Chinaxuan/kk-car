#!/bin/sh
umask 077
. /usr/share/libubox/jshn.sh
kind="$1"
result() {
    json_init
    json_add_string kind "$kind"
    json_add_string state "$1"
    json_add_string message "$2"
    json_add_int finished "$(date +%s)"
    json_dump > /tmp/kk-car-ui-job.json.new
    mv /tmp/kk-car-ui-job.json.new /tmp/kk-car-ui-job.json
}
trap 'rmdir /tmp/kk-car-ui-lock 2>/dev/null' EXIT
case "$kind" in
    modem_refresh)
        /etc/kk-car/modem-poll.sh once
        case "$?" in
            0) result done '上网棒状态已更新' ;;
            2) result done '后台正在读取上网棒，页面会自动更新' ;;
            *) result error '暂时无法采集模块状态；此结果不代表蜂窝网络已断开' ;;
        esac
        ;;
    vpn_restart|vpn_start|vpn_stop)
        case "$kind" in
            vpn_restart) /etc/init.d/swanctl restart >/dev/null 2>&1 ;;
            vpn_start) /etc/init.d/swanctl start >/dev/null 2>&1 ;;
            vpn_stop) /etc/init.d/swanctl stop >/dev/null 2>&1 ;;
        esac
        rc=$?
        if [ "$rc" != 0 ]; then result error '操作执行失败，请检查服务'; exit 1; fi
        if [ "$kind" = vpn_stop ]; then result done 'VPN 已暂停，国外和公司内网暂时不可用'; exit; fi
        i=0
        while [ "$i" -lt 15 ]; do
            if swanctl --list-sas 2>/dev/null | grep -q INSTALLED; then
                /etc/kk-car/ike-route-ensure.sh
                result done 'VPN 隧道已连接，可运行网络检查验证实际访问'
                exit
            fi
            sleep 2; i=$((i+1))
        done
        result error '暂未连接成功，后台仍会重试；请检查上网棒和公司 VPN'
        ;;
    wan_restart)
        ifdown wan; sleep 2; ifup wan
        sleep 20
        up=$(ubus call network.interface.wan status | jsonfilter -e '@.up')
        if [ "$up" = true ]; then result done '上网棒已重新获取网络，请检查 VPN 和实际访问'; else result error '上网棒尚未获取网络，请检查信号和 USB 连接'; fi
        ;;
    diagnose)
        dir=$(mktemp -d /tmp/kk-car-check.XXXXXX) || { result error '无法创建检查任务'; exit 1; }
        # Pin only the public probe endpoint; record a separate DNS check.
        direct_if=$(jsonfilter -i /tmp/kk-car-uplink.json -e '@.device' 2>/dev/null)
        valid_wan_device() {
            [ "${#1}" -le 15 ] && printf '%s\n' "$1" | grep -Eq '^(eth|wwan|usb)[0-9]+$' && [ -d "/sys/class/net/$1" ]
        }
        if ! valid_wan_device "$direct_if"; then
            direct_if=$(ucode -e 'import {connect} from "ubus"; import {read_cellular} from "/etc/kk-car/uplink-model.uc"; let cell=read_cellular(connect()); if(cell.up && cell.default_route) print(cell.device);' 2>/dev/null)
        fi
        # An unknown/offline WAN must never fall back to an unbound request.
        (valid_wan_device "$direct_if" && curl -4 --noproxy '*' --interface "$direct_if" --connect-timeout 3 --max-time 7 -fsS https://myip.ipip.net > "$dir/domestic" 2>/dev/null) & p1=$!
        curl -4 --noproxy '*' --interface ikecar --resolve www.cloudflare.com:443:104.16.124.96 --connect-timeout 3 --max-time 7 -fsS https://www.cloudflare.com/cdn-cgi/trace > "$dir/foreign" 2>/dev/null & p2=$!
        curl -4 --noproxy '*' --interface ikecar --connect-timeout 3 --max-time 7 -sS -o /dev/null -w '%{http_code}' http://10.8.8.15:8080/ > "$dir/company" 2>/dev/null & p3=$!
        (nslookup www.google.com 127.0.0.1 > "$dir/dns" 2>/dev/null) & p4=$!
        # Public AI probes follow the VPN only. No cookies, login or API credentials.
        # Bound both response bytes and duration; no redirects to other hosts.
        (curl -4 --noproxy '*' --interface ikecar --connect-timeout 4 --max-time 12 --max-filesize 32768 -sS -o "$dir/chatgpt.body" -w '%{http_code}' https://chatgpt.com/cdn-cgi/trace > "$dir/chatgpt.code" 2>/dev/null; echo $? > "$dir/chatgpt.rc") & p5=$!
        (curl -4 --noproxy '*' --interface ikecar --connect-timeout 4 --max-time 12 --max-filesize 1572864 -sS -o "$dir/gemini.body" -w '%{http_code}' https://gemini.google.com/ > "$dir/gemini.code" 2>/dev/null; echo $? > "$dir/gemini.rc") & p6=$!
        # Bound the DNS query as BusyBox has no timeout utility here.
        (sleep 8; kill "$p4" 2>/dev/null) & timer=$!
        wait "$p1"; domestic_rc=$?
        wait "$p2"; foreign_rc=$?
        wait "$p3"; company_rc=$?
        wait "$p4"; dns_rc=$?
        kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
        wait "$p5"; wait "$p6"
        json_init
        json_add_int timestamp "$(date +%s)"
        json_add_boolean domestic "$([ "$domestic_rc" = 0 ] && echo 1 || echo 0)"
        json_add_string domestic_detail "$(head -c 180 "$dir/domestic")"
        json_add_boolean foreign "$([ "$foreign_rc" = 0 ] && grep -q '^ip=' "$dir/foreign" && echo 1 || echo 0)"
        json_add_string foreign_ip "$(sed -n 's/^ip=//p' "$dir/foreign")"
        json_add_string foreign_country "$(sed -n 's/^loc=//p' "$dir/foreign")"
        code=$(cat "$dir/company")
        json_add_boolean company "$([ "$company_rc" = 0 ] && [ "$code" != 000 ] && echo 1 || echo 0)"
        json_add_string company_code "$code"
        json_add_boolean dns "$([ "$dns_rc" = 0 ] && grep -q 'Name:' "$dir/dns" && echo 1 || echo 0)"
        json_dump > "$dir/base.json"
        if ! ucode /etc/kk-car/ai-region-report.uc "$dir" > /tmp/kk-car-ui-diagnostics.json.new; then
            rm -r "$dir"
            rm -f /tmp/kk-car-ui-diagnostics.json.new
            result error '地区结果解析失败，保留上次检查结果'
            exit 1
        fi
        mv /tmp/kk-car-ui-diagnostics.json.new /tmp/kk-car-ui-diagnostics.json
        rm -r "$dir"
        result done '检查完成，请查看每项结果；探测目标失败不一定代表整条线路故障'
        ;;
    port_apply)
        sleep 4
        ifdown kk_ethwan
        /etc/init.d/network reload >/dev/null 2>&1
        [ "$(uci -q get network.kk_ethwan.auto)" = 1 ] && ifup kk_ethwan
        /etc/kk-car/disable-ipv6.sh
        deadline=$(jsonfilter -i /etc/kk-car/ui-port-pending.json -e '@.deadline')
        while [ "$(date +%s)" -lt "${deadline:-0}" ]; do
            if [ -f /tmp/kk-car-ui-port-confirmed ]; then
                rm -f /etc/kk-car/ui-port-pending.json /etc/kk-car/ui-port-backup /tmp/kk-car-ui-port-confirmed
                result done '网口用途已确认并保留'
                exit
            fi
            sleep 1
        done
        if cp /etc/kk-car/ui-port-backup /etc/config/network; then
            chmod 600 /etc/config/network
            ifdown kk_ethwan
            /etc/init.d/network reload >/dev/null 2>&1
            [ "$(uci -q get network.kk_ethwan.auto)" = 1 ] && ifup kk_ethwan
            /etc/kk-car/disable-ipv6.sh
            rm -f /etc/kk-car/ui-port-pending.json /etc/kk-car/ui-port-backup /tmp/kk-car-ui-port-confirmed
            result done '未收到确认，已自动恢复原网口用途'
        else
            result error '网口自动恢复失败，请通过 Wi-Fi 检查高级设置'
        fi
        ;;
    wifi_apply)
        sleep 4
        wifi reload >/dev/null 2>&1
        deadline=$(jsonfilter -i /etc/kk-car/ui-wifi-pending.json -e '@.deadline')
        while [ "$(date +%s)" -lt "${deadline:-0}" ]; do
            if [ -f /tmp/kk-car-ui-wifi-confirmed ]; then
                rm -f /etc/kk-car/ui-wifi-pending.json /etc/kk-car/ui-wifi-backup /tmp/kk-car-ui-wifi-confirmed
                result done '新热点设置已确认并保留'
                exit
            fi
            sleep 1
        done
        if cp /etc/kk-car/ui-wifi-backup /etc/config/wireless; then
            chmod 600 /etc/config/wireless
            wifi reload >/dev/null 2>&1
            rm -f /etc/kk-car/ui-wifi-pending.json /etc/kk-car/ui-wifi-backup /tmp/kk-car-ui-wifi-confirmed
            result done '未收到确认，已自动恢复原热点名称和密码'
        else
            result error '自动恢复失败，请使用网线进入高级设置'
        fi
        ;;
    *) result error '不支持的操作'; exit 1 ;;
esac
