'use strict';
import { readfile, writefile, rename } from 'fs';

function metric(value, low, high) {
    if (value == null || !match('' + value, /^-?[0-9]+(\.[0-9]+)?$/)) return null;
    let n = +value;
    return n >= low && n <= high ? n : null;
}
function text(value, max) {
    return type(value) == 'string' ? substr(replace(value, /[[:cntrl:]]/g, ''), 0, max) : '';
}
function decode(value) {
    try { return json(value || 'null'); } catch (e) { return null; }
}
function private_ip(value) {
    if (type(value) != 'string') return null;
    let p = split(value, '.');
    if (length(p) != 4) return null;
    for (let n in p) if (!match(n, /^[0-9]{1,3}$/) || +n > 255) return null;
    return (+p[0] == 10 || (+p[0] == 172 && +p[1] >= 16 && +p[1] <= 31) || (+p[0] == 192 && +p[1] == 168)) ? value : null;
}
function parse_modem(raw, rc, timestamp) {
    let values = {};
    for (let line in split(raw || '', '\n')) {
        let m = match(trim(line), /^([a-z_]+)=(.*)$/);
        if (m) values[m[1]] = m[2];
    }
    let data = {timestamp, online:false,collector_rc:metric(rc,0,255),collector_state:values.collector_state=='wan_initializing'?'wan_initializing':+rc==124?'timeout':'sampled'};
    if (values.transport == 'QMI') {
        let signal = decode(values.qmi_signal), serving = decode(values.qmi_serving);
        let status = decode(values.qmi_data), caps = decode(values.qmi_capabilities);
        let sim = decode(values.qmi_sim);
        if (type(signal) != 'object') signal = {};
        if (type(serving) != 'object') serving = {};
        if (type(caps) != 'object') caps = {};
        if (type(sim) != 'object') sim = {};
        let registration = serving.registration;
        let valid_registration = index(['registered','searching','not_registered','not-registered','denied','unknown'], registration) >= 0;
        let valid_status = index(['connected','disconnected','suspended','authenticating'], status) >= 0;
        let radio = type(signal.type) == 'string' ? lc(signal.type) : '';
        let valid_signal = index(['lte','gsm','wcdma','cdma','evdo','td-scdma','nr5g'], radio) >= 0;
        let valid_caps = type(caps.networks) == 'array' && length(caps.networks) > 0;
        data.online = '' + rc == '0' && values.kkcar_probe == '1' && (valid_signal || valid_status || valid_registration || valid_caps);
        data.transport = 'QMI';
        data.model = text(values.model, 80) || 'Quectel LTE';
        data.firmware = null;
        // Failed registration alone does not prove that the SIM is absent.
        let sim_states = {ready:'ready', pin1_or_upin_required:'pin_required', puk1_or_upuk_required:'puk_required', pin_required:'pin_required', puk_required:'puk_required', absent:'absent', blocked:'blocked', permanently_blocked:'blocked'};
        data.sim_state = sim_states[sim.card_application_state] || 'unknown';
        if (data.online) {
            data.connected = valid_status ? status == 'connected' : null;
            data.operator = text(serving.plmn_description, 80);
            data.network = valid_signal ? uc(radio) : '';
            data.registration = valid_registration ? registration : null;
            data.roaming = type(serving.roaming) == 'bool' ? serving.roaming : null;
            data.bars = null;
            data.rssi = metric(signal.rssi, -140, -1);
            data.rsrp = metric(signal.rsrp, -150, -30);
            data.rsrq = metric(signal.rsrq, -40, 20);
            data.snr = metric(signal.snr, -30, 50);
            data.band = null;
            data.cell = null;
            data.uptime = null;
            data.connection_uptime = null;
            data.rx = metric(values.cellular_rx, 0, 9e15);
            data.tx = metric(values.cellular_tx, 0, 9e15);
        }
        return data;
    }
    let uptime = metric(values.uptime, 0, 1e10);
    data.online = '' + rc == '0' && values.kkcar_probe == '1' && uptime != null;
    data.transport = 'ADB';
    data.model = 'ZTE F30A Pro';
    data.management_ip = private_ip(values.management_ip);
    data.sim_state = 'unknown';
    if (data.online) {
        data.operator = text(values.network_provider, 80);
        data.network = text(values.network_type, 40);
        data.connected = values.ppp_status == 'ppp_connected';
        data.roaming = values.simcard_roam == 'Home' ? false : values.simcard_roam == 'Roaming' ? true : null;
        data.bars = metric(values.signalbar, 0, 5);
        data.rssi = metric(values.rssi, -140, -1);
        data.rsrp = metric(values.lte_rsrp, -150, -30);
        data.rsrq = null;
        data.snr = null;
        data.band = null;
        data.cell = null;
        data.uptime = uptime;
        data.connection_uptime = metric(values.realtime_time, 0, 1e10);
        data.rx = metric(values.cellular_rx, 0, 9e15);
        data.tx = metric(values.cellular_tx, 0, 9e15);
    }
    return data;
}

function merge_at(data,at,now) {
    if (data.transport!='QMI' || type(at)!='object' || !at.timestamp || now<at.timestamp || now-at.timestamp>75)
        return data;
    let rsrp=metric(at.rsrp_dbm,-150,-30),rssi=metric(at.rssi_dbm,-140,-1);
    if (rsrp==null && rssi==null) return data;
    // Radio availability is distinct from a data session. A valid AT signal
    // does not make connected=true or turn a failed data query into success.
    data.online=true;
    if (data.connected==null) data.connected=null;
    if (data.rsrp==null) {data.rsrp=rsrp;data.rssi=rssi;
        data.rsrq=metric(at.rsrq_db,-40,20);data.snr=metric(at.sinr_db,-30,50);
        data.signal_source='AT';data.signal_timestamp=at.timestamp;}
    else {data.signal_source='QMI';data.signal_timestamp=data.timestamp;}
    data.network=data.network || (match(at.technology || '',/LTE/)?'LTE':'');
    data.band=match(at.band || '',/^LTE B[0-9]{1,3}$/)?at.band:null;
    if (data.sim_state=='unknown' && at.sim_pin_state=='ready') data.sim_state='ready';
    if (data.rsrp!=null) {data.bars=data.rsrp>=-80?5:data.rsrp>=-90?4:data.rsrp>=-100?3:data.rsrp>=-110?2:1;data.bars_estimated=true;}
    return data;
}

// CLI entry point; fixture tests exercise parse_modem without any state writes.
let data = parse_modem(readfile('/tmp/kk-car-modem.raw'), ARGV[0], time());
data=merge_at(data,decode(readfile('/tmp/kk-car-dji-at.json')),time());
writefile('/tmp/kk-car-modem.json.new', sprintf('%J', data));
rename('/tmp/kk-car-modem.json.new', '/tmp/kk-car-modem.json');
