'use strict';
import { sample } from '/etc/kk-car/ups-read.uc';
import { readfile } from 'fs';
import { policy,save_policy,set_option,rtc_sync,power_action } from '/etc/kk-car/ups-control.uc';

function status() {
    let data=sample();
    data.policy=policy();
    try { data.watch=json(readfile('/tmp/kk-car-ups-watch.json') || '{}'); }
    catch(e) { data.watch={}; }
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
