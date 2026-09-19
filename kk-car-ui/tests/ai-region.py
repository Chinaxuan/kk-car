"""Isolated router-side parser fixtures; no production state/network edits."""
from pathlib import Path
import json,shlex,subprocess
root=Path(__file__).resolve().parents[2]
ssh=['ssh','-i',str(root/'work/private/pi-admin'),'-o','IdentitiesOnly=yes','-o','UserKnownHostsFile='+str(root/'work/pi-reflash-known-hosts'),'-o','BatchMode=yes','root@192.168.88.1']
def run(s):return subprocess.check_output(ssh+[s],text=True,timeout=20)
def put(p,s):subprocess.run(ssh+['cat > '+shlex.quote(p)],input=s,text=True,check=True)
b=run('mktemp -d /tmp/kk-region-test.XXXXXX').strip()
try:
 put(b+'/lib.uc',(root/'kk-car-ui/root/etc/kk-car/ai-region.uc').read_text())
 fixtures=[]
 def case(provider,body,code=200,rc=0,state='unknown',country=None):fixtures.append([provider,body,code,rc,state,country])
 case('chatgpt','h=chatgpt.com\nloc=JP\n',state='non_cn',country='JP')
 case('chatgpt','h=chatgpt.com\r\nloc=CN\r\n',state='cn',country='CN')
 for body in ['h=other.com\nloc=JP','h=chatgpt.com\nloc=ZZ','h=chatgpt.com\nloc=AA','h=chatgpt.com\nloc=JP\nloc=CN','<html>loc=JP</html>'] :case('chatgpt',body)
 for code,rc in [(403,0),(429,0),(302,0),(200,28),(200,63),(0,7)]:case('chatgpt','h=chatgpt.com\nloc=JP',code,rc)
 for country,state in [('CN','cn'),('JP','non_cn'),('HK','non_cn'),('ZZ','unknown')]:
  case('gemini','window.WIZ_global_data='+json.dumps({'vXmutd':'%.@."'+country+'","ZZ","x"]'}),state=state,country=None if state=='unknown' else country)
 case('gemini','<html lang="zh-CN">Japan US</html>')
 case('gemini','{"vXmutd":"broken"}')
 case('gemini','{"vXmutd":"%.@.\\"CN\\",\\"ZZ\\"]"}',403)
 put(b+'/fixtures.json',json.dumps(fixtures))
 put(b+'/test.uc',f"import {{ classify }} from '{b}/lib.uc'; import {{ readfile }} from 'fs'; for(let f in json(readfile('{b}/fixtures.json'))) printf('%J\\n',classify(f[0],f[1],f[2],f[3]));")
 results=[json.loads(l) for l in run('ucode '+b+'/test.uc').splitlines()]
 for f,r in zip(fixtures,results):assert (r['state'],r['country'])==(f[4],f[5]),(f,r)
 assert len(results)==len(fixtures)
 print('PASS:',len(fixtures),'region cases: CN/non-CN, challenge, timeout, oversized, malformed, language false positives')
 # A saved response is optional; this checks the actual current page format as well.
 captured=root/'work/gemini-probe.html'
 if captured.exists():
  put(b+'/gemini.html',captured.read_text())
  put(b+'/live.uc',f"import {{ classify }} from '{b}/lib.uc'; import {{ readfile }} from 'fs'; printf('%J\\n',classify('gemini',readfile('{b}/gemini.html'),200,0));")
  print('Captured Gemini:',run('ucode '+b+'/live.uc').strip())
finally:run('rm -r '+shlex.quote(b))
