#!/usr/bin/ucode
'use strict';
// Poll new modem SMS and send their complete text to enabled Feishu robots.
// Plaintext exists only in this process and root-only tmpfs files. The SD
// archives are encrypted to a public certificate; its private key stays off
// the router. On-card dedupe state contains hashes and flags only.
import { readfile, writefile, rename, chmod, mkdir, unlink, rmdir, popen, stat } from 'fs';
import { read_config, valid_url } from '/etc/kk-car/notify-config.uc';

const dir='/tmp/kk-car-sms-forward';
const state_path='/etc/kk-car/private/dji-sms-forward-state.json';
const status_path='/tmp/kk-car-sms-forward-status.json';
const badge_path='/tmp/kk-car-sms-badge.json';
const seen_path='/etc/kk-car/private/dji-sms-seen.json';
const archive_dir='/etc/kk-car/private/sms-archive';
const recipient='/etc/kk-car/private/sms-archive-recipient.pem';
function parse(path) { try { return json(readfile(path) || ''); } catch(e) { return null; } }
function save(path, value) {
    let temp=path+'.new';
    if (!writefile(temp,sprintf('%J',value))) return false;
    chmod(temp,0600);
    return rename(temp,path);
}
function run(command) {
    let p=popen(command+' 2>/dev/null');
    if (!p) return '';
    let output=trim(p.read('all') || ''); p.close(); return output;
}
function sms(action,index) {
    let raw=run('/usr/bin/ucode /etc/kk-car/dji-sms.uc '+action+(index==null?'':' '+index));
    try { return json(raw); } catch(e) { return null; }
}
function fingerprint(state,group) {
    // CMGD compacts slot indexes; including them here would re-send surviving
    // messages after any deletion. Sender/time/concat stay stable across moves.
    let value=[state.salt,group.storage,group.from,group.time,group.concat];
    if (!writefile(dir+'/hash-input',sprintf('%J',value))) return null;
    chmod(dir+'/hash-input',0600);
    let out=run('sha256sum '+dir+'/hash-input');
    unlink(dir+'/hash-input');
    let m=match(out,/^([0-9a-f]{64}) /);
    return m ? m[1] : null;
}
function body(group) {
    let text='';
    for (let i=0;i<length(group.parts);i++) {
        let index=group.parts[i];
        if (type(index)!='int' || index<0 || index>255) return null;
        let response=sms('read',index);
        if (!response?.ok || !response.message || type(response.message.text)!='string' ||
            response.message.from!=group.from) return null;
        let c=response.message.concat;
        if (group.concat && (!c || c.ref!=group.concat.ref || c.bits!=group.concat.bits ||
            c.total!=group.concat.total || c.part!=i+1)) return null;
        text+=response.message.text;
    }
    return text;
}
function archive(id,group,text) {
    if (!stat(recipient) || (!stat(archive_dir) && !mkdir(archive_dir,0700))) return false;
    chmod(archive_dir,0700);
    let target=archive_dir+'/'+id+'.der';
    if (stat(target)?.size>128) return true;
    if (!writefile(dir+'/archive.json',sprintf('%J',{from:group.from,time:group.time,
        concat:group.concat,parts:group.parts,text}))) return false;
    chmod(dir+'/archive.json',0600);
    let rc=system('openssl cms -encrypt -binary -aes-256-cbc -outform DER -in '+dir+
        '/archive.json -out '+target+'.new -recip '+recipient+' >/dev/null 2>&1');
    unlink(dir+'/archive.json');
    if (rc!=0 || (stat(target+'.new')?.size || 0)<128) { unlink(target+'.new'); return false; }
    chmod(target+'.new',0600);
    return rename(target+'.new',target);
}
function send(dest,text) {
    if (!valid_url(dest.url)) return false;
    if (!save(dir+'/payload.json',{msg_type:'text',content:{text}})) return false;
    if (!writefile(dir+'/curl.conf','url = "'+dest.url+'"\n')) return false;
    chmod(dir+'/curl.conf',0600);
    let http=run("curl --silent --proto '=https' --connect-timeout 5 --max-time 12 --max-filesize 65536 --config "+dir+
        "/curl.conf -H 'Content-Type: application/json' --data-binary @"+dir+
        "/payload.json -o "+dir+"/response.json -w '%{http_code}'");
    let reply=parse(dir+'/response.json');
    unlink(dir+'/curl.conf'); unlink(dir+'/payload.json'); unlink(dir+'/response.json');
    return http=='200' && reply && reply.code==0;
}

