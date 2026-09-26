'use strict';
import { sample } from '/etc/kk-car/ups-read.uc';
import { readfile } from 'fs';
import { policy,save_policy,set_option,rtc_sync,power_action } from '/etc/kk-car/ups-control.uc';

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
    set_option: {args:{key:'',value:0,expected:0,confirm:''},call:function(req) {
        let a=req.args;return set_option(a.key,a.value,a.expected,a.confirm);
    }},
    save_policy: {args:{enabled:false,shutdown_mv:3550},call:function(req) {
        let a=req.args;return save_policy(a.enabled,a.shutdown_mv);
    }},
    rtc_sync: {call:function() {return rtc_sync();}},
    power_action: {args:{action:'',confirm:''},call:function(req) {
        return power_action(req.args.action,req.args.confirm);
    }}
}};
