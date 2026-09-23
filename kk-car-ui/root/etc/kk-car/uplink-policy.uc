'use strict';
function ipv4(value) {
    if (type(value) != 'string' || !match(value, /^\d+\.\d+\.\d+\.\d+$/)) return null;
    let parts = split(value, '.'), n = 0;
    for (let p in parts) { if (+p > 255) return null; n = n * 256 + (+p); }
    return n;
}
function subnet(address, mask) {
    let n = ipv4(address);
    if (n == null || mask < 0 || mask > 32 || int(mask) != mask) return null;
    let size = 2 ** (32 - mask), base = int(n / size) * size;
    return {start:base, end:base+size-1, mask};
}
function overlap(a, b) {
    return a && b && a.start <= b.end && b.start <= a.end;
}
function cidr(address, mask) {
    let s = subnet(address, mask);
    if (!s) return null;
    let n = s.start, parts = [];
    for (let shift in [24,16,8,0]) { let d = 2 ** shift; push(parts, int(n/d)); n %= d; }
    return join('.', parts) + '/' + mask;
}
function decide(mode, wire, cell, lan, previous, probe, carrier) {
    let wn = subnet(wire.ip, wire.mask), cn = subnet(cell.ip, cell.mask), ln = subnet(lan.ip, lan.mask);
    let conflict = !!(wn && (overlap(wn, cn) || overlap(wn, ln) || overlap(wn, subnet('192.168.0.0',24))));
    let eligible = mode == 'wan' && carrier && wire.up && wn && wire.gateway && !conflict;
    let identity = (wire.ip || '') + '/' + (wire.mask || '') + '/' + (wire.gateway || '');
    let same = previous.identity == identity && previous.mode == mode;
    let good = eligible && probe ? min(3, (same ? previous.good || 0 : 0)+1) : 0;
    let bad = eligible && !probe ? min(2, (same ? previous.bad || 0 : 0)+1) : 0;
    let healthy = !!(eligible && (good >= 3 || (same && previous.healthy && bad < 2)));
    let active = healthy ? 'ethernet' : cell.up && (cell.gateway || cell.default_route) ? 'cellular' : 'none';
    let reason = mode != 'wan' ? 'lan' : !carrier ? 'no_cable' : conflict ? 'subnet_conflict' : !wire.up || !wire.gateway ? 'dhcp_wait' : healthy ? 'preferred' : probe ? 'checking' : 'probe_failed';
    return {mode, identity, good, bad, healthy, active, reason, conflict};
}

export { ipv4, subnet, overlap, cidr, decide };
