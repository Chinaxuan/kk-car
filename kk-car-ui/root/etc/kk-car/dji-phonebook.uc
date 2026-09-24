'use strict';
import {readfile,writefile,rename,chmod,mkdir,rmdir} from 'fs';

const path='/etc/kk-car/private/dji-phonebook.json';
const lock='/tmp/kk-car-dji-phonebook.lock';
function blank(){return {version:1,active:null,history:[],contacts:[]};}
function load(){
    try {
        let d=json(readfile(path));
        return d && d.version==1 && type(d.history)=='array' && type(d.contacts)=='array' ? d : blank();
    } catch(e){return blank();}
}
function save(d){
    mkdir('/etc/kk-car/private',0700);
    if (!writefile(path+'.new',sprintf('%J',d))) return false;
    chmod(path+'.new',0600);
    return rename(path+'.new',path);
}
function guarded(fn){
    if (!mkdir(lock,0700)) return false;
    let result=false;
    try {result=fn();} catch(e) {}
    rmdir(lock);
    return result;
}
function clean_number(n){return type(n)=='string' && match(n,/^\+?[0-9]{3,15}$/) ? n : null;}
function seed_outgoing(number){
    number=clean_number(number);
    if (!number) return false;
    return guarded(function(){
        let d=load();
        if (d.active) {
            if (d.active.direction!='outgoing' || d.active.number) return false;
            d.active.number=number;
            return save(d);
        }
        d.active={direction:'outgoing',number,started_at:time(),connected_at:null};
        return save(d);
    });
}
function observe(call){
    if (!call || call.ok!=true) return false;
    return guarded(function(){
        let d=load(),now=time(),a=d.active,active=+call.count>0;
        if (active) {
            let direction=call.direction=='incoming'?'incoming':'outgoing';
            let number=clean_number(call.number),changed=false;
            if (!a) {a={direction,number,started_at:now,connected_at:null};changed=true;}
            if (!a.number && number) {a.number=number;changed=true;}
            if (call.state=='通话中' && !a.connected_at) {a.connected_at=now;changed=true;}
            d.active=a;
            return changed ? save(d) : true;
        }
        if (!a) return true;
        let kind=a.direction=='incoming'?(a.connected_at?'已接':'未接'):(a.connected_at?'已拨':'未接通');
        d.history=[{id:now+'-'+a.started_at,kind,
            direction:a.direction,number:a.number || null,started_at:a.started_at,
            connected_at:a.connected_at || null,duration_s:a.connected_at?max(0,now-a.connected_at):0},...d.history];
        d.history=slice(d.history,0,100);d.active=null;
        return save(d);
    });
}
function get_data(){let d=load();return {ok:true,active:d.active,history:d.history,contacts:d.contacts};}
function save_contact(name,number){
    number=clean_number(number);
    if (type(name)!='string') return {ok:false,error:'联系人名称无效'};
    name=trim(replace(name,/[[:cntrl:]]/g,''));
    if (!number || !length(name) || length(name)>40) return {ok:false,error:'请填写名称和有效号码'};
    let ok=guarded(function(){
        let d=load(),found=false;
        for(let c in d.contacts) if(c.number==number){c.name=name;found=true;break;}
        if(!found){if(length(d.contacts)>=100)return false;push(d.contacts,{name,number});}
        return save(d);
    });
    return ok?{ok:true}:{ok:false,error:'联系人保存失败或已达上限'};
}
function delete_contact(number){
    number=clean_number(number);
    if (!number) return {ok:false,error:'号码无效'};
    let ok=guarded(function(){let d=load();d.contacts=filter(d.contacts,c=>c.number!=number);return save(d);});
    return ok?{ok:true}:{ok:false,error:'联系人删除失败'};
}
export {observe,seed_outgoing,get_data,save_contact,delete_contact};
