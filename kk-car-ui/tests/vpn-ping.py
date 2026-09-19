"""Exercise the actual router parser without changing live VPN or probe state."""
from pathlib import Path
import json, shlex, subprocess
ROOT = Path(__file__).resolve().parents[2]
SSH = ['ssh', '-i', str(ROOT/'work/private/pi-admin'), '-o', 'IdentitiesOnly=yes',
       '-o', 'UserKnownHostsFile='+str(ROOT/'work/pi-reflash-known-hosts'),
       '-o', 'BatchMode=yes', 'root@192.168.88.1']
def run(cmd):
    return subprocess.check_output(SSH+[cmd], text=True, timeout=15)
def put(path, text):
    subprocess.run(SSH+['cat > '+shlex.quote(path)], input=text, text=True, check=True)
base = run('mktemp -d /tmp/kk-car-ping-test.XXXXXX').strip()
try:
    put(base+'/parse.uc', (ROOT/'kk-car-ui/root/etc/kk-car/vpn-ping-parse.uc').read_text())
    cases = [
        ('3 packets transmitted, 3 packets received, 0% packet loss\nround-trip min/avg/max = 23.882/24.249/24.945 ms', 'probe', 'ok', 24.249, 0),
        ('3 packets transmitted, 2 packets received, 33% packet loss\nround-trip min/avg/max = 10.0/20.0/30.0 ms', 'probe', 'loss', 20, 100/3),
        ('3 packets transmitted, 0 packets received, 100% packet loss', 'probe', 'timeout', None, 100),
        ('ping: bad address', 'probe', 'error', None, None),
        ('', 'vpn_down', 'vpn_down', None, None),
        ('3 packets transmitted, 1 packets received, 66% packet loss\nround-trip min/avg/max = 30/20/10 ms', 'probe', 'error', None, 200/3),
    ]
    put(base+'/cases.json', json.dumps(cases))
    put(base+'/test.uc', "import { parse_probe } from '"+base+"/parse.uc';\nimport { readfile } from 'fs';\nfor (let c in json(readfile('"+base+"/cases.json'))) printf('%J\\n',parse_probe(c[0],c[1]));")
    rows = [json.loads(line) for line in run('ucode '+base+'/test.uc').splitlines()]
    for case, result in zip(cases, rows):
        assert result['state']==case[2] and result['avg_ms']==case[3], result
        if case[4] is None: assert result['loss_percent'] is None
        else: assert abs(result['loss_percent']-case[4])<.001, result
    assert len(rows)==len(cases)
    print('PASS: reachable, partial loss, timeout, command failure, VPN unavailable, invalid timings')
finally:
    run('rm -r '+shlex.quote(base))
