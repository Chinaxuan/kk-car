'use strict';
import { readfile } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import { record } from '/etc/kk-car/history.uc';
import { read_cellular } from '/etc/kk-car/uplink-model.uc';
let probe=json(readfile('/tmp/kk-car-vpn-ping.json') || '{}');
let modem={};
try { modem=json(readfile('/tmp/kk-car-modem.json') || '{}'); } catch(e) {}
let signal=modem.online && match(modem.network || '',/LTE/i) ? {timestamp:modem.timestamp,rsrp:modem.rsrp} : {};
let wired=cursor().get('network','kk_ethwan','auto')=='1';
let bus=connect(), cellular=bus ? read_cellular(bus) : {}, device=cellular.device || '';
if (bus) bus.disconnect();
function counter(device,kind) { return +(trim(readfile('/sys/class/net/'+device+'/statistics/'+kind+'_bytes') || '0')); }
record(probe,{signal,mode:wired?'wan':'lan',source:device+(wired?'+eth0':''),rx:counter(device,'rx')+(wired?counter('eth0','rx'):0),
    tx:counter(device,'tx')+(wired?counter('eth0','tx'):0)},trim(readfile('/proc/sys/kernel/random/boot_id') || ''));
