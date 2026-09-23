'use strict';
import { ipv4, subnet, cidr } from '/etc/kk-car/uplink-policy.uc';

// Only interface names expected from the supported USB network drivers may
// enter route commands. Logical netifd names and control-device paths cannot.
function wan_device(value) {
    return type(value)=='string' && length(value)<=15 && match(value,/^(eth|wwan|usb)[0-9]+$/) ? value : '';
}
function address(status, fallback) {
    let s=status || {}, device=wan_device(s.l3_device) || wan_device(s.device) || fallback || '';
    let ip='', mask=0, gateway='', default_route=false;
    for (let a in s['ipv4-address'] || []) {
        if (ipv4(a.address)!=null && a.mask!=null && subnet(a.address,+a.mask)) { ip=a.address; mask=+a.mask; break; }
    }
    for (let route in s.route || []) {
        if (route.target!='0.0.0.0' || route.mask==null || +route.mask!=0 || (route.table && +route.table!=254)) continue;
        if (route.nexthop && route.nexthop!='0.0.0.0' && ipv4(route.nexthop)==null) continue;
        default_route=true;
        gateway=route.nexthop && route.nexthop!='0.0.0.0' ? route.nexthop : '';
        break;
    }
    return {up:!!s.up && !!ip && !!device,ip,mask,gateway,default_route,device,uptime:s.uptime || 0};
}
function cellular(parent, interfaces) {
    let cell=address(parent), candidates=[cell];
    // QMI's DHCP mode may put the IPv4 lease on netifd's dynamic wan_4
    // child. Never adopt an unrelated interface merely because it uses USB.
    for (let status in interfaces || []) {
        if (!status.dynamic || !match(status.interface || '',/^wan_[0-9]+$/)) continue;
        let child=address(status);
        if (!child.device || (cell.device && child.device!=cell.device)) continue;
        push(candidates,child);
    }
    for (let candidate in candidates) if (candidate.up && candidate.default_route) return candidate;
    for (let candidate in candidates) if (candidate.up) return candidate;
    return cell;
}
function read_cellular(bus) {
    let parent=bus.call('network.interface.wan','status') || {};
    let dump=bus.call('network.interface','dump') || {};
    return cellular(parent,dump.interface);
}
function route_path(link) { return (link.gateway ? 'via '+link.gateway+' ' : '')+'dev '+link.device; }
function route_options(link) {
    // Raw-IP modems can expose /32 addresses with an off-subnet gateway.
    return link.gateway && cidr(link.ip,link.mask)!=cidr(link.gateway,link.mask) ? ' onlink' : '';
}
function selected_identity(active, link) {
    return link ? active+'/'+link.device+'/'+link.ip+'/'+link.mask+'/'+link.gateway : 'none';
}
export { wan_device, address, cellular, read_cellular, route_path, route_options, selected_identity };
