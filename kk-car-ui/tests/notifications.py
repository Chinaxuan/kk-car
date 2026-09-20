"""Isolated ucode notification state/config tests; never send a real Webhook."""
from pathlib import Path
import subprocess,shlex,json
root=Path(__file__).resolve().parents[2]
ssh=['ssh','-i',str(root/'work/private/pi-admin'),'-o','IdentitiesOnly=yes','-o','UserKnownHostsFile='+str(root/'work/pi-reflash-known-hosts'),'-o','BatchMode=yes','root@192.168.88.1']
def run(cmd):return subprocess.check_output(ssh+[cmd],text=True,timeout=30)
def put(p,s):subprocess.run(ssh+['cat > '+shlex.quote(p)],input=s,text=True,check=True)
b=run('mktemp -d /tmp/kk-notify-test.XXXXXX').strip()
try:
 for n in ['notify-config.uc','notify-engine.uc']:
  put(b+'/'+n,(root/'kk-car-ui/root/etc/kk-car'/n).read_text())
 test=r'''
import {step} from 'BASE/notify-engine.uc';
import {defaults,validate_config,public_config,valid_url} from 'BASE/notify-config.uc';
let count=0;function ok(v,label){if(!v)die('FAIL '+label+'\n');count++;}
let c=defaults();c.enabled=true;
function snap(t,v,p,loss){v=v??true;p=p??20;loss=loss??0;return {timestamp:10000+t,vpn:v,uplink:'cellular',ping:{timestamp:10000+t,avg_ms:p,loss_percent:loss,sent:3},rsrp:-90,temperature:50,undervoltage:false,clients:{}};}
let s={};function tick(t,x){let r=step(s,x || snap(t),c,t);s=r.state;return r.events;}
function has(events,k){return length(filter(events,e=>e.kind==k))>0;}
ok(length(tick(0))==0,'baseline silent');
ok(!has(tick(10,snap(10,false)),'vpn_down'),'vpn debounce');
ok(has(tick(20,snap(20,false)),'vpn_down'),'vpn down');
ok(!has(tick(30,snap(30,true)),'vpn_up'),'up debounce');
ok(has(tick(40),'vpn_up'),'vpn up');
ok(!has(tick(50,snap(50,true,400)),'latency'),'spike waiting');
tick(60);ok(!has(tick(80,snap(80,true,400)),'latency'),'spike reset');
ok(has(tick(110,snap(110,true,400)),'latency'),'sustained latency');
ok(!has(tick(130,snap(130,true,290)),'latency'),'hysteresis band');
tick(140);ok(has(tick(170),'latency'),'recovery');
tick(180,snap(180,true,400));ok(!has(tick(210,snap(210,true,400)),'latency'),'cooldown');
s={};tick(0);tick(10,snap(10,true,400));let stale=snap(50,true,400);stale.ping.timestamp=1;tick(50,stale);ok(!has(tick(60,snap(60,true,400)),'latency'),'stale resets hold');
ok(has(tick(90,snap(90,true,400)),'latency'),'fresh sustained after stale');
s={};tick(0);tick(10,snap(10,true,null,100));ok(has(tick(40,snap(40,true,null,100)),'loss'),'100 percent loss');
s={};let power=snap(0);power.undervoltage=true;tick(0,power);power.timestamp=10010;ok(has(tick(10,power),'power'),'current undervoltage');
s={};let hot=snap(0);hot.temperature=85;tick(0,hot);hot.timestamp=10030;ok(has(tick(30,hot),'temperature'),'hot hold');
s={};let weak=snap(0);weak.rsrp=-120;tick(0,weak);weak.timestamp=10030;ok(!has(tick(30,weak),'signal'),'signal 60 seconds minimum');weak.timestamp=10060;ok(has(tick(60,weak),'signal'),'weak signal');
s={};let client=snap(0);client.clients={'aa:bb:cc:dd:ee:ff':'phone'};ok(!has(tick(0,client),'client_join'),'existing clients baseline');
client.timestamp=10010;client.clients['ab:bb:cc:dd:ee:ff']='new';ok(has(tick(10,client),'client_join'),'new client');ok(!has(tick(20,client),'client_join'),'client dedup');c.events.client_leave=true;
ok(!has(tick(100),'client_leave'),'leave grace');ok(has(tick(140),'client_leave'),'leave timeout');
s={};tick(0);let uplink=snap(10);uplink.uplink='ethernet';tick(10,uplink);uplink.timestamp=10020;ok(has(tick(20,uplink),'uplink'),'uplink transition');
s={};tick(0);tick(10,snap(10,true,400));ok(!has(tick(100,snap(100,true,400)),'latency'),'long monitor gap resets continuity');
s={};c.enabled=false;tick(0);tick(10,snap(10,false));ok(length(tick(20,snap(20,false)))==0,'master disabled');c.enabled=true;c.events.vpn_down=false;s={};tick(0);tick(10,snap(10,false));ok(!has(tick(20,snap(20,false)),'vpn_down'),'event disabled');
c=defaults();c.enabled=true;c.events.recovery=false;s={};tick(0,snap(0,true,400));tick(30,snap(30,true,400));tick(40);ok(!has(tick(70),'latency'),'recovery disabled');
let old=defaults();old.destinations[0].url='https://open.feishu.cn/open-apis/bot/v2/hook/00000000-0000-0000-0000-000000000000';let input=public_config(old);
ok(!index(sprintf('%J',input),'00000000-0000')>=0,'placeholder');
ok(input.destinations[0].url==null,'secret not returned');
input.enabled=true;input.destinations[0].enabled=true;ok(validate_config(input,old).ok,'keep stored secret');
input.destinations[0].clear=true;ok(!validate_config(input,old).ok,'cannot enable cleared address');input.destinations[0].clear=false;
input.latency_ms=0;ok(!validate_config(input,old).ok,'threshold validated');input.latency_ms=300;
input.destinations[0].url='https://open.feishu.cn.evil.example/hook/x';ok(!validate_config(input,old).ok,'SSRF host rejected');
ok(!valid_url('http://127.0.0.1/'),'localhost rejected');ok(!valid_url(old.destinations[0].url+'\n'),'newline rejected');
printf('PASS %d notification engine/config assertions\n',count);
'''.replace('BASE',b).replace("ok(!index(sprintf('%J',input),'00000000-0000')>=0,'placeholder');","ok(index(sprintf('%J',input),'00000000-0000')<0,'secret absent from serialized response');")
 put(b+'/test.uc',test)
 print(run('ucode '+b+'/test.uc').strip())
 worker=(root/'kk-car-ui/root/etc/kk-car/notify-worker.uc').read_text().replace('/etc/kk-car/notify-',b+'/notify-')
 put(b+'/notify-worker.uc',worker)
 print(run('ucode -c -o '+b+'/worker.ucb '+b+'/notify-worker.uc && echo "PASS worker compilation"').strip())
 # Exercise the whole worker with fake observations and an in-process HTTP stub.
 # All state/config/queue writes stay in the temporary directory; no Webhook request.
 run('mkdir -p '+b+'/tmp '+b+'/private')
 put(b+'/worker-config.uc',"import {readfile} from 'fs'; function read_config(){return json(readfile('"+b+"/config.json'));} export {read_config};")
 put(b+'/bus.uc',"import {readfile} from 'fs'; function connect(){return {call:function(object,method){if(object=='kkcar')return json(readfile('"+b+"/sample.json'));return {clients:{}};}};} export {connect};")
 config=json.loads(run('ucode -e '+shlex.quote("import {defaults} from '"+b+"/notify-config.uc'; printf('%J',defaults());")))
 config['enabled']=True;config['revision']=1
 config['destinations'][0].update(enabled=True,url='https://open.feishu.cn/open-apis/bot/v2/hook/00000000-0000-0000-0000-000000000000')
 put(b+'/config.json',json.dumps(config))
 put(b+'/sample.json',json.dumps({'timestamp':1,'vpn':{'connected':True},'uplink':{'active':'cellular'},'peers':[],'power':{'known':True,'undervoltage':False},'temperature':50}))
 original=(root/'kk-car-ui/root/etc/kk-car/notify-worker.uc').read_text()
 worker=original.replace("from 'ubus'", "from '"+b+"/bus.uc'").replace("from '/etc/kk-car/notify-config.uc'", "from '"+b+"/worker-config.uc'").replace("from '/etc/kk-car/notify-engine.uc'", "from '"+b+"/notify-engine.uc'")
 worker=worker.replace('/tmp/kk-car-',b+'/tmp/kk-car-').replace('/etc/kk-car/private',b+'/private')
 start=worker.index('function run(cmd)')
 end=worker.index('let lock=',start)
 worker=worker[:start]+"function run(cmd){if(index(cmd,'/usr/bin/curl')==0){let fixture=read('"+b+"/http.json');write('"+b+"/tmp/kk-car-notify-response.json',fixture.body);return fixture.http;}return '';}\n"+worker[end:]
 put(b+'/worker.uc',worker)
 def execute(mode=''):
  run('ucode '+b+'/worker.uc '+mode)
  status=json.loads(run('cat '+b+'/tmp/kk-car-notify-status.json'))
  assert 'error' not in status,status
  return status
 put(b+'/http.json',json.dumps({'http':'200 OK','body':{'code':0}}))
 assert execute()['queued']==0
 put(b+'/tmp/kk-car-notify-test.json',json.dumps({'revision':1}))
 out=execute();assert out['deliveries']['primary']['ok'] and out['queued']==0,out
 # HTTP success is insufficient when Feishu reports a business error.
 put(b+'/http.json',json.dumps({'http':'200 OK','body':{'code':19024}}))
 put(b+'/tmp/kk-car-notify-test.json',json.dumps({'revision':1}))
 out=execute();assert not out['deliveries']['primary']['ok'] and out['queued']==1,out
 # A future config revision request must not be consumed by an older worker.
 put(b+'/tmp/kk-car-notify-test.json',json.dumps({'revision':2}))
 execute();assert run('test -f '+b+'/tmp/kk-car-notify-test.json && echo yes').strip()=='yes'
 run('rm '+b+'/tmp/kk-car-notify-test.json')
 # Disable an address/master: no requests and no stale queue delivered later.
 config['revision']=2;config['enabled']=False;put(b+'/config.json',json.dumps(config))
 assert execute()['queued']==0
 config['revision']=3;config['enabled']=True;put(b+'/config.json',json.dumps(config))
 put(b+'/http.json',json.dumps({'http':'200 OK','body':{'code':0}}))
 out=execute('shutdown');assert out['deliveries']['primary']['ok'] and '正常关机' in out['log'][-1]['text'],out
 marker=json.loads(run('cat '+b+'/private/notify-boot.json'));assert marker['clean']
 assert execute()['queued']==0
 print('PASS worker integration: successful delivery, Feishu business error, queued retry, revision race, disabled master, shutdown and service restart')
finally:run('rm -rf '+shlex.quote(b))
