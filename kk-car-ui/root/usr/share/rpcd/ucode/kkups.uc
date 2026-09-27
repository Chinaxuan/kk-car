'use strict';
import { sample } from '/etc/kk-car/ups-read.uc';
import { readfile, popen } from 'fs';
import { policy,save_policy,set_option,save_battery,rtc_sync,power_action } from '/etc/kk-car/ups-control.uc';

function status() {
    let data=sample();
    data.policy=policy();
    try { data.watch=json(readfile('/tmp/kk-car-ups-watch.json') || '{}'); }
    catch(e) { data.watch={}; }
    try {
        let r=json(readfile('/tmp/kk-car-diagnostics.json') || '{}');
        data.diagnostics={timestamp:r.timestamp,ok:r.ok,interval_s:r.interval_s,
            max_bytes:r.max_bytes,qmi_errors:(r.errors_new?.qmi_timeout || 0)+(r.errors_new?.qmi_parse || 0),
            sd_unclean:r.errors_total?.sd_unclean || 0};
    } catch(e) { data.diagnostics={}; }
    return data;
}

return { 'kkups': {
    status: { call:function() { return status(); } },
    history: {args:{range:'24h',start:0,end:0,segment:0,raw:false,offset:0},call:function(req) {
        let a=req.args;
        if (index(['1h','24h','7d','30d','all','custom'],a.range)<0 ||
            a.start<0 || a.end<0 || a.segment<0 || a.offset<0)
            return {ok:false,error:'无效的历史查询'};
        // Only enum/numeric arguments reach the shell; no path or text input.
        let query=sprintf('{"range":"%s","start":%d,"end":%d,"segment":%d,"raw":%s,"offset":%d}',
            a.range,a.start,a.end,a.segment,a.raw?'true':'false',a.offset);
        let p=popen('/usr/bin/python3 /etc/kk-car/ups_history.py \''+query+'\' 2>/dev/null');
        if (!p) return {ok:false,error:'历史查询无法启动'};
        let raw=p.read('all'), rc=p.close();
        if (rc!=0) return {ok:false,error:'历史日志暂时无法读取'};
        try {return json(raw);} catch(e) {return {ok:false,error:'历史数据格式无效'};}
    }},
    set_option: {args:{key:'',value:0,expected:0,confirm:''},call:function(req) {
        let a=req.args;return set_option(a.key,a.value,a.expected,a.confirm);
    }},
    save_battery: {args:{full_mv:0,empty_mv:0,protect_mv:0,manual:false,expected:'',confirm:''},call:function(req) {
        let a=req.args;return save_battery(a.full_mv,a.empty_mv,a.protect_mv,a.manual,a.expected,a.confirm);
    }},
    save_policy: {args:{enabled:false,shutdown_mv:3550},call:function(req) {
        let a=req.args;return save_policy(a.enabled,a.shutdown_mv);
    }},
    rtc_sync: {call:function() {return rtc_sync();}},
    power_action: {args:{action:'',confirm:''},call:function(req) {
        return power_action(req.args.action,req.args.confirm);
    }}
}};
