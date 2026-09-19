'use strict';
import { readfile } from 'fs';
import { cursor } from 'uci';
import { record } from '/etc/kk-car/history.uc';
let probe=json(readfile('/tmp/kk-car-vpn-ping.json') || '{}');
let modem={};
try { modem=json(readfile('/tmp/kk-car-modem.json') || '{}'); } catch(e) {}
let signal=modem.online && match(modem.network || '',/LTE/i) ? {timestamp:modem.timestamp,rsrp:modem.rsrp} : {};
let wired=cursor().get('network','kk_ethwan','auto')=='1';
function counter(device,kind) { return +(trim(readfile('/sys/class/net/'+device+'/statistics/'+kind+'_bytes') || '0')); }
record(probe,{signal,mode:wired?'wan':'lan',rx:counter('eth1','rx')+(wired?counter('eth0','rx'):0),
    tx:counter('eth1','tx')+(wired?counter('eth0','tx'):0)},trim(readfile('/proc/sys/kernel/random/boot_id') || ''));
