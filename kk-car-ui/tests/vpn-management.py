#!/usr/bin/env python3
"""Exercise VPN reply routing with a fake ip/uci backend; never touch host routes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / 'root/etc/kk-car/vpn-management-route.sh'
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['FAKE_DB']); d = json.loads(p.read_text()); a = sys.argv[1:]
name = Path(sys.argv[0]).name
if name == 'flock': sys.exit(0)
if name == 'uci': print('1' if d['enabled'] else '0'); sys.exit(0)
if a[:4] == ['-o', '-4', 'addr', 'show']:
    for addr in d['addresses']: print('5: ikecar inet ' + addr + '/32 scope global ikecar')
elif a == ['-4', 'rule', 'show']:
    for rule in d['rules']: print(rule)
elif a[:3] in (['-4','rule','add'], ['-4','rule','del']):
    op = a[2]; src = a[a.index('from') + 1]
    rule = '9980: from ' + src.removesuffix('/32') + ' lookup 300'
    if d.get('fail') == op + ':' + src: sys.exit(1)
    if op == 'add': d['rules'].append(rule)
    else: d['rules'].remove(rule)
    p.write_text(json.dumps(d))
else: raise RuntimeError(a)
'''
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp); db = root / 'db.json'; state = root / 'owned'
    for name in ['ip', 'uci', 'flock']:
        p = root / name; p.write_text(FAKE); p.chmod(0o755)
    script = root / 'route.sh'
    script.write_text(SOURCE.read_text().replace('/tmp/kk-car-vpn-management-sources', str(state)).replace('/var/lock/kk-car-vpn-management.lock', str(root / 'lock')))
    env = dict(os.environ, PATH=str(root)+':'+os.environ['PATH'], FAKE_DB=str(db))
    other = ['0: from all lookup local', '9980: from 192.0.2.99 lookup 301', '9990: from all fwmark 0x10000/0xff0000 lookup 301']
    data = dict(enabled=True, addresses=['192.0.2.2'], rules=other.copy())
    def save(): db.write_text(json.dumps(data))
    def run(code=0):
        result = subprocess.run(['/bin/sh', str(script)], env=env)
        assert result.returncode == code, result.returncode
        data.update(json.loads(db.read_text()))
        assert all(r in data['rules'] for r in other), 'Unrelated rule modified'
    save(); run(); run()
    assert data['rules'].count('9980: from 192.0.2.2 lookup 300') == 1
    data['addresses'] = ['192.0.2.3']; save(); run()
    assert '9980: from 192.0.2.2 lookup 300' not in data['rules']
    assert '9980: from 192.0.2.3 lookup 300' in data['rules']
    data['addresses'] = ['192.0.2.4']; data['fail'] = 'del:192.0.2.3/32'; save(); run(1)
    assert set(state.read_text().split()) == {'192.0.2.3/32', '192.0.2.4/32'}
    data.pop('fail'); save(); run()
    assert '9980: from 192.0.2.3 lookup 300' not in data['rules']
    data['enabled'] = False; save(); run(); assert data['rules'] == other
    data['enabled'] = True; data['addresses'] = ['192.0.2.5']; data['fail'] = 'add:192.0.2.5/32'; save(); run(1)
    data.pop('fail'); save(); run()
    assert '9980: from 192.0.2.5 lookup 300' in data['rules']
    data['addresses'] = []; save(); run(); assert data['rules'] == other
print('PASS: idempotence, VIP change, disable/disconnect cleanup, partial failure retry, unrelated rules preserved')
