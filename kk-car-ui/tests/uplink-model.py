"""Test runtime WAN discovery and routing decisions in isolated router RAM.

Every route, probe, logger and VPN service command is replaced with a recorder.
nft --check only validates a disposable candidate; it does not install rules.
No production network/configuration files or services are changed.
"""
from pathlib import Path
import json, re, shlex, subprocess

ROOT = Path(__file__).resolve().parents[2]
SSH = ['ssh', '-i', str(ROOT/'work/private/pi-admin'), '-o', 'IdentitiesOnly=yes',
       '-o', 'UserKnownHostsFile='+str(ROOT/'work/pi-reflash-known-hosts'),
       '-o', 'BatchMode=yes', 'root@192.168.88.1']

def run(command):
    return subprocess.check_output(SSH+[command], text=True, timeout=35)

def put(path, content):
    subprocess.run(SSH+['cat > '+shlex.quote(path)], input=content,
                   text=True, check=True, timeout=35)

base = run('mktemp -d /tmp/kk-uplink-model.XXXXXX').strip()
try:
    for name in ('uplink-policy.uc', 'uplink-model.uc'):
        source = (ROOT/'kk-car-ui/root/etc/kk-car'/name).read_text()
        put(base+'/'+name, source.replace('/etc/kk-car/', base+'/'))
    tests = r'''
import {wan_device,address,cellular,route_path,route_options,selected_identity} from 'BASE/uplink-model.uc';
import {decide} from 'BASE/uplink-policy.uc';
function check(value,message) { if(!value) die(message+'\n'); }
function status(device,ip,gateway) {
    return {up:true,l3_device:device,'ipv4-address':[{address:ip,mask:24}],route:[{target:'0.0.0.0',mask:0,nexthop:gateway}]};
}
for(let device in ['eth0','eth1','eth12','wwan0','wwan12','usb0']) check(wan_device(device)==device,'safe USB device');
for(let device in ['',null,'eth1;reboot','eth1\n','/dev/cdc-wdm0','br-lan','ikecar','eth1234567890123x','wwan0.1']) check(!wan_device(device),'unsafe device');
let old=status('eth1','192.168.0.2','192.168.0.1'), cell=cellular(old,[]);
check(cell.up && cell.device=='eth1' && cell.gateway=='192.168.0.1','legacy CDC');
let parent={up:true,l3_device:'wwan0'}, child=status('wwan0','10.23.4.2','10.23.4.1');
child.dynamic=true; child.interface='wan_4';
cell=cellular(parent,[child]);check(cell.up && cell.device=='wwan0' && cell.ip=='10.23.4.2','QMI dynamic IPv4 child');
check(cellular({up:true,device:'/dev/cdc-wdm0'},[child]).up,'control node is not a network device');
child.l3_device='usb0';check(!cellular(parent,[child]).up,'reject child on another device');
child.l3_device='wwan0';child.dynamic=false;check(!cellular(parent,[child]).up,'reject non-dynamic child');
child.dynamic=true;child.interface='lan_4';check(!cellular(parent,[child]).up,'reject unrelated logical child');
let direct=status('wwan0','10.23.4.2','');direct['ipv4-address'][0].mask=32;
cell=cellular(direct,[]);check(cell.up && cell.default_route && route_path(cell)=='dev wwan0','device-only default');
let down={up:false,ip:'',mask:0,gateway:''};
check(decide('lan',down,cell,down,{},false,false).active=='cellular','QMI without next hop usable');
direct.route=[];cell=cellular(direct,[]);
check(decide('lan',down,cell,down,{},false,false).active=='none','IP without default not usable');
direct.route=[{target:'0.0.0.0',mask:0,nexthop:'10.23.4.1'}];cell=cellular(direct,[]);
check(route_options(cell)==' onlink','raw-IP off-subnet gateway');
let before=selected_identity('cellular',cell);cell.ip='10.23.4.3';check(before!=selected_identity('cellular',cell),'address transition');
cell=cellular({up:false,l3_device:'wwan0'},[]);check(!cell.up && !cell.default_route,'no SIM/no lease is offline');
check(!address(status('wwan0;reboot','10.23.4.2','10.23.4.1')).up,'malformed interface is unusable');
print('PASS: F30 CDC; runtime USB names; dynamic QMI children; absent SIM; default route requirements; raw-IP /32; unsafe input rejection\n');
'''.replace('BASE', base)
    put(base+'/model-test.uc', tests)
    print(run('ucode '+shlex.quote(base+'/model-test.uc')).strip())

    source = (ROOT/'kk-car-ui/root/etc/kk-car/uplink-step.uc').read_text()
    source = source.replace('/etc/kk-car/', base+'/').replace('/tmp/kk-car-uplink', base+'/state')
    endpoint = re.search(r"let endpoint=run\('ip -4 route show ([0-9.]+)/32'\)", source).group(1)
    source = source.replace(endpoint, '192.0.2.10')
    start = source.index('function run(command)')
    end = source.index('function has_route(')
    recorder = '''
let fixture=json(readfile('BASE/input.json')), commands=[];
function run(s) {
    if(index(s,'rule show')>=0) return '9990: from all fwmark 0x10000/0xff0000 lookup 301';
    if(index(s,'table 301')>=0) return fixture.routes || '';
    if(index(s,'default dev eth0')>=0) return fixture.main || '';
    return '';
}
function command(s) {
    push(commands,s);
    if(index(s,'ping ')>=0) return !!fixture.probe;
    return !(fixture.fail_route && index(s,'route replace default')>=0);
}
let c={get:function(){return fixture.mode=='wan' ? '1' : '0';}};
let bus={call:function(name,method){
    if(name=='network.interface.wan') return fixture.parent;
    if(name=='network.interface') return {interface:fixture.children || []};
    if(name=='network.interface.kk_ethwan') return fixture.wire;
    if(name=='network.interface.lan') return fixture.lan;
    return {};
}};
'''.replace('BASE', base)
    source = source[:start]+recorder+source[end:]
    source = source.replace('let c=cursor(), bus=connect();', '')
    source = source.replace("let carrier=trim(readfile('/sys/class/net/eth0/carrier') || '')=='1';", 'let carrier=!!fixture.carrier;')
    source = source.replace("access('/var/run/charon.pid')", 'fixture.vpn_running')
    source += "\nwritefile('"+base+"/commands.json',sprintf('%J',commands));\n"
    put(base+'/controller.uc', source)

    def status(device, address, gateway='', mask=24):
        return {'up': True, 'l3_device': device, 'ipv4-address': [{'address': address, 'mask': mask}],
                'route': [{'target': '0.0.0.0', 'mask': 0, 'nexthop': gateway}]}

    fixture = {'mode': 'lan', 'parent': status('eth1', '192.168.0.2', '192.168.0.1'),
               'wire': {}, 'lan': status('br-lan', '192.168.88.1'), 'vpn_running': True}

    def step():
        put(base+'/input.json', json.dumps(fixture))
        run('ucode '+shlex.quote(base+'/controller.uc'))
        state = json.loads(run('cat '+shlex.quote(base+'/state.json')))
        commands = json.loads(run('cat '+shlex.quote(base+'/commands.json')))
        return state, commands

    state, commands = step()
    assert state['active'] == 'cellular' and state['cell']['device'] == 'eth1'
    assert not any('swanctl' in command for command in commands), 'first observation should not restart VPN'
    fixture['parent'] = {'up': True, 'l3_device': 'wwan0'}
    child = status('wwan0', '10.23.4.2', mask=32)
    child.update(dynamic=True, interface='wan_4')
    fixture['children'] = [child]
    fixture['routes'] = '192.168.0.0/24 dev eth1 scope link src 192.168.0.2\n10.22.1.1 dev usb1 scope link src 10.22.1.1'
    state, commands = step()
    assert state['device'] == 'wwan0' and state['ready']
    assert 'ip -4 route replace default dev wwan0 table 301 metric 10' in commands
    assert any('route del 192.168.0.0/24 dev eth1 table 301' in command for command in commands)
    assert any('route del 10.22.1.1 dev usb1 table 301' in command for command in commands)
    assert sum('swanctl' in command for command in commands) == 2, 'same category device replacement needs VPN rebuild'
    state, commands = step()
    assert not any('swanctl' in command for command in commands), 'stable observation must not flap VPN'
    child['ipv4-address'][0]['address'] = '10.23.4.3'
    fixture['fail_route'] = True
    state, commands = step()
    assert not state['ready'] and not any('swanctl' in command for command in commands)
    fixture['fail_route'] = False
    state, commands = step()
    assert state['ready'] and sum('swanctl' in command for command in commands) == 2, 'retry failed route then rebuild VPN'
    fixture['vpn_running'] = False
    child['ipv4-address'][0]['address'] = '10.23.4.4'
    state, commands = step()
    assert not any('swanctl' in command for command in commands), 'preserve paused VPN'
    fixture['children'] = []
    fixture['routes'] = 'default dev wwan0 metric 10\n10.23.4.4 dev wwan0 scope link src 10.23.4.4'
    state, commands = step()
    assert state['active'] == 'none'
    assert 'ip -4 route replace unreachable default table 301 metric 32767' in commands
    assert 'ip -4 route del default table 301 metric 10' in commands
    print('PASS: device-only routes; stale eth/USB/host-route cleanup; same-category device/IP change; delayed retry; paused VPN; no-uplink blocking')

    for name in ('history.uc', 'notify-config.uc'):
        source = (ROOT/'kk-car-ui/root/etc/kk-car'/name).read_text()
        put(base+'/'+name, source.replace('/etc/kk-car/', base+'/'))
    backend = (ROOT/'kk-car-ui/root/usr/share/rpcd/ucode/kkcar.uc').read_text()
    put(base+'/backend.uc', backend.replace('/etc/kk-car/', base+'/'))
    # Loading the method table parses all imports without invoking any RPC,
    # running a service, or reading production configuration.
    run('ucode -e '+shlex.quote("let m=loadfile('"+base+"/backend.uc')(); if(!m.kkcar.status) die('status method missing');"))
    job = (ROOT/'kk-car-ui/root/etc/kk-car/ui-job.sh').read_text()
    guard = re.search(r'        valid_wan_device\(\) \{\n.*?\n        \}', job, re.S).group(0)
    guard = guard.replace('/sys/class/net/', base+'/fake-net/')
    run('mkdir -p '+shlex.quote(base+'/fake-net/wwan0')+' '+shlex.quote(base+'/fake-net/eth2'))
    put(base+'/device-check.sh', guard+'\nvalid_wan_device "$1"\n')
    for device, expected in [('wwan0', True), ('eth2', True), ('usb9', False), ('wwan0;true', False), ('eth2\nwwan0', False), ('', False)]:
        result = run('if sh '+shlex.quote(base+'/device-check.sh')+' '+shlex.quote(device)+'; then echo yes; else echo no; fi').strip()
        assert (result == 'yes') == expected
    print('PASS: RPC module/import load; diagnostic binding rejects missing, malformed and multiline devices')

    # Compile the complete source prefix dataset unchanged, in check-only mode.
    nft = (ROOT/'kk-car-ui/root/etc/nftables.d/20-kk-car-china.nft').read_text()
    for family in ('eth', 'wwan', 'usb'):
        assert f'oifname "{family}*" ip saddr' in nft
        assert f'oifname "{family}*" ip daddr {{ 1.1.1.1, 1.0.0.1 }}' in nft
    put(base+'/guard.nft', 'table inet kk_car_candidate_check {\n'+nft+'\n}\n')
    run('nft --check --file '+shlex.quote(base+'/guard.nft'))
    print('PASS: complete nft candidate check; eth/wwan/usb fail-closed and DNS guard coverage')
finally:
    run('rm -r '+shlex.quote(base))
