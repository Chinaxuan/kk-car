'use strict';
import { readfile, writefile, popen, access, mkdir, rmdir, chmod, unlink, rename } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import { read_cellular } from '/etc/kk-car/uplink-model.uc';
import { get_data,seed_outgoing,save_contact,delete_contact } from '/etc/kk-car/dji-phonebook.uc';

function filejson(path) {
    try { return json(readfile(path) || '{}'); } catch (e) { return {}; }
}
function value(x) { return x == null ? null : x; }
function fresh(record, seconds) {
    return type(record) == 'object' && record.timestamp != null &&
        +record.timestamp > 0 && time() - +record.timestamp >= 0 && time() - +record.timestamp <= seconds;
}
function call_sms(kind, index) {
    // kind is selected from fixed literals; index is validated as decimal digits.
    let command = '/usr/bin/ucode /etc/kk-car/dji-sms.uc ' + kind + (index == null ? '' : ' ' + index);
    let process = popen(command + ' 2>/dev/null');
    if (!process) return {ok:false,error:'短信服务暂不可用'};
    let output = process.read('all'); process.close();
    try {
        let result = json(output || '{}');
        return type(result) == 'object' && type(result.ok) == 'bool' ? result : {ok:false,error:'短信服务返回异常'};
    } catch (e) { return {ok:false,error:'短信服务返回异常'}; }
}
function call_traffic(kind) {
    let p=popen('flock /tmp/kk-car-dji-traffic.lock /usr/bin/ucode /etc/kk-car/dji-traffic.uc '+kind+' 2>/dev/null');
    if (!p) return {ok:false,error:'流量服务暂不可用'};
    let output=p.read('all'); p.close();
    try { return json(output || '{}'); } catch(e) { return {ok:false,error:'流量服务返回异常'}; }
}
function save_storage(result) {
    if (!result.ok || result.used == null || result.total == null) return;
    let data={timestamp:time(),storage:result.storage || 'ME',used:+result.used,
        total:+result.total,full:+result.total > 0 && +result.used >= +result.total};
    if (writefile('/tmp/kk-car-dji-sms-storage.json.new',sprintf('%J',data))) {
        chmod('/tmp/kk-car-dji-sms-storage.json.new',0600);
        rename('/tmp/kk-car-dji-sms-storage.json.new','/tmp/kk-car-dji-sms-storage.json');
    }
}
function sms_badges() {
    let badges=filejson('/tmp/kk-car-sms-badge.json');
    return fresh(badges,120) && type(badges.groups)=='array' ? badges : null;
}
function save_sms_seen(id) {
    let path='/etc/kk-car/private/dji-sms-seen.json';
    let seen=filejson(path), ids=type(seen.ids)=='object' ? seen.ids : {};
    ids[id]=true;
    let temp=path+'.new';
    if (!writefile(temp,sprintf('%J',{ids}))) return false;
    chmod(temp,0600);
    return rename(temp,path);
}
function sms_index(input) {
    let result = '' + input;
    return match(result,/^(0|[1-9][0-9]{0,2})$/) && +result <= 255 ? result : null;
}
function at_available() {
    return access('/etc/kk-car/dji-at-status.sh') && access('/usr/bin/socat');
}
function sms_available() {
    return access('/etc/kk-car/dji-sms.uc') && access('/usr/bin/socat');
}
function modem_available(modem) {
    return fresh(modem,120) && modem.online == true && modem.transport == 'QMI';
}
function refresh_if_needed(modem, info) {
    if (!modem_available(modem) || !at_available() || fresh(info,120)) return;
    if (access('/tmp/kk-car-dji-control-lock')) return;
    let last = +(readfile('/tmp/kk-car-dji-last-at-attempt') || '0');
    if (time() - last < 60) return;
    writefile('/tmp/kk-car-dji-last-at-attempt','' + time());
    system('/etc/kk-car/dji-control.sh refresh </dev/null >/dev/null 2>&1 &');
}
function state(auto_refresh) {
    let bus=connect(), c=cursor();
    let modem=filejson('/tmp/kk-car-modem.json');
    let info=filejson('/tmp/kk-car-dji-at.json');
    let storage=filejson('/tmp/kk-car-dji-sms-storage.json');
    let uplink=filejson('/tmp/kk-car-uplink.json');
    let job=filejson('/tmp/kk-car-dji-job.json');
    let sms_forward=filejson('/tmp/kk-car-sms-forward-status.json');
    let available=modem_available(modem);
    if (!fresh(info,600)) info={};
    if (!fresh(storage,600)) storage={};
    if (auto_refresh) refresh_if_needed(modem, info);
    let cell=read_cellular(bus);
    let qmi=c.get('network','wan','proto') == 'qmi';
    let sms=available && sms_available();
    let metrics=(cell.device && match(cell.device,/^(wwan|eth|usb)[0-9]+$/)) ? cell.device : null;
    let rx=metrics ? +(trim(readfile('/sys/class/net/'+metrics+'/statistics/rx_bytes') || '0')) : value(modem.rx);
    let tx=metrics ? +(trim(readfile('/sys/class/net/'+metrics+'/statistics/tx_bytes') || '0')) : value(modem.tx);
    return {
        ok:true,available,reason:available ? '' : '未检测到已工作的 DJI QMI 模块',
        updated_at:modem.timestamp || null,
        identity:{model:available ? (modem.model || 'DJI 4G') : null,firmware:info.firmware || null},
        sim:{state:available ? (modem.sim_state || 'unknown') : 'unknown',
            pin_state:info.sim_pin_state || 'unknown'},
        radio:{registered:available ? modem.registration == 'registered' : false,
            operator:available ? (modem.operator || null) : null,
            technology:available ? (info.technology || modem.network || null) : null,
            band:info.band || null,channel:info.channel || null,
            duplex:info.duplex || null,mcc:info.mcc || null,mnc:info.mnc || null,
            cell_id:info.cell_id || null,tac:info.tac || null,pci:value(info.pci),
            earfcn:value(info.earfcn),ul_bandwidth_mhz:value(info.ul_bandwidth_mhz),
            dl_bandwidth_mhz:value(info.dl_bandwidth_mhz),
            rsrp:available ? value(modem.rsrp) : null,
            rsrq:available ? value(modem.rsrq) : null,
            sinr:available ? value(info.sinr_db) : null,
            snr:available ? value(modem.snr) : null,
            rssi:available ? value(modem.rssi) : null,
            neighbours:info.neighbours || {intra_count:null,inter_count:null,best_rsrp_dbm:null}},
        session:{connected:available ? modem.connected == true : false,
            device:available ? (cell.device || null) : null,
            ip:available && cell.up ? cell.ip : null,
            rx_bytes:available ? rx : null,tx_bytes:available ? tx : null,
            uptime:available && cell.up ? cell.uptime : null,
            active_uplink:uplink.active || 'none'},
        temperature_c:value(info.module_temperature_c),
        capabilities:{refresh:available && access('/etc/kk-car/dji-control.sh'),
            reconnect:available && qmi && access('/etc/kk-car/dji-control.sh'),
            sms_read:sms,sms_send:sms,sms_delete:sms,
            gps:available && sms && type(info.gps_enabled) == 'bool',
            gps_start:available && sms && info.gps_enabled == false,
            gps_stop:available && sms && info.gps_enabled == true},
        sms:{storage:storage.storage || null,used:value(storage.used),
            capacity:value(storage.total),full:storage.full == true,
            updated_at:storage.timestamp || null},
        sms_forward:{enabled:sms_forward.enabled == true,initialized:sms_forward.initialized == true,
            pending:+(sms_forward.pending || 0),last_success:sms_forward.last_success || null,
            error:sms_forward.error || null},
        gps:{supported:type(info.gps_enabled) == 'bool',enabled:info.gps_enabled == true,
            fix:false,lat:null,lon:null,speed_kmh:null,updated_at:null},
        job
    };
}
function start_action(kind) {
    if (kind == 'gps_start' || kind == 'gps_stop') {
        let s=state(false);
        if (!s.available || !s.capabilities.gps) return {ok:false,error:'定位接口当前不可用'};
        let result=call_sms(kind,null);
        if (result.ok) {
            // Refresh the cached state; GPS commands never restart the network.
            system('/etc/kk-car/dji-control.sh refresh </dev/null >/dev/null 2>&1 &');
        }
        return result;
    }
    if (kind != 'refresh' && kind != 'reconnect') return {ok:false,error:'不支持的操作'};
    let s=state(false);
    if (!s.available) return {ok:false,error:'DJI 模块当前不可用'};
    if (kind == 'reconnect' && !s.capabilities.reconnect) return {ok:false,error:'当前无法重新连接 DJI 模块'};
    if (access('/tmp/kk-car-dji-control-lock')) return {ok:false,error:'DJI 模块正在处理上一项操作'};
    if (kind == 'reconnect' && access('/tmp/kk-car-ui-lock')) return {ok:false,error:'其他网络操作正在进行'};
    if (kind == 'reconnect' && !mkdir('/tmp/kk-car-ui-lock',0700)) return {ok:false,error:'其他网络操作正在进行'};
    let command='/etc/kk-car/dji-control.sh ' + kind + ' </dev/null >/dev/null 2>&1 &';
    if (system(command) != 0) {
        if (kind == 'reconnect') rmdir('/tmp/kk-car-ui-lock');
        return {ok:false,error:'操作未能启动'};
    }
    return {ok:true,accepted:true};
}

