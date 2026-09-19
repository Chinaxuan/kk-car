import { readfile } from 'fs';
import { classify } from '/etc/kk-car/ai-region.uc';
let dir=ARGV[0];
let result=json(readfile(dir+'/base.json'));
for(let name in ['chatgpt','gemini']) {
    let code=+(trim(readfile(dir+'/'+name+'.code') || '0'));
    let rc=+(trim(readfile(dir+'/'+name+'.rc') || '99'));
    result[name]=classify(name,readfile(dir+'/'+name+'.body') || '',code,rc);
}
printf('%J\n',result);
