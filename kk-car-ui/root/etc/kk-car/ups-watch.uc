'use strict';
import { readfile, writefile, chmod } from 'fs';
import { sample,voltage_reference } from '/etc/kk-car/ups-read.uc';
import { policy, power_action } from '/etc/kk-car/ups-control.uc';
import { record_event } from '/etc/kk-car/diagnostic-event.uc';

const STATE='/tmp/kk-car-ups-watch.json';
function orphaned_timer(previous,data,pending) {
    return !previous?.timestamp && !pending && data?.ok && data.input?.external===true &&
        data.controller?.shutdown_countdown_s>0;
}
function step(config,data,previous) {
    let prior=previous || {},state={timestamp:time(),enabled:!!config.enabled,
        consecutive:0,triggered:!!prior.triggered,status:'monitoring',threshold_mv:config.shutdown_mv};
    if (!data?.ok) {state.status=config.enabled?'read_error':'disabled';state.triggered=false;return state;}
    let reference=voltage_reference(data);
    state.controller_mv=reference.controller_mv;
    state.sensor_mv=reference.sensor_mv;
    state.battery_mv=reference.millivolts;
    state.voltage_source=reference.source;
    state.voltage_difference_mv=reference.difference_mv;
    state.sensor_voltage_rejected=reference.sensor_rejected;
    state.external=!!data.input?.external;
    if (!config.enabled) {state.triggered=false;state.status='disabled';return state;}
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
    let measured=sample(true),next=step(policy(),measured,old);
    if (old.status!=next.status) record_event('ups_transition',{state:next.status,
        controller_mv:next.controller_mv,sensor_mv:next.sensor_mv,battery_mv:next.battery_mv,
        threshold_mv:next.threshold_mv,external:next.external,consecutive:next.consecutive,
        voltage_source:next.voltage_source});
    // A previous power loss can leave the UPS timer armed in a new OS boot.
    // Cancel once at watcher startup on external power, but preserve an explicit
    // power action already issued in this boot (including a service restart).
    if (orphaned_timer(old,measured,!!readfile('/tmp/kk-car-power-intent.json'))) {
            let left=measured.controller.shutdown_countdown_s;
            record_event('ups_countdown_orphaned',{shutdown_s:left,external:true});
            let cancelled=power_action('cancel_shutdown','');
            next.startup_countdown_cancelled=!!cancelled.ok;
            if (cancelled.ok) record_event('ups_countdown_cancelled',{shutdown_s:left,external:true});
    }
    if (next.should_shutdown) {
        record_event('low_voltage_shutdown',{controller_mv:next.controller_mv,sensor_mv:next.sensor_mv,
            battery_mv:next.battery_mv,threshold_mv:next.threshold_mv,consecutive:next.consecutive,
            voltage_source:next.voltage_source,external:next.external});
        // Make the last decision observable before the OS shutdown is scheduled.
        writefile(STATE,sprintf('%J',next));chmod(STATE,0600);
        let action=power_action('shutdown','关闭树莓派');
        next.action_ok=!!action.ok;
        next.action_error=action.error || null;
        if (!action.ok) next.triggered=false;
    }
    writefile(STATE,sprintf('%J',next));chmod(STATE,0600);
    return next;
}

export { step,run,orphaned_timer };
