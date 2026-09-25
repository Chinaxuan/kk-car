'use strict';
import { readfile, writefile, chmod } from 'fs';
import { sample } from '/etc/kk-car/ups-read.uc';
import { policy, power_action } from '/etc/kk-car/ups-control.uc';

const STATE='/tmp/kk-car-ups-watch.json';
function step(config,data,previous) {
    let prior=previous || {},state={timestamp:time(),enabled:!!config.enabled,
        consecutive:0,triggered:!!prior.triggered,status:'monitoring'};
    if (!config.enabled) {state.triggered=false;state.status='disabled';return state;}
    if (!data?.ok) {state.status='read_error';state.triggered=false;return state;}
    state.battery_mv=data.battery?.millivolts;
    state.external=!!data.input?.external;
    if (state.external) {state.status='external_power';state.triggered=false;return state;}
    if (state.battery_mv==null || state.battery_mv<2500 || state.battery_mv>4500) {
        state.status='invalid_voltage';state.triggered=false;return state;
    }
    if (state.battery_mv>config.shutdown_mv) {state.status='on_battery';state.triggered=false;return state;}
    state.consecutive=(prior.consecutive || 0)+1;
    state.status=state.consecutive>=3?'low_battery':'low_battery_wait';
    state.should_shutdown=state.consecutive>=3 && !state.triggered;
    if (state.should_shutdown) state.triggered=true;
    return state;
}

function run() {
    let old={};try { old=json(readfile(STATE)||'{}'); } catch(e) {}
    let next=step(policy(),sample(true),old);
    if (next.should_shutdown) {
        let action=power_action('shutdown','关闭树莓派');
        next.action_ok=!!action.ok;
        next.action_error=action.error || null;
        if (!action.ok) next.triggered=false;
    }
    writefile(STATE,sprintf('%J',next));chmod(STATE,0600);
    return next;
}

export { step,run };
