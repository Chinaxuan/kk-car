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
let idle={enabled:true,shutdown_mv:3500,idle_enabled:true,idle_minutes:60};
let idleStart=step(idle,high,{},0,100);
check(idleStart.status=='idle_wait' && idleStart.idle_elapsed_s==0,'idle timer starts on battery');
let idleAlmost=step(idle,high,idleStart,0,3699);
check(idleAlmost.idle_elapsed_s==3599 && !idleAlmost.should_shutdown,'do not shut down early');
let idleDue=step(idle,high,idleAlmost,0,3700);
check(idleDue.should_shutdown && idleDue.shutdown_reason=='idle','one-hour idle shutdown');
check(!step(idle,high,idleDue,0,3710).should_shutdown,'idle shutdown triggered once');
let clientJoin=step(idle,high,idleAlmost,1,3700);
check(clientJoin.status=='on_battery' && !clientJoin.should_shutdown,'client join resets idle timer');
check(step(idle,high,clientJoin,0,3710).idle_elapsed_s==0,'new idle period after client leaves');
check(step(idle,high,idleAlmost,null,3700).status=='clients_unknown','failed client probe never means idle');
check(step(idle,plugged,idleAlmost,0,3700).status=='external_power','restored external power resets idle');
check(step(idle,high,idleAlmost,0,100).idle_elapsed_s==0,'reboot resets monotonic idle timer');
let lowFirst=step(idle,low,idleAlmost,0,3700);
let lowSecond=step(idle,low,lowFirst,0,3710);
let lowPriority=step(idle,low,lowSecond,0,3720);
check(lowPriority.should_shutdown && lowPriority.shutdown_reason=='low_voltage','low voltage overrides idle reason');
let percentPolicy={enabled:true,mode:'percent',shutdown_mv:3500,shutdown_percent:10,
    emergency_mv:3250,idle_enabled:false,idle_minutes:60};
let ten={ok:true,input:{external:false},battery:{millivolts:3320,percent:10}};
let pctFirst=step(percentPolicy,ten,{},1,100),pctSecond=step(percentPolicy,ten,pctFirst,1,110);
let pctThird=step(percentPolicy,ten,pctSecond,1,120);
check(pctFirst.percent_consecutive==1 && pctSecond.percent_consecutive==2 &&
    pctThird.should_shutdown && pctThird.shutdown_reason=='low_percent','three low percent samples');
check(!step(percentPolicy,ten,pctThird,1,130).should_shutdown,'percent shutdown triggered once');
let badPercent={ok:true,input:{external:false},battery:{millivolts:3400,percent:101}};
check(step(percentPolicy,badPercent,{},1,100).status=='invalid_percent' &&
    !step(percentPolicy,badPercent,{},1,100).should_shutdown,'invalid percent cannot shut down');
let floorOnly={ok:true,input:{external:false},battery:{millivolts:3240,percent:50}};
let floorFirst=step(percentPolicy,floorOnly,{},1,100);
check(step(percentPolicy,floorOnly,step(percentPolicy,floorOnly,floorFirst,1,110),1,120).shutdown_reason=='low_voltage',
    'voltage floor protects percent mode');
check(step(percentPolicy,plugged,pctSecond,1,130).percent_consecutive==0,
    'external power resets low percent counter');
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
put32(0x1c,818664);put32(0x20,1184156);put32(0x24,32894);
check(validRaw(frame),'independent V10 runtime counters do not hide battery data');
put16(0x28,65535);check(!validRaw(frame),'reject corrupt firmware version');put16(0x28,10);
put32(0x24,4294967295);check(!validRaw(frame),'reject corrupt uptime');put32(0x24,3600);
put16(0x11,65535);check(!validRaw(frame),'reject corrupt protection voltage');
print('PASS UPS voltage/percent/idle policy, sensor consistency, write-validation, and corrupt-frame cases\n');
