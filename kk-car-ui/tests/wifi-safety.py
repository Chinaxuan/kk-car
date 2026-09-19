"""Exercise the real Wi-Fi transaction code against isolated router fixtures.

The UCI cursor, all writable paths and the Wi-Fi reload command are redirected.
No production network configuration or service is changed by these tests.
"""
from pathlib import Path
import json
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SSH = ['ssh', '-i', str(ROOT/'work/private/pi-admin'), '-o', 'IdentitiesOnly=yes',
       '-o', 'UserKnownHostsFile='+str(ROOT/'work/pi-reflash-known-hosts'),
       '-o', 'BatchMode=yes', 'root@192.168.88.1']

def remote(command):
    p = subprocess.run(SSH+[command], text=True, capture_output=True, check=True)
    return p.stdout

def put(path, data):
    subprocess.run(SSH+['cat > '+shlex.quote(path)], input=data, text=True, check=True)

base = remote('mktemp -d /tmp/kk-car-ui-test.XXXXXX').strip()
assert base.startswith('/tmp/kk-car-ui-test.')
try:
    remote('mkdir -p '+base+'/config '+base+'/saved '+base+'/etc/kk-car '+base+'/tmp')
    original="config wifi-device 'radio0'\n option band '2g'\n option channel '6'\n option htmode 'HT20'\n\nconfig wifi-iface 'default_radio0'\n option ssid 'Fixture-Old'\n option key 'FixtureOnly-NotReal'\n"
    put(base+'/config/wireless', original)
    # Replace temporary paths before injecting the fixture's own /tmp prefix.
    source=(ROOT/'kk-car-ui/root/usr/share/rpcd/ucode/kkcar.uc').read_text()
    source=source.replace('/tmp/kk-car',base+'/tmp/kk-car').replace('/etc/kk-car/',base+'/etc/kk-car/').replace('/etc/config/wireless',base+'/config/wireless')
    source=source.replace("import { cursor } from 'uci';", "import { cursor as base_cursor } from 'uci';\nfunction cursor() { return base_cursor('"+base+"/config', '"+base+"/saved'); }")
    start=source.index('function launch(kind) {'); end=source.index('function failjob()',start)
    source=source[:start]+'function launch(kind) { return true; }\n'+source[end:]
    put(base+'/backend.uc',source)
    def invoke(method,args=None):
        expr="let m=loadfile('"+base+"/backend.uc')(); print(sprintf('%J',m.kkcar."+method+".call({args:"+json.dumps(args or {})+"})));"
        return json.loads(remote('ucode -e '+shlex.quote(expr)))
    assert invoke('wifi_save',{'ssid':'Fixture-Old','password':''})['unchanged']
    assert not invoke('wifi_save',{'ssid':'','password':''})['ok']
    assert not invoke('wifi_save',{'ssid':'Fixture-Old','password':'short'})['ok']
    assert not invoke('wifi_save',{'ssid':'bad\nname','password':''})['ok']
    assert not invoke('wifi_save',{'ssid':'中'*11,'password':''})['ok']
    assert not invoke('wifi_save',{'ssid':'Fixture-Old','password':'','band':'6g'})['ok']
    # Shell punctuation remains literal UCI data, not executable code.
    target='Fixture-$()\'"'
    saved=invoke('wifi_save',{'ssid':target,'password':''})
    assert saved['ok'] and saved['pending']['ssid']==target
    assert not invoke('action',{'action':'diagnose'})['ok'], 'Concurrent work must be blocked'
    config=remote('uci -c '+base+'/config -P '+base+'/saved -q get wireless.default_radio0.ssid').strip()
    assert config==target, config
    assert remote('cat '+base+'/etc/kk-car/ui-wifi-backup')==original

    job=(ROOT/'kk-car-ui/root/etc/kk-car/ui-job.sh').read_text()
    job=job.replace('/tmp/kk-car',base+'/tmp/kk-car').replace('/etc/kk-car/',base+'/etc/kk-car/').replace('/etc/config/wireless',base+'/config/wireless')
    job=job.replace('wifi reload >/dev/null 2>&1',': # Wi-Fi reload stubbed for isolated fixture')
    job=job.replace('sleep 4','sleep 0')
    put(base+'/job.sh',job)
    # Unconfirmed settings expire and restore the original UCI file.
    put(base+'/etc/kk-car/ui-wifi-pending.json',json.dumps({'deadline':1,'ssid':target}))
    remote('sh '+base+'/job.sh wifi_apply')
    assert remote('cat '+base+'/config/wireless')==original
    assert '自动恢复' in json.loads(remote('cat '+base+'/tmp/kk-car-ui-job.json'))['message']
    # Confirmed settings survive; rollback artifacts are removed.
    assert invoke('wifi_save',{'ssid':'Fixture-New','password':'','band':'5g'})['ok']
    assert remote('uci -c '+base+'/config -P '+base+'/saved -q get wireless.radio0.band').strip()=='5g'
    assert remote('uci -c '+base+'/config -P '+base+'/saved -q get wireless.radio0.channel').strip()=='149'
    assert remote('uci -c '+base+'/config -P '+base+'/saved -q get wireless.radio0.htmode').strip()=='VHT20'
    assert invoke('wifi_confirm')['ok']
    remote('sh '+base+'/job.sh wifi_apply')
    assert 'Fixture-New' in remote('cat '+base+'/config/wireless')
    assert '已确认' in json.loads(remote('cat '+base+'/tmp/kk-car-ui-job.json'))['message']
    assert remote('test ! -e '+base+'/etc/kk-car/ui-wifi-backup && echo clean').strip()=='clean'
    # A power loss during the trial must restore the original file before netifd starts.
    put(base+'/etc/kk-car/ui-wifi-backup',original)
    put(base+'/etc/kk-car/ui-wifi-pending.json','{"deadline":1}')
    boot=(ROOT/'kk-car-ui/root/etc/init.d/kk-car-ui-recovery').read_text()
    boot=boot.replace('/etc/kk-car/',base+'/etc/kk-car/').replace('/etc/config/wireless',base+'/config/wireless').replace("logger -t kk-car-ui",':')
    put(base+'/boot.sh',boot+'\nboot\n')
    remote('sh '+base+'/boot.sh')
    assert remote('cat '+base+'/config/wireless')==original
    print('PASS: validation, unchanged save, literal shell characters, persisted UCI, job lock, timed rollback, confirmed retention, band switch, backup cleanup, boot recovery')
finally:
    remote('rm -rf '+shlex.quote(base))
