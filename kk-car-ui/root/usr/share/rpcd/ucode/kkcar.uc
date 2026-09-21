'use strict';
import { readfile, writefile, popen, access, mkdir, rmdir, chmod, unlink } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import { history } from '/etc/kk-car/history.uc';
import { read_config, public_config, save_config } from '/etc/kk-car/notify-config.uc';

function run(cmd) {
    let p = popen(cmd + ' 2>/dev/null');
    if (!p) return '';
    let s = p.read('all'); p.close(); return trim(s || '');
}
function numberfile(path) { return +(trim(readfile(path) || '0')); }
function metricfile(path) { let v=trim(readfile(path) || '');return match(v,/^[0-9]+$/) ? +v : null; }
function netmetrics(device) {
    let result={mtu:metricfile('/sys/class/net/'+device+'/mtu')};
    for (let key in ['rx_packets','tx_packets','rx_errors','tx_errors','rx_dropped','tx_dropped'])
        result[key]=metricfile('/sys/class/net/'+device+'/statistics/'+key);
    return result;
}
function jsonfile(path) { try { return json(readfile(path) || '{}'); } catch(e) { return {}; } }
function takejob(kind) {
    if (!mkdir('/tmp/kk-car-ui-lock', 0700)) return false;
    writefile('/tmp/kk-car-ui-job.json', sprintf('%J', {kind, state:'running', started:time()}));
    return true;
}
function launch(kind) {
    // kind is always a literal from the allow-list below, never shell input.
    return system('/etc/kk-car/ui-job.sh ' + kind + ' </dev/null >/dev/null 2>&1 &') == 0;
}
function failjob() { rmdir('/tmp/kk-car-ui-lock'); }

