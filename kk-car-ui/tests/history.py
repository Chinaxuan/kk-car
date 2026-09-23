"""Router-side isolated history tests; no production files or networking changed."""
from pathlib import Path
import json, shlex, subprocess
ROOT=Path(__file__).resolve().parents[2]
SSH=['ssh','-i',str(ROOT/'work/private/pi-admin'),'-o','IdentitiesOnly=yes','-o','UserKnownHostsFile='+str(ROOT/'work/pi-reflash-known-hosts'),'-o','BatchMode=yes','root@192.168.88.1']
def run(cmd): return subprocess.check_output(SSH+[cmd],text=True,timeout=40)
def put(path,text): subprocess.run(SSH+['cat > '+shlex.quote(path)],input=text,text=True,check=True)
base=run('mktemp -d /tmp/kk-history-test.XXXXXX').strip()
try:
    put(base+'/lib.uc',(ROOT/'kk-car-ui/root/etc/kk-car/history.uc').read_text())
    code=r'''
import { record,history,aggregate,rebuild_hours } from 'BASE/lib.uc';
import { readfile,writefile,mkdir,unlink,glob } from 'fs';
let ram='BASE/ram.json',disk='BASE/disk',t=1789800600;
function probe(at,up,received) { return {timestamp:at,uptime:up,avg_ms:received?20.0:null,min_ms:received?10.0:null,max_ms:received?30.0:null,sent:3,received}; }
for (let i=0;i<38;i++) record(probe(t+i*10,100+i*10,i==12?0:3),{mode:'lan',rx:i*1250000,tx:i*125000},'boot1',ram,disk);
let first=history('1h',t+380,ram,disk);
let state=json(readfile(ram));
printf('%J\n',{first,storage_error:state.storage_error,files:glob(disk+'/*'),content:readfile(glob(disk+'/*')[0])});
// Restart destroys RAM but must retain completed, flushed minute history.
unlink(ram);
printf('%J\n',{recovered:history('1h',t+390,ram,disk)});
record(probe(t+400,1,3),{mode:'lan',rx:99999999,tx:99999999},'boot2',ram,disk);
printf('%J\n',{restart:history('1h',t+400,ram,disk)});
record(probe(t+410,11,3),{mode:'wan',rx:199999999,tx:199999999},'boot2',ram,disk);
printf('%J\n',{modechange:json(readfile(ram)).rows});
printf('%J\n',{weighted:aggregate([[t,1,2,10,3,3,5,15,1,10],[t+10,3,4,40,3,1,30,50,1,20]],t)});
// Independent 31-day journal fixture, plus a malformed final record.
let long='BASE/long';mkdir(long,0700);
for(let d=0;d<32;d++) {
    let at=t-d*86400,row=[at,1,2,20,3,3,10,30,1,10];
    writefile(long+'/'+int(at/86400)+'.jsonl',sprintf('%J\n',row)+'[torn');
    rebuild_hours(long,int(at/86400));
}
printf('%J\n',{month:history('30d',t+60,'BASE/empty',long),day:history('1d',t+60,'BASE/empty',long),invalid:history('../x',t,ram,disk)});
// Signal data must aggregate independently of VPN replies, survive rollups,
// ignore stale/replayed/invalid readings and preserve gaps in old journals.
let sr='BASE/signal.json',sd='BASE/signals';
function sample(at,rsrp,seen) { record(probe(at,at-t+100,0),{mode:'lan',rx:0,tx:0,signal:{timestamp:seen,rsrp}},'sigboot',sr,sd); }
sample(t,-80,t);sample(t+10,-80,t);sample(t+20,-100,t+20);
sample(t+30,-999,t+30);sample(t+40,-60,t+100);sample(t+50,-70,t-100);
sample(t+60,-60,t+60);
let sig=history('1h',t+60,sr,sd);unlink(sr);
printf('%J\n',{signal:sig,signal_recovered:history('1h',t+70,sr,sd),negative:aggregate([[t,null,null,null,0,0,null,null,1,0,-85.125,1]],t),mixed:aggregate([[t,1,2,20,3,3,10,30,1,10],[t+10,1,2,20,3,3,10,30,1,10,-80,1],[t+20,1,2,20,3,3,10,30,1,10,-100,3]],t)});
// A replacement modem with larger counters must not create a traffic spike.
let cr='BASE/counter-source.json',cd='BASE/counter-source';
record(probe(t,100,3),{mode:'lan',source:'eth1',rx:100,tx:100},'sameboot',cr,cd);
record(probe(t+10,110,3),{mode:'lan',source:'wwan0',rx:90000000,tx:90000000},'sameboot',cr,cd);
record(probe(t+20,120,3),{mode:'lan',source:'wwan0',rx:91250000,tx:90125000},'sameboot',cr,cd);
printf('%J\n',{sourcechange:json(readfile(cr)).rows});
'''.replace('BASE',base)
    # ucode source requires one escaped newline, not a literal backslash-n output.
    code=code.replace('\\n','\n')
    put(base+'/test.uc',code)
    results=[json.loads(line) for line in run('ucode '+base+'/test.uc').splitlines()]
    first=results[0];assert not first['storage_error'],first
    observed=[p for p in first['first']['points'] if p[8]]
    assert len(observed)==7 and abs(observed[1][1]-1)<.001,observed
    assert any(p[4]>p[5] for p in observed),observed
    assert results[1]['recovered']['minutes']>=6,results[1]
    assert [p for p in results[2]['restart']['points'] if p[8]][-1][1] is None
    assert results[3]['modechange'][-1][1] is None
    assert abs(results[4]['weighted'][1]-2.333)<.001 and results[4]['weighted'][3]==17.5
    final=results[5]
    assert 720<=len(final['month']['points'])<=722 and final['month']['minutes']==30
    assert final['day']['minutes']==1 and final['invalid']['ok'] is False
    assert any(p[8]==0 and p[3] is None for p in final['month']['points'])
    assert results[7]['sourcechange'][1][1] is None,results[7]
    assert results[7]['sourcechange'][2][1:3]==[1,0.1],results[7]
    signal=results[6];pts=[p for p in signal['signal']['points'] if p[8]]
    assert pts[0][10:]==[-90,2] and pts[0][3] is None,pts
    assert pts[1][10:]==[-60,1],pts
    assert [p for p in signal['signal_recovered']['points'] if p[8]][0][10:]==[-90,2]
    assert signal['negative'][10]==-85.125 and signal['mixed'][10:]==[-95,4],signal
    assert all(p[10] is None and p[11]==0 for p in final['month']['points']),final
    print('PASS: distinct signal samples, stale/future/invalid rejection, negative values, mixed-version weighted signal rollups, persistence; ')
    print('PASS: sampling rates, loss, batched persistence, RAM loss/restart, interface changes, weighted rollups, 30-day bounds, corrupt tails, gaps, invalid range')
finally:
    run('rm -r '+shlex.quote(base))
