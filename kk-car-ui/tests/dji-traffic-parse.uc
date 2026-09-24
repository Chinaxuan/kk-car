#!/usr/bin/ucode
'use strict';
// Run on OpenWrt after installing dji-traffic-parse.uc. Synthetic SMS only.
import { parse_balance } from '/etc/kk-car/dji-traffic-parse.uc';
function check(ok,name) { if (!ok) { print('FAIL '+name+'\n');exit(1); } }
let mixed='[1]:专属定向可使用流量20GB,本月已使用2.00GB,剩余18.00GB\n'+
    '[2]:国内上网可使用流量(含结转)100GB,本月已使用12.50GB,剩余87.50GB';
let result=parse_balance(mixed,'CT');
check(result?.used_bytes==13421772800 && result?.remaining_bytes==93952409600,'domestic only');
check(parse_balance(mixed+'\n[3]:国内上网可使用流量10GB,本月已使用1GB,剩余9GB','CT')==null,'ambiguous domestic package');
check(parse_balance('专属定向流量剩余10GB','CT')==null,'directional only');
check(parse_balance('国内通用流量,本月已使用500MB,剩余1.25GB','CMCC')?.used_bytes==524288000,'MB and GB units');
check(parse_balance('国内通用流量,本月已使用500MB,剩余1.25GB','CT')==null,'operator-specific label');
print('PASS 5 DJI traffic SMS parser cases\n');