return {'kkdji': {
    status:{call:function() { return state(true); }},
    traffic_status:{call:function() {
        let data=filejson('/tmp/kk-car-dji-traffic.json');
        return data.timestamp ? {ok:true,data} : {ok:false,error:'流量统计尚未采样'};
    }},
    traffic_save:{args:{operator:'',recipient:'',command:'',daily:false,hour:9},call:function(req) {
        let a=req.args;
        if (a.operator!='CT' && a.operator!='CMCC' && a.operator!='CU') return {ok:false,error:'请选择运营商'};
        if (type(a.recipient)!='string' || !match(a.recipient,/^[0-9]{3,6}$/) ||
            type(a.command)!='string' || !match(a.command,/^[A-Za-z0-9]{1,20}$/) ||
            type(a.daily)!='bool' || type(a.hour)!='int' || a.hour<0 || a.hour>23)
            return {ok:false,error:'查询号码、指令或时间格式不正确'};
        let path='/etc/kk-car/private/dji-traffic-config.json', temp=path+'.new';
        if (!writefile(temp,sprintf('%J',{operator:a.operator,recipient:a.recipient,
            command:a.command,daily:a.daily,hour:a.hour}))) return {ok:false,error:'无法保存设置'};
        chmod(temp,0600);
        if (!rename(temp,path)) return {ok:false,error:'无法保存设置'};
        return {ok:true};
    }},
    traffic_query:{call:function() { return call_traffic('query'); }},
    action:{args:{action:''},call:function(req) {return start_action(req.args.action);}},
    sms_list:{call:function() {
        if (!state(false).capabilities.sms_read) return {ok:false,error:'短信功能不可用'};
        let result=call_sms('list',null); save_storage(result);
        let badges=sms_badges();
        if (result.ok && badges && badges.storage==result.storage && type(result.groups)=='array') {
            for (let group in result.groups) {
                let badge=filter(badges.groups,b=>b.index==group.index && b.from==group.from && b.time==group.time)[0];
                group.ui_unread=badge ? badge.unread==true : (group.status=='已发' || group.status=='待发' ? false : null);
                group.ui_baseline=badge ? badge.baseline==true : false;
                group.badge_id=badge ? badge.id : null;
            }
        }
        return result;
    }},
    sms_ack:{args:{id:''},call:function(req) {
        let id=req.args.id;
        if (type(id)!='string' || !match(id,/^[0-9a-f]{64}$/)) return {ok:false,error:'短信标识无效'};
        let badges=sms_badges();
        if (!badges || !length(filter(badges.groups,b=>b.id==id)))
            return {ok:false,error:'短信目录已变化，请刷新'};
        return save_sms_seen(id) ? {ok:true} : {ok:false,error:'未能保存已读状态'};
    }},
    voice_probe:{call:function() {
        if (!state(false).capabilities.sms_read) return {ok:false,error:'模块控制接口不可用'};
        return call_sms('voice_probe',null);
    }},
    call_status:{call:function() {
        if (!state(false).capabilities.sms_read) return {ok:false,error:'模块控制接口不可用'};
        return call_sms('call_status',null);
    }},
    phone_data:{call:function(){return get_data();}},
    phone_contact_save:{args:{name:'',number:''},call:function(req){
        return save_contact(req.args.name,req.args.number);
    }},
    phone_contact_delete:{args:{number:''},call:function(req){
        return delete_contact(req.args.number);
    }},
    call_dial:{args:{number:''},call:function(req) {
        if (!state(false).capabilities.sms_read) return {ok:false,error:'模块控制接口不可用'};
        let number=req.args.number;
        if (type(number)!='string' || !match(number,/^\+?[0-9]{3,15}$/)) return {ok:false,error:'号码格式不正确'};
        let result=call_sms('call_dial',number);
        if (result.ok) seed_outgoing(number);
        return result;
    }},
    call_answer:{call:function() {
        if (!state(false).capabilities.sms_read) return {ok:false,error:'模块控制接口不可用'};
        return call_sms('call_answer',null);
    }},
    call_hangup:{call:function() {
        if (!state(false).capabilities.sms_read) return {ok:false,error:'模块控制接口不可用'};
        return call_sms('call_hangup',null);
    }},
    voice_ticket:{call:function() {
        if (system('/etc/kk-car/dji-voice-health.sh >/dev/null 2>&1')!=0)
            return {ok:false,error:'模块音频路由未就绪'};
        let random=popen('head -c 32 /dev/urandom | hexdump -v -e \'1/1 "%02x"\'');
        let token=random ? trim(random.read('all') || '') : '';
        if (random) random.close();
        if (!match(token,/^[0-9a-f]{64}$/)) return {ok:false,error:'无法创建音频会话'};
        let path='/tmp/kk-car-voice-ticket.json';
        if (!writefile(path,sprintf('%J',{token,expires:time()+30})))
            return {ok:false,error:'无法创建音频会话'};
        chmod(path,0600);
        return {ok:true,token,expires:time()+30};
    }},
    gps_probe:{call:function() {
        if (!state(false).capabilities.gps) return {ok:false,error:'定位接口当前不可用'};
        return call_sms('gps_probe',null);
    }},
    sms_read:{args:{index:''},call:function(req) {
        if (!state(false).capabilities.sms_read) return {ok:false,error:'短信功能不可用'};
        let n=sms_index(req.args.index);
        return n == null ? {ok:false,error:'短信序号无效'} : call_sms('read',n);
    }},
    sms_delete:{args:{index:''},call:function(req) {
        if (!state(false).capabilities.sms_delete) return {ok:false,error:'短信功能不可用'};
        let n=sms_index(req.args.index);
        if (n == null) return {ok:false,error:'短信序号无效'};
        let result=call_sms('delete',n);
        if (result.ok) save_storage(call_sms('storage',null));
        return result;
    }},
    sms_send:{args:{to:'',text:''},call:function(req) {
        if (!state(false).capabilities.sms_send) return {ok:false,error:'短信功能不可用'};
        let to=req.args.to, body=req.args.text;
        if (type(to) != 'string' || !match(to,/^\+?[0-9]{3,15}$/)) return {ok:false,error:'收件号码格式不正确'};
        if (type(body) != 'string' || !length(body) || length(body) > 640 || match(body,/[[:cntrl:]]/))
            return {ok:false,error:'短信内容须为 1–640 字节且不能含控制字符'};
        if (!mkdir('/tmp/kk-car-dji-sms-request-lock',0700)) return {ok:false,error:'另一条短信操作正在进行'};
        let request='/tmp/kk-car-dji-sms-request-lock/request.json';
        let ok=writefile(request,sprintf('%J',{to,text:body}));
        if (ok) chmod(request,0600);
        let result=ok ? call_sms('send',request) : {ok:false,error:'无法提交短信'};
        unlink(request); rmdir('/tmp/kk-car-dji-sms-request-lock');
        return result;
    }}
}};
