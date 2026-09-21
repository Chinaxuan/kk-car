'use strict';
// Opt-in installer. Apply with fw4 check/reload after backing up firewall UCI.
import { cursor } from 'uci';
let c = cursor();
if (length(c.changes('firewall') || {})) die('Unapplied firewall changes; stopped\n');
if (c.get('network','ikecar','proto') != 'xfrm' ||
    c.get('firewall','ikecar','name') != 'ikecar' ||
    c.get('network','kk_ike_route','table') != '300')
    die('Expected KK-Car XFRM topology is missing\n');
for (let name in ['kk_vpn_admin','kk_vpn_admin_ping']) {
    if (c.get('firewall',name) && c.get('firewall',name) != 'rule')
        die('Conflicting firewall section: '+name+'\n');
    c.set('firewall',name,'rule');
    for (let key,value in {src:'ikecar',target:'ACCEPT',family:'ipv4',enabled:'1'})
        c.set('firewall',name,key,value);
}
c.set('firewall','kk_vpn_admin','name','KK-Car VPN management');
c.set('firewall','kk_vpn_admin','proto','tcp');
c.set('firewall','kk_vpn_admin','dest_port','22 80 443');
c.set('firewall','kk_vpn_admin_ping','name','KK-Car VPN management ping');
c.set('firewall','kk_vpn_admin_ping','proto','icmp');
c.set('firewall','kk_vpn_admin_ping','icmp_type','echo-request');
if (!c.commit('firewall')) die('Firewall commit failed\n');
print('VPN-zone management rules saved; validate and reload firewall next\n');
