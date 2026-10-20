#!/usr/bin/ucode
'use strict';
import { prepare_shutdown } from '/etc/kk-car/ups-control.uc';
function check(ok,name) {if (!ok) {print('FAIL '+name+'\n');exit(1);}}
let state,events,fail,watchdog_ok,reads,invalid_read,change_auto_start;
function reset(timer) {
    state={auto_start_on_ac:true,restart_countdown_s:37,shutdown_countdown_s:timer || 0};
    events=[];fail=null;watchdog_ok=true;reads=0;invalid_read=0;change_auto_start=false;
}
let io={
    read:function() {reads++;push(events,'read');
        if (reads==2 && change_auto_start) state.auto_start_on_ac=!state.auto_start_on_ac;
        return {ok:reads!=invalid_read,controller:{...state}};},
    write:function(reg,value) {
        push(events,sprintf('write:%d:%d',reg,value));
        if (reg==fail) return false;
        if (reg==0x19) state.auto_start_on_ac=value==1;
        if (reg==0x1a) state.restart_countdown_s=value;
        if (reg==0x18) state.shutdown_countdown_s=value;
        return true;
    },
    stop_watchdog:function() {push(events,'watchdog');return {ok:watchdog_ok};}
};
reset();let result=prepare_shutdown(io);
check(result.ok && result.auto_start_preserved && result.auto_start_on_ac && result.restart_cancelled &&
    result.shutdown_s==180 && result.watchdog_stopped,'fresh cutoff confirms all steps');
check(events[0]=='read' && events[1]=='write:26:0' &&
    events[2]=='write:24:180' && events[3]=='read' && events[4]=='watchdog',
    'preserve auto-start, clear restart timer, verify before watchdog');
reset();state.auto_start_on_ac=false;result=prepare_shutdown(io);
check(result.ok && result.auto_start_preserved && !result.auto_start_on_ac &&
    !state.auto_start_on_ac,'disabled auto-start also preserved');
reset(76);result=prepare_shutdown(io);
check(result.ok && result.preserved && result.shutdown_s==76 &&
    index(events,'write:24:180')<0,'inherited timer never extended');
reset(4);result=prepare_shutdown(io);
check(result.ok && result.shutdown_s==4 && index(events,'write:24:180')<0,
    'imminent inherited cutoff not postponed');
reset();invalid_read=1;result=prepare_shutdown(io);
check(!result.ok && length(events)==1,'failed first read performs no writes');
reset();change_auto_start=true;result=prepare_shutdown(io);
check(!result.ok && result.stage=='readback' && index(events,'watchdog')<0,
    'concurrent auto-start change fails readback');
reset();state.auto_start_on_ac=null;result=prepare_shutdown(io);
check(!result.ok && length(events)==1,'invalid auto-start state performs no writes');
reset();fail=0x1a;result=prepare_shutdown(io);
check(!result.ok && state.auto_start_on_ac && index(events,'watchdog')<0,
    'restart timer failure does not change auto-start');
reset();fail=0x18;result=prepare_shutdown(io);
check(!result.ok && index(events,'watchdog')<0,'failed cutoff never stops watchdog');
reset();invalid_read=2;result=prepare_shutdown(io);
check(!result.ok && state.shutdown_countdown_s==180 && index(events,'watchdog')<0,
    'failed readback preserves armed cutoff without a false success');
reset();watchdog_ok=false;result=prepare_shutdown(io);
check(result.ok && !result.watchdog_stopped && state.shutdown_countdown_s==180 &&
    state.auto_start_on_ac,'watchdog failure remains visible and does not cancel physical cutoff');
reset();io.stop_watchdog=function(){die('simulated watchdog transport error');};
result=prepare_shutdown(io);
check(result.ok && !result.watchdog_stopped,'watchdog exception does not unwind armed cutoff');
print('PASS shutdown sequence, inherited timer, write/read failures and watchdog results\n');
