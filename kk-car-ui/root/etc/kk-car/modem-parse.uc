'use strict';
import { readfile, writefile, rename } from 'fs';
let raw = readfile('/tmp/kk-car-modem.raw') || '', values = {};
for (let line in split(raw, '\n')) {
    let m = match(trim(line), /^([a-z_]+)=(.*)$/);
    if (m) values[m[1]] = m[2];
}
function metric(key, low, high) {
    let s = values[key];
    if (s == null || !match(s, /^-?[0-9]+(\.[0-9]+)?$/)) return null;
    let n = +s;
    return n >= low && n <= high ? n : null;
}
let uptime = metric('uptime', 0, 1e10);
let online = ARGV[0] == '0' && values.kkcar_probe == '1' && uptime != null;
let data = {timestamp:time(), online};
if (online) {
    data.operator = substr(values.network_provider || '', 0, 80);
    data.network = substr(values.network_type || '', 0, 40);
    data.connected = values.ppp_status == 'ppp_connected';
    data.roaming = values.simcard_roam == 'Home' ? false : values.simcard_roam == 'Roaming' ? true : null;
    data.bars = metric('signalbar', 0, 5);
    data.rssi = metric('rssi', -140, -1);
    data.rsrp = metric('lte_rsrp', -150, -30);
    data.uptime = uptime;
    data.connection_uptime = metric('realtime_time', 0, 1e10);
    data.rx = metric('cellular_rx', 0, 9e15);
    data.tx = metric('cellular_tx', 0, 9e15);
}
writefile('/tmp/kk-car-modem.json.new', sprintf('%J', data));
rename('/tmp/kk-car-modem.json.new', '/tmp/kk-car-modem.json');
