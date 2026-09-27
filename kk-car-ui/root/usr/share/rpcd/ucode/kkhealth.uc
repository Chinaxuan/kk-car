'use strict';
import { popen } from 'fs';
function quote(value){return "'"+replace(value,/'/g,"'\\''")+"'";}
function invoke(mode,input){
    let p=popen('/usr/bin/python3 /etc/kk-car/network_health.py '+mode+
        (input==null?'':' '+quote(sprintf('%J',input)))+' 2>/dev/null');
    if(!p)return {ok:false,error:'网络守护服务不可用'};
    let raw=p.read('all');p.close();
    try{return json(raw||'{}');}catch(e){return {ok:false,error:'网络守护响应无效'};}
}
return {'kkhealth':{
    status:{call:function(){return invoke('status');}},
    save:{args:{settings:'',revision:0},call:function(req){
        let values;try{values=json(req.args.settings);}catch(e){return {ok:false,error:'设置格式无效'};}
        return invoke('save',{settings:values,revision:req.args.revision});
    }},
    check:{call:function(){return invoke('check');}}
}};
