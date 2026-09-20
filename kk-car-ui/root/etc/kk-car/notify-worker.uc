'use strict';
import {readfile,writefile,rename,chmod,mkdir,unlink,popen} from 'fs';
import {connect} from 'ubus';
import {read_config} from '/etc/kk-car/notify-config.uc';
import {step} from '/etc/kk-car/notify-engine.uc';
function read(path) {try{return json(readfile(path));}catch(e){return null;}}
function write(path,obj) {if(!writefile(path+'.new',sprintf('%J',obj)))return false;chmod(path+'.new',0600);return rename(path+'.new',path);}
function event_time(at) {let d=localtime(at);return sprintf('%02d-%02d %02d:%02d:%02d',d.mon,d.mday,d.hour,d.min,d.sec);}
function run(cmd) {let p=popen(cmd+' 2>/dev/null');if(!p)return '';let s=p.read('all');p.close();return s || '';}
let lock='/tmp/kk-car-notify-lock';
if(!mkdir(lock,0700)) exit(0);
let c=read_config(), s=read('/tmp/kk-car-notify-state.json') || {queue:[],engine:{},deliveries:{},log:[]};
let up=+(split(readfile('/proc/uptime') || '0',' ')[0]), now=int(up), boot=trim(readfile('/proc/sys/kernel/random/boot_id') || '');
let mode=ARGV[0] || 'poll';
function enqueue(kind,text) {if(c.enabled && (kind=='test' || c.events[kind]))push(s.queue,{kind,text,at:time(),queued_at:now,done:{}});}
try {
    if(s.revision!=c.revision) {s.queue=[];s.engine={};s.revision=c.revision;s.retry_at=0;}
    let marker='/etc/kk-car/private/notify-boot.json', old=read(marker);
    if(!old || old.id!=boot) {
        if(old && old.id) {enqueue('boot','树莓派已开机，运行 '+int(up)+' 秒');if(!old.clean)enqueue('abnormal_boot','上次未记录正常关机，可能是断电、崩溃或关机钩子未执行');}
        mkdir('/etc/kk-car/private',0700);write(marker,{id:boot,clean:false});
    }
    if(mode=='shutdown') {
        enqueue('shutdown','树莓派正在正常关机或重启');write(marker,{id:boot,clean:true});s.retry_at=0;
    } else {
        let request=read('/tmp/kk-car-notify-test.json');
        if(request && request.revision<=c.revision) {unlink('/tmp/kk-car-notify-test.json');if(request.revision==c.revision) {enqueue('test','测试推送：KK-Car 飞书通知已接通');s.retry_at=0;}}
        let bus=connect(), d=bus.call('kkcar','status');
        if(d && d.timestamp) {
            let ap=bus.call('hostapd.phy0-ap0','get_clients'), clients=null;
            if(ap && type(ap.clients)=='object') {
                clients={};let names={};for(let p in d.peers || []) names[lc(p.mac)]=substr(replace(p.name || '设备',/[[:cntrl:]]/g,''),0,48);
                function label(mac){return (names[mac] || '未命名设备')+'（'+substr(mac,12)+'）';}
                for(let mac,p in ap.clients) if(p.authorized)clients[lc(mac)]=label(lc(mac));
                // Only fresh ARP/NUD evidence; STALE leases alone never imply online.
                for(let line in split(run('/sbin/ip -4 neigh show dev br-lan'),'\n')) {
                    let m=match(line,/lladdr ([a-fA-F0-9:]+) (REACHABLE|DELAY|PROBE)( |$)/);
                    if(m)clients[lc(m[1])]=label(lc(m[1]));
                }
            }
            let modem=d.modem || {}, mf=modem.timestamp && time()-modem.timestamp>=0 && time()-modem.timestamp<90;
            let sample={timestamp:time(),vpn:d.vpn?.connected==true,uplink:d.uplink?.active || null,ping:d.vpn_ping,
                rsrp:mf && modem.online ? modem.rsrp : null,temperature:d.temperature>0 ? d.temperature : null,
                undervoltage:d.power?.known ? d.power.undervoltage : null,clients};
            let result=step(s.engine,sample,c,now);s.engine=result.state;
            for(let e in result.events)push(s.queue,{...e,queued_at:now,done:{}});
            s.sample_at=time();s.sample_error=false;
        } else s.sample_error=true;
    }
    s.queue=filter(s.queue,e=>now-(e.queued_at ?? now)<3600 && (e.kind=='test' || c.events[e.kind]));
    if(!c.enabled) s.queue=[];
    if(length(s.queue)>50) {s.dropped=(s.dropped || 0)+length(s.queue)-50;s.queue=slice(s.queue,-50);}
    if(mode=='shutdown')s.queue=[...filter(s.queue,e=>e.kind=='shutdown'),...filter(s.queue,e=>e.kind!='shutdown')];
    write('/tmp/kk-car-notify-state.json',s);
    let targets=filter(c.destinations,d=>d.enabled && d.url), attempted=false, failed=false;
    if(now>=(s.retry_at || 0)) for(let target in targets) {
        let batch=slice(filter(s.queue,e=>!e.done[target.id]),0,10);
        if(!length(batch))continue;
        attempted=true;
        let lines=['KK-Car · 车载网络通知'];
        for(let e in batch)push(lines,sprintf('%s  %s',event_time(e.at),e.text));
        write('/tmp/kk-car-notify-payload.json',{msg_type:'text',content:{text:join('\n',lines)}});
        // URL never appears in argv, logs, RPC responses, or published source.
        writefile('/tmp/kk-car-notify-lock/curl.conf','url = "'+target.url+'"\n');chmod('/tmp/kk-car-notify-lock/curl.conf',0600);
        let http=trim(run("/usr/bin/curl --silent --proto '=https' --connect-timeout 4 --max-time 8 --max-filesize 65536 --config /tmp/kk-car-notify-lock/curl.conf -H 'Content-Type: application/json' --data-binary @/tmp/kk-car-notify-payload.json -o /tmp/kk-car-notify-response.json -w '%{http_code}' && printf ' OK'"));
        let reply=read('/tmp/kk-car-notify-response.json');
        let ok=http=='200 OK' && reply && (type(reply.code)=='int' && reply.code==0 || reply.code==null && type(reply.StatusCode)=='int' && reply.StatusCode==0);
        s.deliveries[target.id]={ok,at:time(),http:substr(http,0,3),code:reply?.code ?? reply?.StatusCode ?? null};
        unlink('/tmp/kk-car-notify-lock/curl.conf');unlink('/tmp/kk-car-notify-response.json');unlink('/tmp/kk-car-notify-payload.json');
        if(ok) {for(let e in batch){e.done[target.id]=true;push(s.log,{at:e.at,text:e.text});}s.log=slice(s.log,-10);}
        else failed=true;
    }
    if(attempted) {s.failures=failed ? min(5,(s.failures || 0)+1) : 0;s.retry_at=now+(failed ? min(300,30*2**s.failures) : 0);}
    if(length(targets))s.queue=filter(s.queue,e=>length(filter(targets,d=>!e.done[d.id]))>0);
    write('/tmp/kk-car-notify-state.json',s);
    write('/tmp/kk-car-notify-status.json',{timestamp:time(),sample_at:s.sample_at,sample_error:s.sample_error,queued:length(s.queue),dropped:s.dropped || 0,deliveries:s.deliveries,log:s.log});
} catch(e) {
    // Do not persist exception strings: they might contain endpoint details.
    write('/tmp/kk-car-notify-status.json',{timestamp:time(),error:'通知服务采样或发送异常，请检查服务状态'});
}
// fs.rmdir is used below rather than shelling out with dynamic paths.
import {rmdir} from 'fs';
rmdir(lock);