if (!mkdir(dir,0700)) exit(0); // a previous poll still owns the tmpfs workdir
let summary={timestamp:time(),enabled:false,initialized:false,pending:0,last_success:null,
    unread_count:null,unread_known:false,error:null};
function process_messages() {
    let c=read_config(), list=sms('list',null);
    if (!list?.ok || type(list.groups)!='array') {
        unlink(badge_path); summary.error='短信目录暂不可读'; return;
    }
    let state=parse(state_path);
    if (!state || type(state.entries)!='array' || !match(state.salt || '',/^[0-9a-f]{64}$/)) {
        let salt=run('head -c 32 /dev/urandom | hexdump -v -e \'1/1 "%02x"\'');
        if (!match(salt,/^[0-9a-f]{64}$/)) { summary.error='无法初始化去重状态'; return; }
        state={salt,initialized:false,entries:[]};
    }
    summary.enabled=c.enabled==true && c.events?.sms_received==true;
    summary.initialized=state.initialized;
    let seen=parse(seen_path)?.ids || {};
    let badges=[];
    let unread=0;
    let incomplete=false;
    // A SIM/module store switch can expose historical messages that were not
    // visible in the previous poll. Archive them, but never label them new.
    let storage_changed=state.storage!=null && state.storage!=list.storage;
    for (let group in list.groups) {
        if (group.status=='已发' || group.status=='待发') continue;
        if (!group.complete || !group.from || !group.time) { incomplete=true; continue; }
        let id=fingerprint(state,group);
        if (!id) { summary.error='无法识别短信'; return; }
        let existing=filter(state.entries,e=>e.id==id)[0];
        if (!existing) {
            existing={id,baseline:!state.initialized || !summary.enabled || storage_changed,archived:false,delivered:{}};
            // Automatic archival reads the SIM slot, but is not a user read.
            existing.unread=state.initialized && !storage_changed;
            existing.legacy=!state.initialized || storage_changed;
            push(state.entries,existing);
        }
        let is_new=existing.unread==true && seen[id]!=true;
        if (is_new) unread++;
        push(badges,{id,index:group.index,from:group.from,time:group.time,
            unread:is_new,baseline:existing.legacy==true || (existing.unread==null && existing.baseline==true)});
        let targets=existing.baseline || !summary.enabled ? [] : filter(c.destinations || [],d=>d.enabled && valid_url(d.url));
        let waiting=filter(targets,d=>existing.delivered[d.id]!=true);
        if (existing.archived && !length(waiting)) continue;
        let message=body(group);
        if (message==null) { summary.pending++; continue; }
        if (!existing.archived) {
            if (archive(id,group,message)) { existing.archived=true; save(state_path,state); }
            else summary.error='短信加密备份失败';
        }
        if (!length(waiting)) continue;
        let formatted='【KK-Car 新短信】\n发件人：'+group.from+'\n时间：'+group.time+'\n内容：\n'+message;
        for (let target in waiting) {
            if (send(target,formatted)) {
                existing.delivered[target.id]=true;
                summary.last_success=time();
                save(state_path,state);
            }
            else summary.pending++;
        }
    }
    state.initialized=true;
    state.storage=list.storage;
    if (length(state.entries)>512) state.entries=slice(state.entries,length(state.entries)-512);
    if (!save(state_path,state)) { summary.error='无法保存去重状态'; return; }
    if (!save(badge_path,{timestamp:summary.timestamp,storage:list.storage,groups:badges})) {
        summary.error='无法保存短信提示'; return;
    }
    summary.initialized=true;
    summary.unread_count=incomplete ? null : unread;
    summary.unread_known=!incomplete;
}
process_messages();
save(status_path,summary);
for (let file in ['hash-input','payload.json','curl.conf','response.json','archive.json']) unlink(dir+'/'+file);
rmdir(dir);
