'use strict';
import { readfile, writefile, rename, mkdir, chmod } from 'fs';
const path='/etc/kk-car/private/notify.json';
const kinds=['vpn_up','vpn_down','boot','shutdown','abnormal_boot','latency','loss','client_join','client_leave','uplink','signal','power','temperature','recovery','sms_received','incoming_call','missed_call'];
function defaults() {
    let events={}; for(let k in kinds) events[k]=k!='client_leave' && k!='sms_received';
    return {enabled:false,revision:0,events,latency_ms:300,loss_percent:50,hold_seconds:30,cooldown_seconds:300,signal_dbm:-115,temperature_c:80,
        destinations:[{id:'primary',name:'飞书机器人',enabled:false,url:''},{id:'second',name:'备用群 1',enabled:false,url:''},{id:'third',name:'备用群 2',enabled:false,url:''}]};
}
function read_config() {
    try {
        let saved=json(readfile(path)) || defaults(), base=defaults();
        // Preserve existing switches and destinations when new event kinds
        // are added. SMS contents remain opt-in.
        saved.events={...base.events,...(saved.events || {})};
        return saved;
    } catch(e) {return defaults();}
}
function valid_url(s) {return type(s)=='string' && !!match(s,/^https:\/\/open\.feishu\.cn\/open-apis\/bot\/v2\/hook\/[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/);}
function public_config(c) {
    let out={...c,destinations:[]};
    for(let d in c.destinations) push(out.destinations,{id:d.id,name:d.name,enabled:d.enabled,configured:!!d.url});
    return out;
}
function validate_config(input,old) {
    let c=defaults();
    if(type(input)!='object' || type(input.enabled)!='bool' || type(input.events)!='object') return {ok:false,error:'推送设置格式不正确'};
    c.enabled=input.enabled;c.revision=(old.revision || 0)+1;
    for(let k in kinds) {if(type(input.events[k])!='bool') return {ok:false,error:'缺少事件开关'};c.events[k]=input.events[k];}
    let ranges={latency_ms:[50,5000],loss_percent:[1,100],hold_seconds:[10,600],cooldown_seconds:[60,86400],signal_dbm:[-140,-60],temperature_c:[50,95]};
    for(let k,r in ranges) {let n=input[k];if(type(n)!='int' || n<r[0] || n>r[1]) return {ok:false,error:'阈值超出允许范围：'+k};c[k]=n;}
    if(type(input.destinations)!='array' || length(input.destinations)!=3) return {ok:false,error:'推送地址数量不正确'};
    for(let i=0;i<3;i++) {
        let d=input.destinations[i],prev=old.destinations[i],slot=c.destinations[i];
        if(type(d)!='object' || d.id!=slot.id || type(d.enabled)!='bool' || type(d.name)!='string' || length(d.name)>60 || match(d.name,/[[:cntrl:]]/)) return {ok:false,error:'推送地址设置不正确'};
        if(d.url!=null && type(d.url)!='string') return {ok:false,error:'Webhook 格式不正确'};
        let url=d.clear ? '' : d.url || prev?.url || '';
        if(url && !valid_url(url)) return {ok:false,error:'只支持飞书自定义机器人 HTTPS Webhook'};
        if(d.enabled && !url) return {ok:false,error:'启用地址前请填写 Webhook'};
        c.destinations[i]={id:slot.id,name:d.name || slot.name,enabled:d.enabled,url};
    }
    if(c.enabled && !length(filter(c.destinations,d=>d.enabled && d.url))) return {ok:false,error:'请至少启用一个已配置的推送地址'};
    return {ok:true,config:c};
}
function save_config(input) {
    let v=validate_config(input,read_config());if(!v.ok)return v;
    mkdir('/etc/kk-car/private',0700);chmod('/etc/kk-car/private',0700);
    if(!writefile(path+'.new',sprintf('%J',v.config))) return {ok:false,error:'无法保存推送设置'};
    chmod(path+'.new',0600);
    if(!rename(path+'.new',path)) return {ok:false,error:'无法替换推送设置'};
    return {ok:true,config:public_config(v.config)};
}
export {defaults,read_config,public_config,validate_config,save_config,valid_url};
