'use strict';
import { readfile, writefile, rename, mkdir, open, glob, stat, unlink } from 'fs';

const RAM = '/tmp/kk-car-history.json';
const DISK = '/etc/kk-car/history';
function load(path) { try { return json(readfile(path) || '{}'); } catch(e) { return {}; } }
function atomic(path, value) {
    return writefile(path+'.new', sprintf('%J',value)) && rename(path+'.new',path);
}
function rounded(value) { return value == null ? null : int(value*1000+(value<0?-0.5:0.5))/1000.0; }
// Rows: epoch, down Mbps, up Mbps, reply-weighted RTT, sent, received,
// minimum RTT, maximum RTT, batches observed, valid traffic seconds,
// average LTE RSRP dBm, count of distinct modem samples. Legacy 10-column rows remain readable.
function aggregate(rows, bucket) {
    let a={t:bucket,rx:0,tx:0,seconds:0,rtt:0,sent:0,received:0,min:null,max:null,n:0,rsrp:0,signals:0};
    for (let r in rows) {
        if (r[1]!=null && r[2]!=null && r[9]>0) {
            a.rx+=r[1]*r[9]; a.tx+=r[2]*r[9]; a.seconds+=r[9];
        }
        if (r[10]!=null && r[11]>0) { a.rsrp+=r[10]*r[11]; a.signals+=r[11]; }
        a.sent+=r[4] || 0; a.received+=r[5] || 0; a.n+=r[8] || 0;
        if (r[3]!=null && r[5]>0) {
            a.rtt+=r[3]*r[5];
            a.min=a.min==null ? r[6] : (a.min<r[6]?a.min:r[6]);
            a.max=a.max==null ? r[7] : (a.max>r[7]?a.max:r[7]);
        }
    }
    return [a.t,a.seconds ? rounded(a.rx/(a.seconds*1.0)) : null,a.seconds ? rounded(a.tx/(a.seconds*1.0)) : null,
        a.received ? rounded(a.rtt/(a.received*1.0)) : null,a.sent,a.received,a.min,a.max,a.n,rounded(a.seconds),a.signals ? rounded(a.rsrp/(a.signals*1.0)) : null,a.signals];
}
function valid(r) {
    if (type(r)!='array' || (length(r)!=10 && length(r)!=12) || type(r[0])!='int' || r[0]<1700000000) return false;
    for (let i=1;i<length(r);i++) if (r[i]!=null && type(r[i])!='int' && type(r[i])!='double') return false;
    if (length(r)==12 && !(r[11]>=0 && (r[10]==null ? r[11]==0 : r[11]>0 && r[10]>= -150 && r[10]<= -30))) return false;
    return r[4]>=0 && r[5]>=0 && r[5]<=r[4] && r[8]>0 && r[9]>=0 &&
        (r[3]==null || (r[5]>0 && r[6]!=null && r[7]!=null && r[6]<=r[3] && r[3]<=r[7]));
}
function read_minutes(path) {
    let rows={};
    if ((stat(path)?.size || 0)>524288) return rows;
    for (let line in split(readfile(path) || '', '\n')) {
        try { let r=json(line); if (valid(r)) rows[''+r[0]]=r; } catch(e) { }
    }
    return rows;
}
function hours(minutes) {
    let buckets={}, result=[];
    for (let key, row in minutes) {
        let hour=''+(int(row[0]/3600)*3600);
        if (!buckets[hour]) buckets[hour]=[];
        push(buckets[hour],row);
    }
    for (let hour, rows in buckets) {
        let times=sort(map(rows,function(r){return r[0];}),function(a,b){return a-b;});
        push(result,{row:aggregate(rows,+hour),minutes:length(rows),first:times[0],last:times[length(times)-1]});
    }
    return result;
}
function rebuild_hours(disk,day) {
    return atomic(disk+'/'+day+'.hours.json',hours(read_minutes(disk+'/'+day+'.jsonl')));
}
function record(probe, counters, boot, ram, disk) {
    ram=ram || RAM; disk=disk || DISK;
    let s=load(ram), now=probe.timestamp, mono=probe.uptime;
    if (now<1700000000) return;
    if (!s.pending) s.pending=[];
    let rx=null, tx=null, dt=mono-(s.previous?.uptime || mono);
    if (s.boot==boot && dt>0 && dt<30 && now-s.previous.timestamp-dt<5 && now-s.previous.timestamp-dt> -5) {
        let old=s.previous.counters;
        if (old.mode==counters.mode && counters.rx>=old.rx && counters.tx>=old.tx) {
            rx=(counters.rx-old.rx)*8/dt/1e6; tx=(counters.tx-old.tx)*8/dt/1e6;
        }
    }
    let minute=int(now/60)*60;
    if (s.bucket!=minute) {
        if (s.rows && length(s.rows) && s.bucket<minute) push(s.pending,aggregate(s.rows,s.bucket));
        s.bucket=minute; s.rows=[];
    }
    if (s.boot!=boot || (s.previous && now<s.previous.timestamp)) s.rows=[];
    let signal=counters.signal || {}, rsrp=null;
    if (s.boot!=boot || (s.previous && now<s.previous.timestamp)) s.last_signal=null;
    if ((type(signal.rsrp)=='int' || type(signal.rsrp)=='double') && signal.rsrp>= -150 && signal.rsrp<= -30 &&
        signal.timestamp>0 && now>=signal.timestamp && now-signal.timestamp<75 &&
        (s.last_signal==null || signal.timestamp>s.last_signal)) {
        rsrp=signal.rsrp; s.last_signal=signal.timestamp;
    }
    let reply=probe.avg_ms!=null ? probe.received : 0;
    push(s.rows,[now,rx,tx,probe.avg_ms,probe.sent || 0,reply || 0,probe.min_ms,probe.max_ms,1,rx==null ? 0 : dt,rsrp,rsrp==null ? 0 : 1]);
    s.rows=slice(s.rows,-12);
    s.boot=boot; s.previous={timestamp:now,uptime:mono,counters};
    if (s.last_flush==null) s.last_flush=mono;
    // First completed minute is saved immediately; subsequent writes are batched.
    if (length(s.pending) && (!s.saved || mono-s.last_flush>=300 || mono<s.last_flush)) {
        mkdir(disk,0700);
        let keep=[], blocks={};
        for (let row in s.pending) {
            if (row[0]<now-30*86400 || row[0]>now+60) continue;
            let day=''+int(row[0]/86400);
            if (!blocks[day]) blocks[day]=[];
            push(blocks[day],row);
        }
        s.storage_error=false;
        for (let day, rows in blocks) {
            let path=disk+'/'+day+'.jsonl';
            let content='\n'+join('\n',map(rows,function(r){return sprintf('%J',r);}))+'\n';
            let handle=(stat(path)?.size || 0)+length(content)<524288 ? open(path,'a',0600) : null;
            let ok=handle && handle.write(content)==length(content);
            if (handle) ok=handle.close() && ok;
            if (ok && !rebuild_hours(disk,day)) s.storage_error=true;
            if (!ok) { for (let row in rows) push(keep,row); s.storage_error=true; }
        }
        s.pending=slice(keep,-1440); s.last_flush=mono; s.saved=!s.storage_error;
        for (let file in glob(disk+'/*')) {
            let m=match(file,/\/([0-9]+)\.(jsonl|hours\.json)$/);
            if (m && +m[1]<int((now-30*86400)/86400)) unlink(file);
        }
    }
    atomic(ram,s);
}
function history(range, now, ram, disk) {
    ram=ram || RAM; disk=disk || DISK; now=now || time();
    let config={'1h':[3600,60],'1d':[86400,300],'30d':[2592000,3600]};
    if (!config[range]) return {ok:false,error:'请选择 1 小时、1 天或 30 天'};
    let span=config[range][0], step=config[range][1], from=now-span, byMinute={}, counts={}, starts={}, ends={};
    function add(r,n,first,last) {
        if (valid(r) && r[0]>=int(from/step)*step && r[0]<=now) {
            let key=''+r[0]; byMinute[key]=r;counts[key]=n || 1;starts[key]=first || r[0];ends[key]=last || r[0];
        }
    }
    let state=load(ram), recent={};
    for (let day=int(from/86400);day<=int(now/86400);day++) {
        let boundary=day==int(from/86400) || day>=int((now-3600)/86400);
        if (range=='30d' && !boundary) {
            let summary=load(disk+'/'+day+'.hours.json');
            for (let item in type(summary)=='array' ? summary : []) add(item.row,item.minutes,item.first,item.last);
        }
        if (range!='30d' || boundary) {
            for (let key,row in read_minutes(disk+'/'+day+'.jsonl'))
                if (row[0]>=int(from/60)*60 && row[0]<=now) recent[key]=row;
        }
    }
    for (let row in state.pending || [])
        if (row[0]>=int(from/60)*60 && row[0]<=now) recent[''+row[0]]=row;
    if (length(state.rows || []) && state.bucket>=int(from/60)*60 && state.bucket<=now) recent[''+state.bucket]=aggregate(state.rows,state.bucket);
    if (range=='30d') {
        for (let item in hours(recent)) add(item.row,item.minutes,item.first,item.last);
    } else for (let key,row in recent) add(row);
    let buckets={};
    for (let key, row in byMinute) {
        let bucket=''+(int(row[0]/step)*step);
        if (!buckets[bucket]) buckets[bucket]=[];
        push(buckets[bucket],row);
    }
    let points=[];
    for (let t=int(from/step)*step;t<=now;t+=step) {
        let rows=buckets[''+t];
        push(points,rows ? aggregate(rows,t) : [t,null,null,null,0,0,null,null,0,0,null,0]);
    }
    let minutes=0,first=null,last=null;
    for (let key,row in byMinute) {
        minutes+=counts[key]; if (first==null || starts[key]<first) first=starts[key];
        if (last==null || ends[key]>last) last=ends[key];
    }
    return {ok:true,range,from:int(from/step)*step,to:now,step,points,minutes,
        first,last,
        storage_error:!!state.storage_error,last_sample:state.previous?.timestamp || null};
}
export { record, history, aggregate, rebuild_hours };
