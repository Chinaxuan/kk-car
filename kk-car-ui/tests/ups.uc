#!/usr/bin/ucode
'use strict';
import { step } from '/etc/kk-car/ups-watch.uc';
import { set_option } from '/etc/kk-car/ups-control.uc';

function check(ok,name) {if (!ok) {print('FAIL '+name+'\n');exit(1);}}
let config={enabled:true,shutdown_mv:3550};
let high={ok:true,input:{external:false},battery:{millivolts:3700}};
let low={ok:true,input:{external:false},battery:{millivolts:3500}};
let plugged={ok:true,input:{external:true},battery:{millivolts:3400}};
let a=step(config,high,{});
check(a.consecutive==0 && !a.should_shutdown,'above threshold');
let b=step(config,low,a),c=step(config,low,b),d=step(config,low,c);
check(b.consecutive==1 && c.consecutive==2 && d.should_shutdown,'three low samples');
let e=step(config,low,d);
check(!e.should_shutdown && e.triggered,'once only');
check(step(config,plugged,e).consecutive==0,'external power resets');
check(step(config,{ok:false},e).consecutive==0,'read error resets');
check(step({enabled:false,shutdown_mv:3550},low,d).status=='disabled','default off');
check(!set_option('restart_countdown',20,0,'').ok,'reject unlisted register');
check(!set_option('protect_mv',2800,0,'修改电池参数').ok,'reject low voltage');
check(!set_option('auto_start_on_ac',2,0,'').ok,'reject invalid bool');
print('PASS 9 UPS policy and write-validation cases\n');
