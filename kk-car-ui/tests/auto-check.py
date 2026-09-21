#!/usr/bin/env python3
"""Isolated scheduler tests: virtual uptime/clock/RPC, no host routes or services."""
import concurrent.futures,json,os,signal,subprocess,tempfile
from pathlib import Path
SOURCE=Path(__file__).resolve().parents[1]/'root/etc/kk-car/auto-check.sh'
FAKE=r'''#!/usr/bin/env python3
import json,os,signal,sys
from pathlib import Path
p=Path(os.environ['CASE_ROOT']); now=int((p/'uptime').read_text().split('.')[0]); mode=os.environ['CASE_MODE']; name=Path(sys.argv[0]).name
if name=='flock': sys.exit(0)
if name=='date': print(1700000000+now+(100000 if mode=='clock_jump' and now>400 else 0))
elif name=='jsonfilter': print('true' if json.loads(sys.stdin.read() or '{}').get('accepted') else 'false')
elif name=='ubus':
 assert sys.argv[1:]==['-t','5','call','kkcar','action','{"action":"diagnose"}']
 log=p/'calls'; calls=log.read_text().splitlines() if log.exists() else []
 with log.open('a') as f:f.write(str(now)+'\n')
 lock=p/'ui-lock'
 if not calls and mode=='busy':lock.mkdir();print('{"accepted":false}')
 elif not calls and mode=='rpc_error':print('{}')
 else:
  if lock.exists():lock.rmdir()
  print('{"accepted":true}')
elif name=='sleep':
 now+=int(sys.argv[1]);(p/'uptime').write_text(str(now)+'.00 0\n')
 if now>=int(os.environ['CASE_END']):os.kill(os.getppid(),signal.SIGTERM)
'''
def run_case(mode,start,expected):
 with tempfile.TemporaryDirectory() as t:
  p=Path(t);(p/'uptime').write_text(str(start)+'.00 0\n')
  (p/'lib').write_text('json_init() { :; }; json_add_boolean() { :; }; json_add_int() { :; }; json_add_string() { :; }; json_dump() { echo "{}"; };\n')
  for n in ('flock','date','jsonfilter','ubus','sleep'):
   f=p/n;f.write_text(FAKE);f.chmod(0o755)
  s=SOURCE.read_text().replace('/usr/share/libubox/jshn.sh',str(p/'lib')).replace('/proc/uptime',str(p/'uptime')).replace('/var/lock/kk-car-auto-check.lock',str(p/'worker-lock')).replace('/tmp/kk-car-ui-lock',str(p/'ui-lock')).replace('/tmp/kk-car-auto-check.json',str(p/'state.json'))
  (p/'scheduler').write_text(s)
  env=dict(os.environ,PATH=str(p)+':'+os.environ['PATH'],CASE_ROOT=t,CASE_MODE=mode,CASE_END=str(start+1320))
  result=subprocess.run(['/bin/sh',str(p/'scheduler')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
  assert result.returncode in (-signal.SIGTERM,128+signal.SIGTERM),result.stderr.decode()
  calls=list(map(int,(p/'calls').read_text().splitlines()))
  assert calls==expected,(mode,calls,expected)
  return mode+': '+str(calls)
cases=[('normal',100,[115,715,1315]),('busy',100,[115,130,730,1330]),('rpc_error',100,[115,175,775,1375]),('clock_jump',100,[115,715,1315]),('boot',0,[60,660,1260])]
with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
 for line in pool.map(lambda args:run_case(*args),cases):print('PASS',line)