return { 'kkcar': {
    notify_get: {call:function() {return {config:public_config(read_config()),status:jsonfile('/tmp/kk-car-notify-status.json')};}},
    notify_save: {args:{settings:''},call:function(req) {
        if(length(req.args.settings)>8192)return {ok:false,error:'设置内容过长'};
        let input;try{input=json(req.args.settings);}catch(e){return {ok:false,error:'设置格式错误'};}
        return save_config(input);
    }},
    notify_test: {call:function() {
        let c=read_config();
        if(!c.enabled || !length(filter(c.destinations,d=>d.enabled && d.url)))return {ok:false,error:'请先保存并启用推送和至少一个地址'};
        let previous=jsonfile('/tmp/kk-car-notify-test-last.json');
        let monotonic=int(+(split(readfile('/proc/uptime') || '0',' ')[0]));
        if(previous.uptime!=null && monotonic-previous.uptime<60)return {ok:false,error:'测试推送每分钟最多一次'};
        let request={at:time(),uptime:monotonic,revision:c.revision};
        if(!writefile('/tmp/kk-car-notify-test.json',sprintf('%J',request)))return {ok:false,error:'无法提交测试'};
        chmod('/tmp/kk-car-notify-test.json',0600);
        writefile('/tmp/kk-car-notify-test-last.json',sprintf('%J',request));
        return {ok:true};
    }},
    history: {args:{range:'1h'}, call:function(req) { return history(req.args.range); }},
    status: { call: function() {
        let bus = connect(), c = cursor();
        let wan = bus.call('network.interface.wan', 'status') || {};
        let uplink = jsonfile('/tmp/kk-car-uplink.json');
        let wired = bus.call('network.interface.kk_ethwan', 'status') || {};
        let portmode = c.get('network','kk_ethwan','auto') == '1' ? 'wan' : 'lan';
        let current = uplink.active == 'ethernet' ? wired : wan;
        let sys = bus.call('system', 'info') || {};
        let ap = bus.call('hostapd.phy0-ap0', 'get_clients') || {};
        let sa = run('/usr/sbin/swanctl --list-sas');
        let virtual = match(sa, /local\s+([0-9.]+)\/32/);
        let remote = match(sa, /remote\s+[^\n]+@\s+([0-9.]+)\[/);
        let age = match(sa, /established\s+(\d+)s/);
        let incoming = match(sa, /in\s+[a-f0-9]+[^\n]*?,\s+(\d+) bytes/);
        let outgoing = match(sa, /out\s+[a-f0-9]+[^\n]*?,\s+(\d+) bytes/);
        let power = run('/usr/bin/vcgencmd get_throttled');
        let pm = match(power, /0x([0-9a-f]+)/);
        let powerbits = pm ? int(pm[1],16) : null;
        let ticks=split(trim(split(readfile('/proc/stat') || '', '\n')[0]), /\s+/);
        let total=0;for (let i=1;i<=8;i++) total+=+(ticks[i] || 0);
        let clock=match(run('/usr/bin/vcgencmd measure_clock arm'), /=([0-9]+)/);
        let loads=split(trim(readfile('/proc/loadavg') || ''), /\s+/);
        let cipher=match(sa,/ESP:([^\n]+)/), rekey=match(sa,/installed [0-9]+s ago, rekeying in ([0-9]+)s/);
        let peers = [];
        for (let line in split(readfile('/tmp/dhcp.leases') || '', '\n')) {
            let f = split(trim(line), /\s+/);
            if (length(f) < 4 || (+f[0] != 0 && +f[0] < time())) continue;
            push(peers, {name:f[3] == '*' ? '未命名设备' : f[3], ip:f[2],
                wireless:!!ap.clients?.[lc(f[1])], mac:f[1]});
        }
        let pending = jsonfile('/etc/kk-car/ui-wifi-pending.json');
        let portpending = jsonfile('/etc/kk-car/ui-port-pending.json');
        let ikeRoute = run('/sbin/ip -4 route show table 300');
        let ikeRule = run('/sbin/ip -4 rule show');
        let width = match(run('/usr/sbin/iw dev phy0-ap0 info'), /width: (\d+) MHz/);
        let ipv6off = run('/bin/sh /etc/kk-car/check-ipv6.sh') == 'disabled';
        return {
            timestamp:time(), uptime:sys.uptime, memory:sys.memory, load:sys.load,
            telemetry:{cpu:{total,idle:+(ticks[4] || 0)+ +(ticks[5] || 0),mhz:clock ? +clock[1]/1e6 : null},
                loads:[loads[0] || null,loads[1] || null,loads[2] || null],
                conntrack:metricfile('/proc/sys/net/netfilter/nf_conntrack_count'),conntrack_max:metricfile('/proc/sys/net/netfilter/nf_conntrack_max'),
                wan:netmetrics(uplink.active=='ethernet'?'eth0':'eth1'),vpn:netmetrics('ikecar'),
                cipher:cipher ? trim(cipher[1]) : null,rekey:rekey ? +rekey[1] : null},
            temperature:numberfile('/sys/class/thermal/thermal_zone0/temp') / 1000,
            power:{known:powerbits != null, undervoltage:powerbits != null && !!(powerbits & 1), throttled:powerbits != null && !!(powerbits & 4), historical:powerbits != null && !!(powerbits & 0x50000)},
            wan:{up:uplink.active ? uplink.active != 'none' : !!wan.up, ip:current['ipv4-address']?.[0]?.address || '', device:current.l3_device || '', uptime:current.uptime || 0,
                rx:numberfile('/sys/class/net/eth1/statistics/rx_bytes') + (portmode=='wan' ? numberfile('/sys/class/net/eth0/statistics/rx_bytes') : 0),
                tx:numberfile('/sys/class/net/eth1/statistics/tx_bytes') + (portmode=='wan' ? numberfile('/sys/class/net/eth0/statistics/tx_bytes') : 0)},
            ethernet:{mode:portmode, carrier:trim(readfile('/sys/class/net/eth0/carrier') || '')=='1', up:!!wired.up, ip:wired['ipv4-address']?.[0]?.address || ''},
            uplink,
            vpn:{connected: index(sa,'ESTABLISHED') >= 0 && index(sa,'INSTALLED') >= 0,
                running: access('/var/run/charon.pid'), auto:system('/etc/init.d/swanctl enabled >/dev/null 2>&1') == 0,
                ip:virtual?.[1] || '', server:remote?.[1] || '203.0.113.10', age:+(age?.[1] || 0),
                rx:+(incoming?.[1] || 0), tx:+(outgoing?.[1] || 0),
                route: index(ikeRoute,'default dev ikecar') >= 0 && !!match(ikeRule, /10000:.*fwmark 0x20000\/0xff0000.*lookup 300/)},
            wifi:{ssid:c.get('wireless','default_radio0','ssid'), channel:c.get('wireless','radio0','channel'),
                width:width ? +width[1] : null,
                band:c.get('wireless','radio0','band') || '2g', frequency:ap.freq || 0,
                enabled:c.get('wireless','default_radio0','disabled') != '1', clients:length(ap.clients || {})},
            ipv6_disabled:ipv6off, modem:jsonfile('/tmp/kk-car-modem.json'),
            vpn_ping:jsonfile('/tmp/kk-car-vpn-ping.json'),
            peers, wg_enabled:c.get('network','wgcar','auto') == '1',
            job:jsonfile('/tmp/kk-car-ui-job.json'), busy:access('/tmp/kk-car-ui-lock'),
            wifi_pending: pending.deadline ? {deadline:pending.deadline, ssid:pending.ssid} : null,
            port_pending: portpending.deadline ? {deadline:portpending.deadline, mode:portpending.mode} : null,
            diagnostics:jsonfile('/tmp/kk-car-ui-diagnostics.json'),
            diagnostics_auto:jsonfile('/tmp/kk-car-auto-check.json')
        };
    }},
    action: { args:{action:''}, call:function(req) {
        let kind = req.args.action;
        if (index(['vpn_restart','vpn_start','vpn_stop','wan_restart','diagnose','modem_refresh'],kind) < 0)
            return {ok:false,error:'不支持的操作'};
        if (!takejob(kind)) return {ok:false,error:'上一个操作尚未完成，请稍后再试'};
        if (!launch(kind)) { failjob(); return {ok:false,error:'操作未能启动'}; }
        return {ok:true,accepted:true};
    }},
    auto_connect: {args:{enabled:true}, call:function(req) {
        if (access('/tmp/kk-car-ui-lock')) return {ok:false,error:'请等待当前操作完成'};
        let rc = system(req.args.enabled ? '/etc/init.d/swanctl enable' : '/etc/init.d/swanctl disable');
        return {ok:rc == 0, enabled:system('/etc/init.d/swanctl enabled >/dev/null 2>&1') == 0};
    }},
    port_save: {args:{mode:''}, call:function(req) {
        let mode=req.args.mode;
        if (mode!='lan' && mode!='wan') return {ok:false,error:'请选择 LAN 或 WAN'};
        let c=cursor(), bridge=null;
        c.foreach('network','device',function(s){ if (s.name=='br-lan' && s.type=='bridge') bridge=s['.name']; });
        if (!bridge || c.get('network','kk_ethwan','device')!='eth0') return {ok:false,error:'网口配置已被高级设置改变，请先检查'};
        if (length(c.changes('network') || {})) return {ok:false,error:'高级页面有未应用的网络修改，请先处理'};
        if (mode==(c.get('network','kk_ethwan','auto')=='1'?'wan':'lan')) return {ok:true,unchanged:true};
        if (!takejob('port_apply')) return {ok:false,error:'上一个操作尚未完成，请稍后再试'};
        let backup=readfile('/etc/config/network');
        if (!backup || !writefile('/etc/kk-car/ui-port-backup',backup)) { failjob(); return {ok:false,error:'无法创建回退备份'}; }
        chmod('/etc/kk-car/ui-port-backup',0600);
        let pending={mode,deadline:time()+125};
        if (!writefile('/etc/kk-car/ui-port-pending.json',sprintf('%J',pending))) {
            unlink('/etc/kk-car/ui-port-backup'); failjob(); return {ok:false,error:'无法创建回退任务'};
        }
        unlink('/tmp/kk-car-ui-port-confirmed');
        let ports=c.get('network',bridge,'ports') || [];
        if (type(ports)=='string') ports=[ports];
        let keep=[]; for (let p in ports) if (p!='eth0') push(keep,p);
        if (mode=='lan') push(keep,'eth0');
        if (length(keep)) c.set('network',bridge,'ports',keep); else c.delete('network',bridge,'ports');
        c.set('network','kk_ethwan','auto',mode=='wan'?'1':'0');
        if (!c.commit('network') || !launch('port_apply')) {
            writefile('/etc/config/network',backup); chmod('/etc/config/network',0600);
            unlink('/etc/kk-car/ui-port-pending.json'); unlink('/etc/kk-car/ui-port-backup'); failjob();
            return {ok:false,error:'应用失败，已恢复原网口设置'};
        }
        return {ok:true,pending};
    }},
    port_confirm: {call:function() {
        let p=jsonfile('/etc/kk-car/ui-port-pending.json');
        if (!p.deadline || p.deadline<=time()) return {ok:false,error:'确认期限已结束，请等待自动回退'};
        return {ok:!!writefile('/tmp/kk-car-ui-port-confirmed','1')};
    }},
    wifi_save: {args:{ssid:'',password:'',band:''}, call:function(req) {
        let name = req.args.ssid, password = req.args.password;
        if (length(name) < 1 || length(name) > 32 || match(name, /[[:cntrl:]]/))
            return {ok:false,error:'热点名称应为 1–32 个字节，不能含控制字符'};
        if (password != '' && (length(password) < 8 || length(password) > 63 || match(password, /[^ -~]/)))
            return {ok:false,error:'密码请使用 8–63 位英文字母、数字或常用符号'};
        let c = cursor();
        let current_band = c.get('wireless','radio0','band') || '2g';
        let band = req.args.band || current_band;
        if (band != '2g' && band != '5g') return {ok:false,error:'请选择 2.4GHz 或 5GHz'};
        if (length(c.changes('wireless') || {})) return {ok:false,error:'高级页面有未应用的无线设置，请先处理后再试'};
        if (name == c.get('wireless','default_radio0','ssid') && password == '' && band == current_band)
            return {ok:true,unchanged:true};
        if (!takejob('wifi_apply')) return {ok:false,error:'上一个操作尚未完成，请稍后再试'};
        let backup = readfile('/etc/config/wireless');
        if (!backup || !writefile('/etc/kk-car/ui-wifi-backup',backup)) {
            failjob(); return {ok:false,error:'无法保存回退备份，设置未修改'};
        }
        chmod('/etc/kk-car/ui-wifi-backup',0600);
        let pending = {ssid:name,deadline:time()+125};
        if (!writefile('/etc/kk-car/ui-wifi-pending.json',sprintf('%J',pending))) {
            unlink('/etc/kk-car/ui-wifi-backup'); failjob(); return {ok:false,error:'无法创建回退任务'};
        }
        unlink('/tmp/kk-car-ui-wifi-confirmed');
        c.set('wireless','default_radio0','ssid',name);
        if (password != '') c.set('wireless','default_radio0','key',password);
        if (band != current_band) {
            c.set('wireless','radio0','band',band);
            c.set('wireless','radio0','channel',band == '5g' ? '149' : '6');
            c.set('wireless','radio0','htmode',band == '5g' ? 'VHT20' : 'HT20');
        }
        if (!c.commit('wireless') || !launch('wifi_apply')) {
            writefile('/etc/config/wireless',backup); chmod('/etc/config/wireless',0600);
            unlink('/etc/kk-car/ui-wifi-pending.json'); unlink('/etc/kk-car/ui-wifi-backup'); failjob();
            return {ok:false,error:'设置失败，已恢复原配置'};
        }
        return {ok:true,pending};
    }},
    wifi_confirm: {call:function() {
        let p = jsonfile('/etc/kk-car/ui-wifi-pending.json');
        if (!p.deadline || p.deadline <= time()) return {ok:false,error:'确认期限已结束，请等待自动回退'};
        return {ok:!!writefile('/tmp/kk-car-ui-wifi-confirmed','1')};
    }}
}};
