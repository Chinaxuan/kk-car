"""Exercise real Linux routing and the controller in three isolated namespaces.

No production interfaces, routes, VPN, firewall or persistent config are changed.
Requires ip-full and kmod-veth on the router.
"""
from pathlib import Path
import json, shlex, subprocess
ROOT=Path(__file__).resolve().parents[2]
SSH=['ssh','-i',str(ROOT/'work/private/pi-admin'),'-o','IdentitiesOnly=yes','-o','UserKnownHostsFile='+str(ROOT/'work/pi-reflash-known-hosts'),'-o','BatchMode=yes','root@192.168.88.1']
def run(c): return subprocess.check_output(SSH+[c],text=True,timeout=35)
def put(p,s): subprocess.run(SSH+['cat > '+shlex.quote(p)],input=s,text=True,check=True)
b=run('mktemp -d /tmp/kk-car-route-test.XXXXXX').strip()
r='kkr'+b[-6:];w='kkw'+b[-6:];m='kkm'+b[-6:]
names=[]
try:
    for n in [r,w,m]: run('ip netns add '+n);names.append(n);run('ip -n '+n+' link set lo up')
    for dev,peer,ns,net in [('eth0','wired',w,'10.250.1'),('eth1','mobile',m,'10.250.2')]:
        run('ip -n '+r+' link add '+dev+' type veth peer name '+peer)
        run('ip -n '+r+' link set '+peer+' netns '+ns)
        run('ip -n '+r+' addr add '+net+'.2/24 dev '+dev)
        run('ip -n '+r+' link set '+dev+' up')
        run('ip -n '+ns+' addr add '+net+'.1/24 dev '+peer)
        run('ip -n '+ns+' link set '+peer+' up')
        run('ip -n '+ns+' addr add 223.5.5.5/32 dev lo')
    run('ip -n '+r+' link add br-lan type bridge')
    run('ip -n '+r+' addr add 192.168.88.1/24 dev br-lan')
    run('ip -n '+r+' link set br-lan up')
    run('ip -n '+r+' route add default via 10.250.2.1 dev eth1 metric 20')
    run('ip -n '+r+' route add default via 10.250.1.1 dev eth0 metric 500')
    run('ip -n '+r+' route add 203.0.113.10/32 via 10.250.2.1 dev eth1 metric 20')
    # Proves the device-bound health probe uses the lower-priority wired route.
    run('ip netns exec '+r+' ping -4 -I eth0 -c 1 -w 2 223.5.5.5 >/dev/null')
    put(b+'/policy.uc',(ROOT/'kk-car-ui/root/etc/kk-car/uplink-policy.uc').read_text())
    put(b+'/model.uc',(ROOT/'kk-car-ui/root/etc/kk-car/uplink-model.uc').read_text().replace('/etc/kk-car/uplink-policy.uc',b+'/policy.uc'))
    source=(ROOT/'kk-car-ui/root/etc/kk-car/uplink-step.uc').read_text()
    source=source.replace('/etc/kk-car/uplink-policy.uc',b+'/policy.uc').replace('/etc/kk-car/uplink-model.uc',b+'/model.uc').replace('/tmp/kk-car-uplink',b+'/state')
    source=source.replace('let c=cursor(), bus=connect();',"let fixture=json(readfile('"+b+"/input.json'));")
    source=source.replace("let mode=c.get('network','kk_ethwan','auto')=='1' ? 'wan' : 'lan';",'let mode=fixture.mode;')
    source=source.replace("let cell=read_cellular(bus), wire=address(bus.call('network.interface.kk_ethwan','status'),'eth0'), lan=address(bus.call('network.interface.lan','status'),'br-lan');",'let cell=fixture.cell, wire=fixture.wire, lan=fixture.lan;')
    source=source.replace("let carrier=trim(readfile('/sys/class/net/eth0/carrier') || '')=='1';",'let carrier=fixture.carrier;')
    source=source.replace('/var/run/charon.pid',b+'/no-vpn.pid').replace('logger -t kk-car-uplink',':')
    put(b+'/step.uc',source)
    f={'mode':'wan','carrier':True,'wire':{'up':True,'ip':'10.250.1.2','mask':24,'gateway':'10.250.1.1','device':'eth0'},'cell':{'up':True,'ip':'10.250.2.2','mask':24,'gateway':'10.250.2.1','device':'eth1'},'lan':{'up':True,'ip':'192.168.88.1','mask':24,'gateway':'','device':'br-lan'}}
    def step():
        put(b+'/input.json',json.dumps(f));run('ip netns exec '+r+' ucode '+b+'/step.uc')
        return json.loads(run('cat '+b+'/state.json'))
    def route(): return run('ip -n '+r+' route get 8.8.8.8 mark 0x10000')
    assert step()['active']=='cellular'
    assert step()['active']=='cellular'
    s=step();assert s['active']=='ethernet' and s['ready'],s
    assert 'dev eth0' in route()
    assert 'dev eth0' in run('ip -n '+r+' route get 8.8.8.8')
    assert 'dev eth0' in run('ip -n '+r+' route get 203.0.113.10')
    run('ip -n '+w+' addr del 223.5.5.5/32 dev lo')
    assert step()['active']=='ethernet','One lost probe must not flap'
    s=step();assert s['active']=='cellular' and s['ready'],s
    assert 'dev eth1' in route()
    assert 'dev eth1' in run('ip -n '+r+' route get 8.8.8.8')
    assert 'dev eth1' in run('ip -n '+r+' route get 203.0.113.10')
    run('ip -n '+w+' addr add 223.5.5.5/32 dev lo')
    for _ in range(3): s=step()
    assert s['active']=='ethernet'
    f['carrier']=False;assert step()['active']=='cellular'
    f['carrier']=True;f['wire']['ip']='192.168.88.2';f['wire']['gateway']='192.168.88.254'
    s=step();assert s['conflict'] and s['active']=='cellular'
    f['wire']['ip']='192.168.0.2';f['wire']['gateway']='192.168.0.1';assert step()['conflict']
    f['mode']='lan';s=step();assert s['active']=='cellular' and s['reason']=='lan'
    f['cell']['up']=False;s=step();assert s['active']=='none'
    assert 'unreachable default' in run('ip -n '+r+' route show table 301')
    assert not any(line.startswith('default via') for line in run('ip -n '+r+' route show table 301').splitlines())
    print('PASS: bound probes; wired preference; marked and unmarked routing; hysteresis; wired recovery; cable removal; subnet conflict; LAN mode; no-uplink blocking')
finally:
    for n in names: run('ip netns del '+n)
    run('rm -rf '+shlex.quote(b))
