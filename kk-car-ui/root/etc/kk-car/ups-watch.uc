'use strict';
import { readfile, writefile, chmod, popen } from 'fs';
import { connect } from 'ubus';
import { sample,voltage_reference } from '/etc/kk-car/ups-read.uc';
import { policy, power_action } from '/etc/kk-car/ups-control.uc';
import { record_event } from '/etc/kk-car/diagnostic-event.uc';

const STATE='/tmp/kk-car-ups-watch.json';
function uptime_seconds() {
    let raw=trim(readfile('/proc/uptime') || '');
    if (!match(raw,/^[0-9]+(\.[0-9]+)?\s/)) return null;
    let value=+(split(raw,/\s+/)[0] || '');
    return value>=0 ? value : null;
}
function connected_terminals() {
    // A failed presence probe must never be interpreted as an empty hotspot.
    try {
        let stations=connect().call('hostapd.phy0-ap0','get_clients',{})?.clients;
        if (type(stations)!='object') return null;
        let count=0;
        for (let item in stations) if (item?.authorized===true) count++;
        let p=popen('/sbin/uci -q get network.kk_ethwan.auto 2>/dev/null');
        if (!p) return null;
        let wan=trim(p.read('all') || '');
        if (p.close()!=0 || (wan!='0' && wan!='1')) return null;
        if (wan=='0' && trim(readfile('/sys/class/net/eth0/carrier') || '')=='1') count++;
        return count;
    } catch(e) { return null; }
}
function orphaned_timer(previous,data,pending) {
    return !previous?.timestamp && !pending && data?.ok && data.input?.external===true &&
        data.controller?.shutdown_countdown_s>0;
}
function step(config,data,previous,clients,uptime) {
    let prior=previous || {},state={timestamp:time(),enabled:!!config.enabled,
        mode:config.mode=='percent'?'percent':'voltage',
        shutdown_percent:config.shutdown_percent || 10,
        idle_enabled:!!config.idle_enabled,idle_minutes:config.idle_minutes || 60,
        clients:clients ?? null,consecutive:0,percent_consecutive:0,triggered:!!prior.triggered,
        status:'monitoring',threshold_mv:config.mode=='percent'?config.emergency_mv:config.shutdown_mv};
    if (!data?.ok || type(data.input?.external)!='bool') {
        state.status=config.enabled||config.idle_enabled?'read_error':'disabled';
        state.triggered=false;return state;
    }
    let reference=voltage_reference(data);
    state.controller_mv=reference.controller_mv;
    state.sensor_mv=reference.sensor_mv;
    state.battery_mv=reference.millivolts;
    state.voltage_source=reference.source;
    state.voltage_difference_mv=reference.difference_mv;
    state.sensor_voltage_rejected=reference.sensor_rejected;
    state.percent=data.battery?.percent;
    state.external=data.input.external;
    if (!config.enabled && !config.idle_enabled) {
        state.triggered=false;state.status='disabled';return state;
    }
    if (state.external) {state.status='external_power';state.triggered=false;return state;}
    if (config.idle_enabled && clients===0 && uptime!=null && uptime>=0) {
        state.idle_since_uptime=prior.external===false && prior.clients===0 &&
            prior.idle_since_uptime!=null && prior.idle_since_uptime<=uptime ?
            prior.idle_since_uptime : uptime;
        state.idle_elapsed_s=uptime-state.idle_since_uptime;
        if (state.idle_elapsed_s>=state.idle_minutes*60) {
            state.status='idle_shutdown';state.shutdown_reason='idle';
            state.should_shutdown=!state.triggered;
        }
        else state.status='idle_wait';
    }
    else if (config.idle_enabled && clients==null) state.status='clients_unknown';
    else state.status='on_battery';
    if (config.enabled) {
        let threshold=state.threshold_mv;
        if (state.battery_mv==null || state.battery_mv<2500 || state.battery_mv>4500) {
            if (!state.should_shutdown) state.status='invalid_voltage';
        }
        else if (state.battery_mv<=threshold) {
            state.consecutive=(prior.consecutive || 0)+1;
            if (state.consecutive>=3) {
                state.status='low_battery';state.shutdown_reason='low_voltage';
                state.should_shutdown=!state.triggered;
            }
            else if (!state.should_shutdown) state.status='low_battery_wait';
        }
        if (state.mode=='percent') {
            if (type(state.percent)=='int' && state.percent>=0 && state.percent<=100) {
                if (state.percent<=state.shutdown_percent) {
                    state.percent_consecutive=(prior.percent_consecutive || 0)+1;
                    if (state.percent_consecutive>=3 && state.shutdown_reason!='low_voltage') {
                        state.status='low_percent';state.shutdown_reason='low_percent';
                        state.should_shutdown=!state.triggered;
                    }
                    else if (state.shutdown_reason!='low_voltage' && !state.should_shutdown)
                        state.status='low_percent_wait';
                }
            }
            else if (state.status=='on_battery') state.status='invalid_percent';
        }
    }
    if (state.should_shutdown) state.triggered=true;
    else if (state.status!='low_battery' && state.status!='low_percent' && state.status!='idle_shutdown')
        state.triggered=false;
    return state;
}

function run() {
    let old={};try { old=json(readfile(STATE)||'{}'); } catch(e) {}
    let config=policy(),measured=sample(true),next=step(config,measured,old,
        connected_terminals(),uptime_seconds());
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
        // Power or a client may return during the decision. Recheck before
        // arming the UPS countdown or stopping OpenWrt.
        let verify=sample(true);
        let clients=next.shutdown_reason=='idle' ? connected_terminals() : next.clients;
        let voltage=voltage_reference(verify).millivolts;
        let pct=verify?.battery?.percent;
        if (!verify?.ok || verify.input?.external!==false ||
            (next.shutdown_reason=='idle' && clients!==0) ||
            (next.shutdown_reason=='low_voltage' && (voltage==null || voltage>next.threshold_mv)) ||
            (next.shutdown_reason=='low_percent' &&
                (type(pct)!='int' || pct>next.shutdown_percent))) {
            next.should_shutdown=false;next.triggered=false;next.status='decision_cancelled';
            if (next.shutdown_reason=='low_voltage') next.consecutive=0;
            if (next.shutdown_reason=='low_percent') next.percent_consecutive=0;
            if (next.shutdown_reason=='idle' && clients!==0) {
                next.clients=clients;next.idle_since_uptime=null;next.idle_elapsed_s=0;
            }
            record_event('ups_shutdown_cancelled',{external:verify?.input?.external,clients:clients,
                battery_mv:voltage,reason:next.shutdown_reason});
        }
    }
    if (next.should_shutdown) {
        record_event(next.shutdown_reason=='idle'?'idle_shutdown':
            next.shutdown_reason=='low_percent'?'low_percent_shutdown':'low_voltage_shutdown',
            {controller_mv:next.controller_mv,sensor_mv:next.sensor_mv,
            battery_mv:next.battery_mv,threshold_mv:next.threshold_mv,consecutive:next.consecutive,
            voltage_source:next.voltage_source,external:next.external,
            clients:next.clients,idle_elapsed_s:next.idle_elapsed_s,
            percent:next.percent,threshold_percent:next.shutdown_percent});
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
