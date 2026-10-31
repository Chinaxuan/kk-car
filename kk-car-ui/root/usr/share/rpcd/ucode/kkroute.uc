'use strict';
import { popen } from 'fs';
function quote(value) { return "'" + replace(value, /'/g, "'\\''") + "'"; }
function invoke(mode, input) {
    let p = popen('/usr/bin/python3 /etc/kk-car/company-routing.py ' + mode +
        (input == null ? '' : ' ' + quote(sprintf('%J', input))) + ' 2>/dev/null');
    if (!p) return {ok:false, error:'公司白名单服务不可用'};
    let raw = p.read('all'); p.close();
    try { return json(raw || '{}'); }
    catch(e) { return {ok:false, error:'公司白名单响应无效'}; }
}
return {'kkroute': {
    status: {call:function() { return invoke('status'); }},
    save: {args:{settings:'', revision:0}, call:function(req) {
        if (length(req.args.settings) > 65536) return {ok:false, error:'规则内容过长'};
        let input; try { input = json(req.args.settings); }
        catch(e) { return {ok:false, error:'设置格式无效'}; }
        if (type(input) != 'object') return {ok:false, error:'设置格式无效'};
        input.revision = req.args.revision;
        return invoke('save', input);
    }}
}};
