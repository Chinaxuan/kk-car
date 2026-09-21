#!/usr/bin/env python3
"""Run pure display helpers in the target ucode runtime; no device state writes.
Optional KK_CAR_TEST_HOST (default 192.168.88.1), KK_CAR_TEST_PROXY_COMMAND,
KK_CAR_TEST_HOST_KEY_ALIAS select an already-authorized SSH path.
"""
import os
from pathlib import Path
import subprocess
source=Path(__file__).resolve().parents[1]/'root/etc/kk-car/hdmi.uc'
prefix=source.read_text().split('let args=ARGV',1)[0]
assert 'while(true)' not in prefix and 'let bus=connect()' not in prefix
checks=r'''
let count=0;
function check(actual,expected){
 if(sprintf('%J',actual)!=sprintf('%J',expected))die(sprintf('Expected %J, got %J\n',expected,actual));
 count++;
}
check(memoryPercent({total:1000,available:840,free:300}),16.0);
check(memoryPercent({total:1000,available:0,free:300}),100.0);
check(memoryPercent({total:1000,free:250}),75.0);
check(memoryPercent({total:1000,available:1000}),0.0);
check(memoryPercent({total:1000,available:1100}),0.0);
check(memoryPercent({total:0,available:0}),null);
check(memoryPercent({total:1000}),null);
check(memoryPercent({total:1000,available:-1}),null);
check(memoryPercent(null),null);
check(fmt(12.345,1,'ms'),'12.3ms');
check(fmt(-68,0,' dBm'),'-68 dBm');
check(fmt(null,1,'ms'),'未知');
check(chars('中文AB'),['中','文','A','B']);
check(duration(3660),'1小时01分');
check(fresh(100,110,25),true);
check(fresh(100,126,25),false);
check(fresh(120,110,25),false);
check(bytes(1000000000),'1.00 GB');
print(sprintf('PASS: %d display helper cases\n',count));
'''
cmd=['ssh','-i','work/private/pi-admin','-o','IdentitiesOnly=yes','-o','UserKnownHostsFile=work/pi-reflash-known-hosts','-o','BatchMode=yes','-o','ConnectTimeout=8']
for env,opt in [('KK_CAR_TEST_PROXY_COMMAND','ProxyCommand'),('KK_CAR_TEST_HOST_KEY_ALIAS','HostKeyAlias')]:
 if os.environ.get(env):cmd+=['-o',opt+'='+os.environ[env]]
cmd+=['root@'+os.environ.get('KK_CAR_TEST_HOST','192.168.88.1'),'ucode -']
subprocess.run(cmd,input=prefix+checks,text=True,check=True)
