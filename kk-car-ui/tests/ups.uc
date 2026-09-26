#!/usr/bin/ucode
'use strict';
import { step,orphaned_timer } from '/etc/kk-car/ups-watch.uc';
import { set_option,battery_voltage_error } from '/etc/kk-car/ups-control.uc';
import { validRaw,voltage_reference } from '/etc/kk-car/ups-read.uc';

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
let armed={ok:true,input:{external:true},controller:{shutdown_countdown_s:88}};
check(orphaned_timer({},armed,false),'cancel orphaned timer on powered startup');
check(!orphaned_timer({timestamp:1},armed,false),'do not cancel timer during normal running');
check(!orphaned_timer({},armed,true),'preserve explicit power action');
armed.input.external=false;
check(!orphaned_timer({},armed,false),'do not cancel hardware protection on battery');
let loaded={ok:true,input:{external:false},battery:{millivolts:3750},
    sensors:{battery:{detected:true,conversion_ready:true,overflow:false,bus_mv:3600}}};
let sag=step(config,loaded,{});
check(sag.consecutive==0 && sag.battery_mv==3600 && sag.voltage_source=='battery_sensor',
    'consistent sensor voltage remains usable at boundary');
loaded.sensors.battery.bus_mv=3340;
let conflict=step(config,loaded,{});
check(conflict.consecutive==0 && conflict.battery_mv==3750 && conflict.voltage_source=='controller' &&
    conflict.sensor_voltage_rejected && !conflict.should_shutdown,'reject false low voltage from disagreeing sensor');
loaded.battery.millivolts=3500;
let fallbackLow=step(config,loaded,{});
check(fallbackLow.consecutive==1 && fallbackLow.battery_mv==3500 && fallbackLow.sensor_voltage_rejected,
    'controller low voltage remains effective during sensor disagreement');
check(step(config,loaded,step(config,loaded,fallbackLow)).should_shutdown,
    'three controller low samples still trigger shutdown');
loaded.sensors.battery.bus_mv=3540;loaded.battery.millivolts=3570;
let low_consistent=step(config,loaded,{});
check(low_consistent.consecutive==1 && low_consistent.battery_mv==3540,'retain genuine consistent low sample');
loaded.battery.millivolts=3750;
loaded.sensors.battery.conversion_ready=false;
check(step(config,loaded,{}).battery_mv==3750,'unready battery sensor falls back');
let disabled=step({enabled:false,shutdown_mv:3550},loaded,{});
check(disabled.status=='disabled' && disabled.battery_mv==3750 && !disabled.should_shutdown,
    'disabled protection still reports voltage reference without acting');
let missing=voltage_reference({battery:{millivolts:0},sensors:{battery:{detected:false}}});
check(missing.millivolts==null && missing.source==null,'invalid sources never become a battery voltage');
loaded.sensors.battery.conversion_ready=true;loaded.battery.millivolts=0;
check(voltage_reference(loaded).source=='battery_sensor','usable sensor survives missing controller');
check(!set_option('restart_countdown',20,0,'').ok,'reject unlisted register');
check(!set_option('protect_mv',2749,0,'修改电池参数').ok,'reject voltage below confirmed cell cutoff');
check(!set_option('protect_mv',0,0,'修改电池参数').ok,'zero is not a protection-disable command');
let limits={configured_full_mv:4200,configured_empty_mv:2750,configured_protect_mv:2750,user_programmed:false};
check(battery_voltage_error('empty_mv',2750,limits)==null &&
    battery_voltage_error('protect_mv',2750,limits)==null,'equal cutoff accepted in automatic mode');
check(battery_voltage_error('user_programmed',1,limits)!=null,'manual mode rejects equal cutoff before voltage clamping');
limits.user_programmed=true;
check(battery_voltage_error('empty_mv',2750,limits)!=null &&
    battery_voltage_error('protect_mv',2750,limits)!=null,'manual mode cannot acquire equal cutoff by either field');
check(battery_voltage_error('protect_mv',2800,limits)==null,'manual mode accepts distinct protection cutoff');
limits.user_programmed=false;
check(battery_voltage_error('empty_mv',2800,limits)!=null,'empty cannot exceed protection');
check(battery_voltage_error('protect_mv',4100,limits)!=null,'protection retains full voltage margin');
check(!set_option('auto_start_on_ac',2,0,'').ok,'reject invalid bool');
let frame=[];for (let i=0;i<42;i++) push(frame,0);
function put16(reg,value) {frame[reg-1]=value&255;frame[reg]=(value>>8)&255;}
function put32(reg,value) {put16(reg,value&65535);put16(reg+2,(value>>16)&65535);}
put16(0x01,3300);put16(0x03,4950);put16(0x05,4000);
put16(0x0b,49);put16(0x0d,4282);put16(0x0f,1792);
put16(0x13,86);put16(0x15,2);frame[0x17-1]=1;
put32(0x1c,3600);put32(0x20,3600);put32(0x24,3600);put16(0x28,10);
check(validRaw(frame),'valid controller frame');
put16(0x28,65535);check(!validRaw(frame),'reject corrupt firmware version');put16(0x28,10);
put32(0x24,4294967295);check(!validRaw(frame),'reject corrupt uptime');put32(0x24,3600);
put16(0x11,65535);check(!validRaw(frame),'reject corrupt protection voltage');
print('PASS UPS policy, voltage consistency, disabled monitoring, write-validation, and corrupt-frame cases\n');
