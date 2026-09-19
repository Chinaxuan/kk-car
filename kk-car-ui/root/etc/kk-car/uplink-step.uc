'use strict';
import { readfile, writefile, rename, popen, access } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';
import { ipv4, cidr, subnet, overlap, decide } from '/etc/kk-car/uplink-policy.uc';
function run(command) { let p=popen(command+' 2>/dev/null'); if (!p) return ''; let s=p.read('all'); p.close(); return trim(s || ''); }
function command(s) { return system(s+' >/dev/null 2>&1') == 0; }
function address(bus, name, device) {
    let s = bus.call('network.interface.'+name, 'status') || {}, a=s['ipv4-address']?.[0] || {};
    let ip=ipv4(a.address) != null ? a.address : '', mask=+a.mask, gateway='';
    for (let r in s.route || []) if (r.target=='0.0.0.0' && r.mask==0 && ipv4(r.nexthop)!=null) gateway=r.nexthop;
    return {up:!!s.up && !!ip, ip, mask, gateway, device, uptime:s.uptime || 0};
}
let c=cursor(), bus=connect();
let mode=c.get('network','kk_ethwan','auto')=='1' ? 'wan' : 'lan';
let cell=address(bus,'wan','eth1'), wire=address(bus,'kk_ethwan','eth0'), lan=address(bus,'lan','br-lan');
let prev={}; try { prev=json(readfile('/tmp/kk-car-uplink.json') || '{}'); } catch(e) {}
let carrier=trim(readfile('/sys/class/net/eth0/carrier') || '')=='1';
let pre=decide(mode,wire,cell,lan,prev,false,carrier), probe=false;
if (mode=='wan' && carrier && wire.up && wire.gateway && !pre.conflict) {
    // DHCP supplies a low-priority wired default solely to allow device-bound probes.
    probe=command('ping -4 -I eth0 -c 1 -W 1 -w 2 223.5.5.5') || command('ping -4 -I eth0 -c 1 -W 1 -w 2 119.29.29.29');
}
let next=decide(mode,wire,cell,lan,prev,probe,carrier);
let selected=next.active=='ethernet' ? wire : next.active=='cellular' ? cell : null;
let ok=command('ip -4 route replace unreachable default table 301 metric 32767');
let rules=run('ip -4 rule show');
if (!match(rules,/9990:.*fwmark 0x10000\/0xff0000.*lookup 301/))
    ok=command('ip -4 rule add priority 9990 fwmark 0x10000/0xff0000 lookup 301') && ok;
let count=0; for (let line in split(rules,'\n')) if (match(line,/^9990:.*fwmark 0x10000\/0xff0000.*lookup 301/)) count++;
while (count>1) { if (!command('ip -4 rule del priority 9990 fwmark 0x10000/0xff0000 lookup 301')) break; count--; }
let routes=run('ip -4 route show table 301'), links=[];
for (let item in [lan,cell,wire]) {
    if (!item.up || (item.device=='eth0' && (mode!='wan' || next.conflict))) continue;
    let network=cidr(item.ip,item.mask); if (!network) continue;
    let prefix=network+' dev '+item.device;
    push(links,{network,device:item.device});
    if (index(routes,prefix)<0 || index(routes,'src '+item.ip)<0)
        ok=command('ip -4 route replace '+prefix+' src '+item.ip+' table 301') && ok;
}
if (selected) {
    let wanted='default via '+selected.gateway+' dev '+selected.device;
    if (index(routes,wanted)<0)
        ok=command('ip -4 route replace '+wanted+' table 301 metric 10') && ok;
} else if (match(routes, /(^|\n)default /)) command('ip -4 route del default table 301 metric 10');
// Remove obsolete connected routes, retaining the unreachable default throughout.
for (let line in split(routes,'\n')) {
    let m=match(line,/^([0-9.]+\/\d+) dev (eth0|eth1|br-lan) /);
    if (!m) continue;
    let keep=false; for (let link in links) if (link.network==m[1] && link.device==m[2]) keep=true;
    if (!keep) command('ip -4 route del '+m[1]+' dev '+m[2]+' table 301');
}
let main=run('ip -4 route show default dev eth0');
if (next.active=='ethernet' && ok) {
    if (index(main,'via '+wire.gateway+' dev eth0 metric 5')<0)
        ok=command('ip -4 route replace default via '+wire.gateway+' dev eth0 metric 5') && ok;
} else if (match(main,/metric 5(\s|$)/)) command('ip -4 route del default dev eth0 metric 5');
// netifd retains a cellular host route for the saved WireGuard endpoint.
// Keep IKE source-address selection on the selected uplink too, before restarting it.
let endpoint=run('ip -4 route show 203.0.113.10/32');
if (selected && ok) {
    let wanted='203.0.113.10 via '+selected.gateway+' dev '+selected.device+' metric 5';
    if (index(endpoint,wanted)<0)
        ok=command('ip -4 route replace 203.0.113.10/32 via '+selected.gateway+' dev '+selected.device+' metric 5') && ok;
} else if (match(endpoint,/metric 5(\s|$)/)) command('ip -4 route del 203.0.113.10/32 metric 5');
next.timestamp=time(); next.carrier=carrier; next.wire=wire; next.cell=cell;
next.device=selected?.device || ''; next.ready=ok;
next.changed=prev.active && prev.active!=next.active ? time() : prev.changed || time();
writefile('/tmp/kk-car-uplink.json.new',sprintf('%J',next));
rename('/tmp/kk-car-uplink.json.new','/tmp/kk-car-uplink.json');
if (ok && prev.active && prev.active!=next.active) {
    command('logger -t kk-car-uplink "Selected '+next.active+' uplink"');
    // Rebuild the VPN only if it was running; a user's paused VPN stays paused.
    if (access('/var/run/charon.pid') && next.active!='none') {
        command('/usr/sbin/swanctl --terminate --ike kk-car --force --timeout 2');
        command('/usr/sbin/swanctl --initiate --child kk-car-internet --timeout 2');
    }
}
