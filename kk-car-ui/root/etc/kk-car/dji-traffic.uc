#!/usr/bin/ucode
'use strict';
// Persistent modem-interface counters and a conservative carrier SMS anchor.
// No SMS body, phone number or credentials are persisted by this worker.
import { readfile, writefile, rename, chmod, popen, mkdir, unlink, rmdir } from 'fs';
import { connect } from 'ubus';
import { parse_balance } from '/etc/kk-car/dji-traffic-parse.uc';

const config_path='/etc/kk-car/private/dji-traffic-config.json';
const state_path='/etc/kk-car/private/dji-traffic-state.json';
const public_path='/tmp/kk-car-dji-traffic.json';
function read(path) { try { return json(readfile(path) || '{}'); } catch(e) { return {}; } }
function save(path,data) {
    let temp=path+'.new';
    if (!writefile(temp,sprintf('%J',data))) return false;
    chmod(temp,0600);
    return rename(temp,path);
}
function run(cmd) {
    let p=popen(cmd+' 2>/dev/null');
    if (!p) return '';
    let out=trim(p.read('all') || ''); p.close(); return out;
}
function defaults() { return {operator:'CT',recipient:'10001',command:'108',daily:false,hour:9}; }
function config() {
    let c=read(config_path), d=defaults();
    for (let key in ['operator','recipient','command','daily','hour']) if (c[key]!=null) d[key]=c[key];
    return d;
}
function day() { return run('date +%Y-%m-%d'); }
function month(today) { return substr(today,0,7); }
function hour() { return +run('date +%H'); }
function counter(device,kind) {
    if (!match(device || '',/^(wwan|usb|eth)[0-9]+$/)) return null;
    let raw=trim(readfile('/sys/class/net/'+device+'/statistics/'+kind+'_bytes') || '');
    return match(raw,/^[0-9]{1,18}$/) ? +raw : null;
}
function sms(action,index) {
    let raw=run('/usr/bin/ucode /etc/kk-car/dji-sms.uc '+action+(index==null?'':' '+index));
    try { return json(raw); } catch(e) { return null; }
}
function body(group) {
    let text='';
    for (let i=0;i<length(group.parts || []);i++) {
        let slot=group.parts[i];
        if (type(slot)!='int' || slot<0 || slot>255) return null;
        let response=sms('read',slot), m=response?.message;
        if (!response?.ok || type(m?.text)!='string' || m.from!=group.from) return null;
        if (group.concat && (!m.concat || m.concat.ref!=group.concat.ref ||
            m.concat.total!=group.concat.total || m.concat.part!=i+1)) return null;
        text+=m.text;
    }
    return text;
}
function sample(state,today,modem) {
    let device=modem?.session?.device;
    let rx=counter(device,'rx'), tx=counter(device,'tx');
    if (state.day_key!=today) { state.day_key=today; state.day={rx:0,tx:0}; }
    if (state.month_key!=month(today)) { state.month_key=month(today); state.month={rx:0,tx:0}; }
    if (!state.total) state.total={rx:0,tx:0};
    if (rx==null || tx==null) { state.last_device=null; return; }
    if (state.last_device==device && rx>=state.last_rx && tx>=state.last_tx) {
        let dr=rx-state.last_rx, dt=tx-state.last_tx;
        for (let bucket in [state.day,state.month,state.total]) { bucket.rx+=dr; bucket.tx+=dt; }
    }
    else if (state.last_device==device && state.last_rx!=null && (rx<state.last_rx || tx<state.last_tx))
        state.resets=(state.resets || 0)+1;
    state.last_device=device;state.last_rx=rx;state.last_tx=tx;
}
function scan_reply(state,c,today,import_today) {
    if (c.operator!='CT' && c.operator!='CMCC' && c.operator!='CU') return;
    let list=sms('list',null);
    if (!list?.ok || type(list.groups)!='array') return;
    let chosen=null;
    for (let group in list.groups) {
        if (!group.complete || group.from!=c.recipient || !match(group.time || '',/^20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$/)) continue;
        // Scheduled/manual queries only accept a reply sent after the request.
        if (state.pending_time && group.time<state.pending_time) continue;
        // Explicit first import is limited to today's already-received response.
        if (!state.pending_time && (!import_today || substr(group.time,0,10)!=today)) continue;
        if (!chosen || group.time>chosen.time) chosen=group;
    }
    if (!chosen || chosen.time==state.reply_time) return false;
    let text=body(chosen);
    if (text==null) return false;
    let parsed=parse_balance(text,c.operator);
    if (!parsed) {
        state.parse_error='回复已收到，但未能唯一识别国内通用流量；统计未校正';
        state.pending_time=null;state.reply_time=chosen.time;return true;
    }
    state.anchor={used_bytes:parsed.used_bytes,remaining_bytes:parsed.remaining_bytes,
        package:parsed.package,operator:c.operator,local_total:(state.total?.rx || 0)+(state.total?.tx || 0),time:chosen.time};
    state.reply_time=chosen.time;state.pending_time=null;state.parse_error=null;
    if (import_today) state.last_query_day=today;
    return true;
}
function query(state,c,today,automatic) {
    if (automatic && state.last_query_day==today) return {ok:false,error:'今天已查询'};
    if (!automatic && state.last_query_epoch && time()-state.last_query_epoch<300)
        return {ok:false,error:'查询过于频繁，请 5 分钟后再试'};
    if (!match(c.recipient || '',/^[0-9]{3,6}$/) || !match(c.command || '',/^[A-Za-z0-9]{1,20}$/))
        return {ok:false,error:'查询号码或指令无效'};
    // Do not call kkdji from its own traffic_query RPC worker: rpcd may be
    // single-threaded. Use the same exclusive request lock as sms_send.
    let dir='/tmp/kk-car-dji-sms-request-lock';
    if (!mkdir(dir,0700)) return {ok:false,error:'短信操作正在进行'};
    let request=dir+'/request.json', reply={ok:false,error:'无法提交短信'};
    if (writefile(request,sprintf('%J',{to:c.recipient,text:c.command}))) {
        chmod(request,0600);reply=sms('send',request) || reply;
    }
    unlink(request);rmdir(dir);
    state.last_query_epoch=time();
    if (automatic) state.last_query_day=today;
    if (!reply?.ok) return {ok:false,error:reply?.error || '模块未确认发送'};
    state.last_query_day=today;
    state.pending_time=run('date +%Y-%m-%d\\ %H:%M:%S');
    state.parse_error=null;
    return {ok:true,accepted:true};
}
function publish(state,c) {
    let anchor=state.anchor?.operator==c.operator ? state.anchor : null;
    let delta=anchor ? max(0,(state.total?.rx || 0)+(state.total?.tx || 0)-anchor.local_total) : 0;
    return {timestamp:time(),config:c,day:state.day || {rx:0,tx:0},
        month:state.month || {rx:0,tx:0},total:state.total || {rx:0,tx:0},
        resets:state.resets || 0,anchor,
        estimated_used:anchor ? anchor.used_bytes+delta : null,
        estimated_remaining:anchor ? max(0,anchor.remaining_bytes-delta) : null,
        last_query_day:state.last_query_day || null,pending:!!state.pending_time,
        parse_error:state.parse_error || null};
}
let mode=ARGV[0] || 'tick', c=config(), state=read(state_path), today=day();
if (!state.day || !state.month || !state.total) state={day_key:today,month_key:month(today),day:{rx:0,tx:0},month:{rx:0,tx:0},total:{rx:0,tx:0}};
if (mode=='tick' || mode=='query' || mode=='import_today') {
    let changed=false;
    let modem=mode=='query' ? null : connect().call('kkdji','status',{});
    if (mode!='query') sample(state,today,modem);
    if (mode=='query') { print(sprintf('%J',query(state,c,today,false))+'\n');changed=true; }
    else if (mode=='tick' && c.daily==true && hour()>=+c.hour && state.last_query_day!=today && modem?.capabilities?.sms_send==true) {
        query(state,c,today,true);changed=true;
    }
    if (mode=='import_today' || (state.pending_time && (!state.last_scan || time()-state.last_scan>=60))) {
        changed=scan_reply(state,c,today,mode=='import_today') || changed;state.last_scan=time();
    }
    if (mode!='tick' || changed || !state.last_save || time()-state.last_save>=300) {
        state.last_save=time();save(state_path,state);
    }
    save(public_path,publish(state,c));
}
