'use strict';
import { readfile, writefile, popen, access, mkdir, rmdir, chmod, lsdir } from 'fs';
import { connect } from 'ubus';

const services=['epaper','hdmi','auto-check','diagnostics','modem','vpn-ping',
    'notify','dji-sms-forward','voice-runtime','voice-gateway'];
function filejson(p){try{return json(readfile(p)||'{}');}catch(e){return {};}}
function quote(s){return "'"+replace(s,/'/g,"'\\''")+"'";}
function config(operation, input){
    let p=popen('/usr/bin/python3 /etc/kk-car/device_settings.py '+operation+
        (input==null?'':' '+quote(sprintf('%J',input)))+' 2>/dev/null');
    if(!p)return {ok:false,error:'设置服务暂不可用'};
    let raw=p.read('all');p.close();
    try{return json(raw||'{}');}catch(e){return {ok:false,error:'设置服务返回异常'};}
}
function service_state(name,bus,entries){
    let id='kk-car-'+name,installed=access('/etc/init.d/'+id),running=false,known=false;
    try {let data=bus.call('service','list',{name:id});known=type(data)=='object';
        for(let key,instance in data?.[id]?.instances||{})if(instance.running===true)running=true;
    }catch(e){}
    let enabled=false;for(let entry in entries)if(match(entry,/^S[0-9]+/)&&substr(entry,-length(id))==id)enabled=true;
    return {name,installed,running,known,enabled};
}
function status(){
    let result=config('get'),bus=connect(),entries=lsdir('/etc/rc.d')||[],states=[];
    for(let name in services)push(states,service_state(name,bus,entries));
    result.services=states;result.epaper=filejson('/tmp/kk-car-epaper-status.json');
    result.hdmi=filejson('/tmp/kk-car-hdmi-status.json');
    result.check=filejson('/tmp/kk-car-auto-check.json');
    result.job=filejson('/tmp/kk-car-settings-job.json');
    result.busy=!!access('/tmp/kk-car-settings-service-lock');result.timestamp=time();return result;
}
function service_set(a){
    if(index(services,a.name)<0||index(['start','stop','restart','enable','disable'],a.action)<0)
        return {ok:false,error:'不支持的服务或操作'};
    let s=service_state(a.name,connect(),lsdir('/etc/rc.d')||[]);
    if(!s.installed||!s.known)return {ok:false,error:'服务未安装或状态无法确认'};
    let before=index(['enable','disable'],a.action)>=0?s.enabled:s.running;
    if(before!==a.expected)return {ok:false,conflict:true,error:'服务状态已改变，请刷新后再操作'};
    if(!mkdir('/tmp/kk-car-settings-service-lock',0700))return {ok:false,error:'另一项服务操作仍在进行'};
    writefile('/tmp/kk-car-settings-job.json',sprintf('%J',{state:'running',name:a.name,action:a.action,timestamp:time()}));
    chmod('/tmp/kk-car-settings-job.json',0600);
    let exit=system('/usr/bin/python3 /etc/kk-car/device_settings.py service-run '+a.name+' '+a.action+' </dev/null >/dev/null 2>&1 &');
    if(exit!=0){rmdir('/tmp/kk-car-settings-service-lock');return {ok:false,error:'无法启动服务操作'};}
    return {ok:true,accepted:true};
}
return {'kksettings':{
    status:{call:function(){return status();}},
    save:{args:{settings:'',revision:0},call:function(req){
        let settings;try{settings=json(req.args.settings);}catch(e){return {ok:false,error:'设置格式无效'};}
        return config('save',{settings,revision:req.args.revision});
    }},
    service_set:{args:{name:'',action:'',expected:false},call:function(req){return service_set(req.args);}},
    refresh_screen:{call:function(){
        let s=service_state('epaper',connect(),lsdir('/etc/rc.d')||[]);
        if(!s.running)return {ok:false,error:'请先启动电子纸服务'};
        let seq=+(readfile('/tmp/kk-car-epaper-refresh')||'0')+1;
        if(!writefile('/tmp/kk-car-epaper-refresh',''+seq))return {ok:false,error:'无法发起清屏'};
        return {ok:true,accepted:true,sequence:seq};
    }}
}};
