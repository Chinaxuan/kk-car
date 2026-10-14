'use strict';
import { readfile, writefile, popen, mkdir, rmdir, chmod, unlink, access, rename } from 'fs';

function filejson(path) { try { return json(readfile(path) || '{}'); } catch(e) { return {}; } }
function run(command) {
    let p=popen(command+' 2>/dev/null');
    if (!p) return {ok:false,error:'服务暂不可用'};
    let output=p.read('all') || ''; p.close();
    try { let result=json(output);return type(result)=='object' && type(result.ok)=='bool' ? result : {ok:false,error:'服务返回异常'}; }
    catch(e) { return {ok:false,error:'服务返回异常'}; }
}
function manager(action,token) {
    return run('/usr/bin/python3 /etc/kk-car/esim-manager.py '+action+(token?' '+token:''));
}
function sms(action,index) {
    return run('KK_CAR_SMS_ROLE=secondary /usr/bin/ucode /etc/kk-car/dji-sms.uc '+action+(index==null?'':' '+index));
}
function index_value(value) {
    let s=''+value;
    return match(s,/^(0|[1-9][0-9]{0,2})$/) && +s<=255 ? s : null;
}
function save_seen(id) {
    let path='/etc/kk-car/private/esim-sms-seen.json';
    let data=filejson(path), ids=type(data.ids)=='object'?data.ids:{};
    ids[id]=true;
    let temp=path+'.new';
    if (!writefile(temp,sprintf('%J',{ids}))) return false;
    chmod(temp,0600);
    return rename(temp,path);
}
function status() {
    let s=manager('status');
    let forward=filejson('/tmp/kk-car-esim-sms-forward-status.json');
    s.sms={initialized:forward.initialized==true,unread:forward.unread_known==true?forward.unread_count:null,
        storage:forward.storage || null,used:forward.storage_used ?? null,
        capacity:forward.storage_capacity ?? null,last_success:forward.last_success || null,
        error:forward.error || null,updated_at:forward.timestamp || null};
    let tick=filejson('/tmp/kk-car-esim-tick.json');
    s.rotation_status=tick.error || null;
    return s;
}
return {'kkesim': {
    status:{call:function(){return status();}},
    sms_list:{call:function(){
        let result=sms('list');
        if (!result.ok || type(result.groups)!='array') return result;
        let badge=filejson('/tmp/kk-car-esim-sms-badge.json');
        let seen=filejson('/etc/kk-car/private/esim-sms-seen.json').ids || {};
        for (let group in result.groups) {
            let found=filter(badge.groups || [],b=>b.index==group.index && b.from==group.from && b.time==group.time)[0];
            group.ui_unread=found ? found.unread==true && seen[found.id]!=true : null;
            group.badge_id=found ? found.id : null;
        }
        return result;
    }},
    sms_read:{args:{index:''},call:function(req){
        let n=index_value(req.args.index);
        return n==null?{ok:false,error:'短信编号无效'}:sms('read',n);
    }},
    sms_history:{call:function(){
        let entries=filejson('/etc/kk-car/private/esim-sms-history-index.json').entries || [];
        let seen=filejson('/etc/kk-car/private/esim-sms-seen.json').ids || {};
        let state=filejson('/etc/kk-car/private/esim-sms-forward-state.json').entries || [];
        let result=[];
        for (let item in entries) {
            if (!match(item.id || '',/^[0-9a-f]{64}$/) ||
                !access('/etc/kk-car/private/esim-sms-history/'+item.id+'.der')) continue;
            let tracked=filter(state,e=>e.id==item.id)[0] || {};
            push(result,{id:item.id,from:item.from,time:item.time,
                archived_at:item.archived_at,unread:tracked.unread==true && seen[item.id]!=true});
        }
        return {ok:true,entries:slice(result,length(result)>500?length(result)-500:0)};
    }},
    sms_history_read:{args:{id:''},call:function(req){
        let id=req.args.id;
        if (type(id)!='string' || !match(id,/^[0-9a-f]{64}$/)) return {ok:false,error:'短信标识无效'};
        let index=filejson('/etc/kk-car/private/esim-sms-history-index.json').entries || [];
        if (!length(filter(index,e=>e.id==id))) return {ok:false,error:'短信历史不存在'};
        let base='/etc/kk-car/private/';
        let p=popen('openssl cms -decrypt -inform DER -in '+base+'esim-sms-history/'+id+'.der'+
            ' -recip '+base+'sms-local-cert.pem -inkey '+base+'sms-local-key.pem 2>/dev/null');
        if (!p) return {ok:false,error:'短信历史解密失败'};
        let raw=p.read('all') || '';p.close();
        if (length(raw)>16384) return {ok:false,error:'短信历史格式异常'};
        let item={};try {item=json(raw);}catch(e){return {ok:false,error:'短信历史解密失败'};}
        return type(item.text)=='string'?{ok:true,message:{id,from:item.from,time:item.time,text:item.text}}:
            {ok:false,error:'短信历史格式异常'};
    }},
    sms_ack:{args:{id:''},call:function(req){
        let id=req.args.id;
        if (type(id)!='string' || !match(id,/^[0-9a-f]{64}$/)) return {ok:false,error:'短信标识无效'};
        let history=filejson('/etc/kk-car/private/esim-sms-history-index.json').entries || [];
        let badge=filejson('/tmp/kk-car-esim-sms-badge.json').groups || [];
        if (!length(filter(history,e=>e.id==id)) && !length(filter(badge,e=>e.id==id)))
            return {ok:false,error:'短信目录已变化，请刷新'};
        return save_seen(id)?{ok:true}:{ok:false,error:'未能保存已读状态'};
    }},
    sms_send:{args:{to:'',text:''},call:function(req){
        let to=req.args.to,body=req.args.text;
        if (type(to)!='string' || !match(to,/^\+?[0-9]{3,15}$/) || type(body)!='string' ||
            !length(body) || length(body)>640 || match(body,/[[:cntrl:]]/))
            return {ok:false,error:'号码或短信内容格式不正确'};
        let dir='/tmp/kk-car-esim-sms-request', request=dir+'/request.json';
        if (!mkdir(dir,0700)) return {ok:false,error:'另一条短信操作正在进行'};
        let ok=writefile(request,sprintf('%J',{to,text:body}));
        if (ok) chmod(request,0600);
        let result=ok?sms('send',request):{ok:false,error:'无法提交短信'};
        unlink(request);rmdir(dir);
        return result;
    }},
    switch:{args:{token:''},call:function(req){
        let token=req.args.token;
        return type(token)=='string' && match(token,/^[0-9a-f]{64}$/)?manager('switch',token):
            {ok:false,error:'配置选择无效'};
    }},
    save:{args:{auto:false,interval_minutes:60,rotation:[]},call:function(req){
        let a=req.args, path='/tmp/kk-car-esim-request';
        if (type(a.auto)!='bool' || type(a.interval_minutes)!='int' ||
            a.interval_minutes<30 || a.interval_minutes>1440 || type(a.rotation)!='array' ||
            length(a.rotation)>8 || length(filter(a.rotation,t=>type(t)!='string' || !match(t,/^[0-9a-f]{64}$/))))
            return {ok:false,error:'自动切卡设置无效'};
        if (!mkdir(path,0700)) return {ok:false,error:'另一项设置正在保存'};
        let request=path+'/config.json';
        let ok=writefile(request,sprintf('%J',a));
        if (ok) chmod(request,0600);
        let result=ok?manager('save'):{ok:false,error:'无法保存设置'};
        unlink(request);rmdir(path);
        return result;
    }}
}};
