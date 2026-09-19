"""Measure 30-day history queries using generated journals in isolated RAM storage."""
from pathlib import Path
import io,json,tarfile,subprocess,shlex
ROOT=Path(__file__).resolve().parents[2]
SSH=['ssh','-i',str(ROOT/'work/private/pi-admin'),'-o','IdentitiesOnly=yes','-o','UserKnownHostsFile='+str(ROOT/'work/pi-reflash-known-hosts'),'-o','BatchMode=yes','root@192.168.88.1']
def run(c): return subprocess.check_output(SSH+[c],text=True,timeout=40)
b=run('mktemp -d /tmp/kk-history-volume.XXXXXX').strip()
now=1789804800
try:
    buffer=io.BytesIO()
    with tarfile.open(fileobj=buffer,mode='w:gz') as tar:
        def add(name,content):
            raw=content.encode();item=tarfile.TarInfo(name);item.size=len(raw);tar.addfile(item,io.BytesIO(raw))
        for d in range(31):
            day=now//86400-d
            lines=[json.dumps([day*86400+i*60,1.1,.12,28.456,18,17,20.1,60.4,6,60,-82.5,2]) for i in range(1440)]
            add(str(day)+'.jsonl','\n'.join(lines)+'\n')
            hours=[{'row':[day*86400+h*3600,1.1,.12,28.456,1080,1020,20.1,60.4,360,3600,-82.5,120], 'minutes':60,'first':day*86400+h*3600,'last':day*86400+h*3600+3540} for h in range(24)]
            add(str(day)+'.hours.json',json.dumps(hours))
        add('lib.uc',(ROOT/'kk-car-ui/root/etc/kk-car/history.uc').read_text())
        add('run.uc',"import {history} from '"+b+"/lib.uc'; import {readfile} from 'fs';let before=+(split(readfile('/proc/uptime'),' ')[0]);let h=history('30d',"+str(now)+",'"+b+"/missing','"+b+"');let elapsed=+(split(readfile('/proc/uptime'),' ')[0])-before;let signals=0;for(let p in h.points) signals+=p[11] || 0;printf('%J\\n',{minutes:h.minutes,points:length(h.points),signal_samples:signals,signal_min:h.points[0][10],seconds:elapsed});")
    subprocess.run(SSH+['tar -xz -C '+shlex.quote(b)],input=buffer.getvalue(),check=True)
    result=json.loads(run('ucode '+b+'/run.uc'))
    assert result['minutes']==43201 and result['points']==721,result
    assert result['signal_samples']==86402 and result['signal_min']==-82.5,result
    assert result['seconds']<8,result
    print('PASS: 30-day volume',json.dumps(result))
    print(run('du -sh '+b).strip())
finally:
    run('rm -r '+shlex.quote(b))
