'use strict';
// Run once during installation, then reload network/firewall/PBR and start the watcher.
import { cursor } from 'uci';
let c=cursor(), bridge=null, zone=null;
for (let config in ['network','firewall','pbr'])
    if (length(c.changes(config) || {})) die('Unapplied changes in '+config+'; installation stopped\n');
c.foreach('network','device',function(s){if(s.name=='br-lan' && s.type=='bridge') bridge=s['.name'];});
c.foreach('firewall','zone',function(s){if(s.name=='wan') zone=s['.name'];});
if (!bridge || !zone || c.get('network','wan','device')!='eth1') die('Unexpected network layout\n');
if (!c.get('network','kk_ethwan')) {
    c.set('network','kk_ethwan','interface');
    for (let k,v in {proto:'dhcp',device:'eth0',auto:'0',ipv6:'0',delegate:'0',peerdns:'0',metric:'500',defaultroute:'1'}) c.set('network','kk_ethwan',k,v);
}
c.set('network',bridge,'bridge_empty','1');
c.set('network','wan','metric','20');
c.set('network','kk_uplink_rule','rule');
for (let k,v in {mark:'0x10000/0xff0000',lookup:'301',priority:'9990'}) c.set('network','kk_uplink_rule',k,v);
c.set('network','kk_uplink_block','route');
for (let k,v in {interface:'loopback',target:'0.0.0.0/0',type:'unreachable',table:'301',metric:'32767'}) c.set('network','kk_uplink_block',k,v);
function add(config,section,key,value) {
    let list=c.get(config,section,key) || [];
    if (type(list)=='string') list=[list];
    if (index(list,value)<0) push(list,value);
    c.set(config,section,key,list);
}
add('firewall',zone,'network','kk_ethwan');
add('pbr','config','ignored_interface','kk_ethwan');
for (let config in ['network','firewall','pbr']) if (!c.commit(config)) die('Failed to commit '+config+'\n');
print('Ethernet WAN configuration installed; current port role preserved\n');
