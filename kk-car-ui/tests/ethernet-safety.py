"""Test Ethernet configuration transactions against isolated router UCI files."""
from pathlib import Path
import json, shlex, subprocess
ROOT=Path(__file__).resolve().parents[2]
SSH=['ssh','-i',str(ROOT/'work/private/pi-admin'),'-o','IdentitiesOnly=yes','-o','UserKnownHostsFile='+str(ROOT/'work/pi-reflash-known-hosts'),'-o','BatchMode=yes','root@192.168.88.1']
def run(c): return subprocess.check_output(SSH+[c],text=True,timeout=30)
def put(p,s): subprocess.run(SSH+['cat > '+shlex.quote(p)],input=s,text=True,check=True)
b=run('mktemp -d /tmp/kk-car-port-test.XXXXXX').strip()
try:
    run('mkdir -p '+b+'/config '+b+'/saved '+b+'/etc/kk-car '+b+'/tmp')
    original="config device 'bridge'\n option name 'br-lan'\n option type 'bridge'\n list ports 'eth0'\n list ports 'fixture-other'\nconfig interface 'kk_ethwan'\n option device 'eth0'\n option auto '0'\nconfig interface 'lan'\n option device 'br-lan'\n option ipaddr '192.168.88.1/24'\n"
    put(b+'/config/network',original)
    source=(ROOT/'kk-car-ui/root/usr/share/rpcd/ucode/kkcar.uc').read_text()
    source=source.replace('/tmp/kk-car',b+'/tmp/kk-car').replace('/etc/kk-car/',b+'/etc/kk-car/').replace('/etc/config/network',b+'/config/network')
    source=source.replace("import { cursor } from 'uci';", "import { cursor as base_cursor } from 'uci';\nfunction cursor() { return base_cursor('"+b+"/config', '"+b+"/saved'); }")
    start=source.index('function launch(kind) {');end=source.index('function failjob()',start)
    source=source[:start]+'function launch(kind) { return true; }\n'+source[end:]
    put(b+'/backend.uc',source)
    def invoke(method,args=None):
        e="let m=loadfile('"+b+"/backend.uc')(); print(sprintf('%J',m.kkcar."+method+".call({args:"+json.dumps(args or {})+"})));"
        return json.loads(run('ucode -e '+shlex.quote(e)))
    def uci(key): return run('uci -c '+b+'/config -P '+b+'/saved -q get '+key).strip()
    assert invoke('port_save',{'mode':'lan'})['unchanged']
    assert not invoke('port_save',{'mode':'wan;reboot'})['ok']
    assert invoke('port_save',{'mode':'wan'})['ok']
    assert uci('network.kk_ethwan.auto')=='1'
    assert uci('network.bridge.ports')=='fixture-other'
    assert not invoke('action',{'action':'diagnose'})['ok']
    assert run('cat '+b+'/etc/kk-car/ui-port-backup')==original
    job=(ROOT/'kk-car-ui/root/etc/kk-car/ui-job.sh').read_text()
    job=job.replace('/tmp/kk-car',b+'/tmp/kk-car').replace('/etc/kk-car/',b+'/etc/kk-car/').replace('/etc/config/network',b+'/config/network')
    job=job.replace('sleep 4','sleep 0').replace('ifdown kk_ethwan',':').replace('ifup kk_ethwan',':').replace('/etc/init.d/network reload',':')
    job=job.replace(b+'/etc/kk-car/disable-ipv6.sh',':')
    job=job.replace('uci -q get network.kk_ethwan.auto','uci -c '+b+'/config -P '+b+'/saved -q get network.kk_ethwan.auto')
    put(b+'/job.sh',job)
    put(b+'/etc/kk-car/ui-port-pending.json','{"deadline":1,"mode":"wan"}')
    run('sh '+b+'/job.sh port_apply')
    assert run('cat '+b+'/config/network')==original
    assert invoke('port_save',{'mode':'wan'})['ok']
    assert invoke('port_confirm')['ok']
    run('sh '+b+'/job.sh port_apply')
    assert uci('network.kk_ethwan.auto')=='1' and uci('network.bridge.ports')=='fixture-other'
    assert invoke('port_save',{'mode':'lan'})['ok']
    assert 'eth0' in uci('network.bridge.ports') and 'fixture-other' in uci('network.bridge.ports')
    # Boot recovery restores the saved WAN config before networking begins.
    boot=(ROOT/'kk-car-ui/root/etc/init.d/kk-car-ui-recovery').read_text().replace('/etc/kk-car/',b+'/etc/kk-car/').replace('/etc/config/network',b+'/config/network').replace('logger -t kk-car-ui',':')
    put(b+'/boot.sh',boot+'\nboot\n');run('sh '+b+'/boot.sh')
    assert uci('network.kk_ethwan.auto')=='1'
    assert uci('network.bridge.ports')=='fixture-other'
    print('PASS: invalid role rejected; only eth0 moved; lock enforced; timeout rollback; confirmation; LAN restoration; boot rollback')
finally:
    run('rm -rf '+shlex.quote(b))
