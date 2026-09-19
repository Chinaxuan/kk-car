'use strict';
import { readfile, writefile, rename } from 'fs';
import { parse_probe } from '/etc/kk-car/vpn-ping-parse.uc';
let data = parse_probe(readfile('/tmp/kk-car-vpn-ping.raw') || '', ARGV[0]);
data.timestamp = time();
data.uptime = +(split(readfile('/proc/uptime') || '0', ' ')[0]);
data.target = '10.8.8.8'; data.interface = 'ikecar'; data.interval = 10;
if (writefile('/tmp/kk-car-vpn-ping.json.new', sprintf('%J', data)))
    rename('/tmp/kk-car-vpn-ping.json.new', '/tmp/kk-car-vpn-ping.json');
