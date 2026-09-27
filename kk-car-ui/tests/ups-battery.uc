#!/usr/bin/ucode
'use strict';
import { battery_settings,battery_revision,battery_expected_matches,
    battery_settings_error,battery_transaction,save_battery } from '/etc/kk-car/ups-control.uc';
function check(ok,name) {if (!ok) {print('FAIL '+name+'\n');exit(1);}}
function status(v) {return {ok:true,battery:{configured_full_mv:v.full_mv,
    configured_empty_mv:v.empty_mv,configured_protect_mv:v.protect_mv,user_programmed:v.manual}};}
let target={full_mv:4200,empty_mv:3000,protect_mv:3080,manual:true};
let learned={full_mv:4288,empty_mv:3080,protect_mv:3080,manual:false};
check(battery_settings_error(target)==null,'requested voltage group accepted');
check(battery_settings_error({...target,empty_mv:3080})!=null,'manual clamping relationship rejected');
check(battery_settings_error({...target,protect_mv:2749})!=null,'cell minimum respected');
check(battery_settings_error({...target,full_mv:3080})!=null,'invalid full rejected');
check(battery_settings_error({...target,empty_mv:'3000'})!=null,'string is not integer');
check(!save_battery(4200,3000,3080,true,'','修改电池参数').ok,'missing revision rejected before hardware access');
check(!save_battery(4200,3000,3080,true,battery_revision(learned),'').ok,'confirmation required before hardware access');
check(battery_expected_matches({...learned,full_mv:4300,empty_mv:3100},battery_revision(learned)),
    'automatic learning does not create stale-edit failure');
check(!battery_expected_matches({...learned,protect_mv:3200},battery_revision(learned)),
    'concurrent protection edit rejected');
check(!battery_expected_matches({...target,full_mv:4250},battery_revision(target)),
    'concurrent manual baseline edit rejected');
check(!battery_expected_matches(target,battery_revision(learned)),'concurrent mode change rejected');
let state={...learned},events=[],writes=0,reads=0,failWrite=false,failRead=false,alwaysFail=false;
let io={
    mode:function(v) {push(events,'mode'+v);state.manual=v==1;return true;},
    voltages:function(v) {push(events,'voltages');writes++;
        if (alwaysFail || failWrite && writes==1) return false;
        if (!state.manual) return false;
        state={...v};return true;
    },
    protection:function(v) {state.protect_mv=v;return true;},
    wait:function() {push(events,'wait');},
    read:function() {reads++;
        if(failRead && reads==1) return {ok:false};
        if(!state.manual){state.full_mv=4288;state.empty_mv=state.protect_mv;}
        return status(state);
    }
};
let result=battery_transaction(target,status(learned),io);
check(result.ok && result.settings.full_mv==4200 && result.settings.empty_mv==3000 &&
    result.settings.protect_mv==3080 && result.settings.manual,'group saves in manual mode');
check(events[0]=='mode1' && events[1]=='wait' && events[2]=='voltages' && reads==2,
    'mode first, settling delay, grouped write, two independent readbacks');
let nextAuto={...target,manual:false};
result=battery_transaction(nextAuto,status(target),io);
check(result.ok && !result.settings.manual && result.settings.full_mv==4288 &&
    result.settings.empty_mv==3080,'automatic baselines can legitimately relearn');
state={...learned};writes=0;reads=0;failWrite=true;
result=battery_transaction(target,status(learned),io);
check(!result.ok && result.rollback_verified && !state.manual && state.protect_mv==3080,
    'failed voltage write restores original automatic mode and protection');
state={...target};writes=0;reads=0;failWrite=false;failRead=true;
result=battery_transaction({...target,full_mv:4250},status(target),io);
check(!result.ok && result.rollback_verified && state.full_mv==4200 && state.empty_mv==3000,
    'failed verification restores original manual values');
state={...target};writes=0;reads=0;failRead=false;alwaysFail=true;
result=battery_transaction({...target,full_mv:4250},status(target),io);
check(!result.ok && !result.rollback_verified,'unconfirmed recovery never reported as saved');
print('PASS battery grouped writes, firmware learning, revisions, validation and recovery\n');
