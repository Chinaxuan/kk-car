#!/usr/bin/python3
"""Authenticated company allow-list, isolated nft rules and VPN-bound DNS proxy.

Uses only Python's standard library; the installed dnsmasq need not support
nftset. Never restart netifd, Wi-Fi, PBR or a VPN to edit this list.
"""
import contextlib
import concurrent.futures
import copy
import fcntl
import ipaddress
import json
import os
import re
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

CONFIG = Path('/etc/kk-car/company-routing.json')
STATE = Path('/tmp/kk-car-company-routing.json')
NFT = Path('/etc/nftables.d/25-kk-car-company.nft')
DNS = Path('/etc/dnsmasq.d/kk-car-company.conf')
CHINA_DNS = Path('/etc/dnsmasq.d/china-direct.conf')
CHINA_ORIGINAL = Path('/etc/kk-car/private/company-routing-china-original.conf')
LOCK = Path('/var/lock/kk-car-company-config.lock')
PORT = 1054
DEVICES = ('ovpncar', 'wgcar')
SETS = ('kk_company_static4', 'kk_company_dns4')
CHAINS = ('kk_company_pre', 'kk_company_out')
LOCAL = ipaddress.IPv4Network('192.168.0.0/16')
RESERVED = [ipaddress.IPv4Network(n) for n in
            ('0.0.0.0/8', '127.0.0.0/8', '169.254.0.0/16', '224.0.0.0/3')]


def run(args, timeout=10, text=None):
    p = subprocess.run(args, input=text, capture_output=True, text=True,
                       timeout=timeout, check=False)
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout or '设备命令失败')[-600:])
    return p.stdout.strip()


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.new')
    with tmp.open('w') as file:
        os.chmod(tmp, 0o600)
        file.write(value)
        file.flush()
        os.fsync(file.fileno())
    os.replace(tmp, path)


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def defaults():
    return {'revision': 0, 'enabled': True, 'dns_server': '', 'rules': []}


def safe_network(net, excluded=()):
    return not any(net.overlaps(other) for other in [LOCAL] + RESERVED + list(excluded))


def normalize(value, excluded=()):
    if not isinstance(value, str) or not value.strip() or len(value) > 253:
        raise ValueError('请输入有效的域名、IPv4 地址或网段')
    value = value.strip().lower().rstrip('.')
    if value.startswith('*.'):
        value = value[2:]
    try:
        net = ipaddress.ip_network(value, strict=False)
    except ValueError:
        net = None
    if net is not None:
        if net.version != 4:
            raise ValueError('当前系统关闭 IPv6，请填写 IPv4 地址或网段')
        if not safe_network(net, excluded):
            raise ValueError('不能覆盖本地 192.168 网段、保留地址、上级直连网段或 VPN 服务器')
        return ('ip', str(net.network_address) if net.prefixlen == 32 else str(net))
    if re.fullmatch(r'[0-9.]+', value):
        raise ValueError('IPv4 地址格式无效')
    try:
        value = value.encode('idna').decode('ascii')
    except UnicodeError:
        raise ValueError('域名格式无效')
    if (len(value) > 253 or '.' not in value or
            any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', s)
                for s in value.split('.'))):
        raise ValueError('只填写域名，不要带 http://、端口或路径')
    return 'domain', value


def validate(data, excluded=()):
    if not isinstance(data, dict) or type(data.get('enabled')) is not bool:
        raise ValueError('设置格式无效')
    dns = data.get('dns_server', '')
    if not isinstance(dns, str):
        raise ValueError('公司 DNS 格式无效')
    dns = dns.strip()
    if dns:
        try:
            addr = ipaddress.IPv4Address(dns)
            if not safe_network(ipaddress.IPv4Network(str(addr)), excluded):
                raise ValueError()
        except ValueError:
            raise ValueError('公司 DNS 必须是可经 VPN 访问的 IPv4 地址，不能填写本地网关')
    rules = data.get('rules')
    if not isinstance(rules, list) or len(rules) > 128:
        raise ValueError('最多保存 128 条规则')
    result, seen = [], set()
    for row in rules:
        if not isinstance(row, dict) or type(row.get('enabled')) is not bool:
            raise ValueError('规则开关格式无效')
        kind, value = normalize(row.get('value'), excluded)
        if value in seen:
            raise ValueError('重复规则：' + value)
        seen.add(value)
        note = row.get('note', '')
        if not isinstance(note, str) or len(note) > 80 or any(ord(c) < 32 for c in note):
            raise ValueError('备注最多 80 字，不能包含控制字符')
        result.append({'value': value, 'kind': kind, 'enabled': row['enabled'], 'note': note})
    return {'enabled': data['enabled'], 'dns_server': dns, 'rules': result}


def excluded_networks():
    # Do not allow a new rule to steer an outer VPN connection into itself.
    result = []
    for key in ('network.wgcar_company.endpoint_host',):
        try:
            host = run(['uci', '-q', 'get', key], 2)
            result.append(ipaddress.IPv4Network(host + '/32'))
        except (RuntimeError, ValueError):
            pass
    for path in list(Path('/etc/openvpn').glob('*.conf')) + list(Path('/etc/openvpn').glob('*.ovpn')):
        for host in re.findall(r'^\s*remote\s+(\S+)', path.read_text(), re.M):
            try:
                result.append(ipaddress.IPv4Network(host + '/32'))
            except ValueError:
                pass
    try:
        routes = json.loads(run(['ip', '-j', '-4', 'route', 'show', 'table', 'main'], 3))
        for route in routes:
            if route.get('scope') == 'link' and route.get('dev') not in DEVICES + ('br-lan',):
                result.append(ipaddress.IPv4Network(route['dst'], strict=False))
            elif (route.get('dst') != 'default' and route.get('gateway') and
                  route.get('dev') not in DEVICES):
                net = ipaddress.IPv4Network(route['dst'])
                if net.prefixlen == 32:
                    result.append(net)
    except (ValueError, KeyError, RuntimeError):
        pass
    return result


def current_device():
    device = run(['uci', '-q', 'get', 'pbr.kk_global.interface'], 3)
    if device not in DEVICES:
        raise RuntimeError('当前公司 VPN 出口无效')
    return device


def check_routing(device):
    rules = run(['ip', '-4', 'rule', 'show'], 3)
    routes = run(['ip', '-4', 'route', 'show', 'table', '300'], 3)
    if (not re.search(r'^10000:.*fwmark 0x20000/0xff0000.*lookup 300\b', rules, re.M)
            or not re.search(r'^unreachable default\b', routes, re.M)):
        raise RuntimeError('公司 VPN 防泄漏路由尚未就绪，暂不应用白名单')
    for other in DEVICES:
        if other != device and re.search(r'^default dev ' + other + r'\b', routes, re.M):
            raise RuntimeError('公司 VPN 正在切换，等待路由同步')


def active_rules(config):
    return [r for r in config['rules'] if config['enabled'] and r['enabled']]


def nft_fragment(config):
    ips = [r['value'] for r in active_rules(config) if r['kind'] == 'ip']
    elements = '    elements = { ' + ', '.join(ips) + ' }\n' if ips else ''
    lines = ['# Generated by KK-Car; keep local administration outside the VPN.',
             'set kk_company_static4 {', '    type ipv4_addr; flags interval; auto-merge;',
             elements + '}',
             'set kk_company_dns4 { type ipv4_addr; flags timeout; timeout 1d; }']
    for chain, hook in zip(CHAINS, ('prerouting', 'output')):
        lines += ['chain ' + chain + ' {',
                  '    type ' + ('route' if hook == 'output' else 'filter') +
                  ' hook ' + hook + ' priority -152; policy accept;',
                  '    ip daddr 192.168.0.0/16 return',
                  '    ip daddr { 0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/3 } return']
        prefix = '    iifname "br-lan" ip saddr 192.168.88.0/24 ' if hook == 'prerouting' else '    '
        for name in SETS:
            lines += [prefix + 'ip daddr @' + name +
                      ' counter meta mark set (meta mark & 0xff00ffff) | 0x00020000']
        lines += ['}']
    lines += ['chain kk_company_egress {',
              '    type filter hook postrouting priority -2; policy accept;',
              '    oifname { "ovpncar", "wgcar" } return']
    for name in SETS:
        lines += ['    ip daddr @' + name + ' counter drop']
    lines += ['}']
    return '\n'.join(lines) + '\n'


def runtime_script(config):
    # add (not create) is idempotent; everything commits as one nft transaction.
    fragment = nft_fragment(config)
    lines = ['add set inet fw4 kk_company_static4 { type ipv4_addr; flags interval; auto-merge; }',
             'add set inet fw4 kk_company_dns4 { type ipv4_addr; flags timeout; timeout 1d; }',
             'flush set inet fw4 kk_company_static4']
    ips = [r['value'] for r in active_rules(config) if r['kind'] == 'ip']
    if ips:
        lines += ['add element inet fw4 kk_company_static4 { ' + ', '.join(ips) + ' }']
    for chain, hook in zip(CHAINS, ('prerouting', 'output')):
        mode = 'route' if hook == 'output' else 'filter'
        lines += [f'add chain inet fw4 {chain} {{ type {mode} hook {hook} priority -152; policy accept; }}',
                  f'flush chain inet fw4 {chain}']
        body = fragment.split('chain ' + chain + ' {\n', 1)[1].split('\n}', 1)[0].splitlines()[1:]
        lines += [f'add rule inet fw4 {chain} ' + line.strip() for line in body]
    lines += ['add chain inet fw4 kk_company_egress { type filter hook postrouting priority -2; policy accept; }',
              'flush chain inet fw4 kk_company_egress',
              'add rule inet fw4 kk_company_egress oifname { "ovpncar", "wgcar" } return']
    for name in SETS:
        lines += ['add rule inet fw4 kk_company_egress ip daddr @' + name + ' counter drop']
    return '\n'.join(lines) + '\n'


def dns_fragment(config):
    return '# Generated by KK-Car company allow-list\n' + ''.join(
        'server=/' + r['value'] + '/127.0.0.1#' + str(PORT) + '\n' +
        'rebind-domain-ok=/' + r['value'] + '/\n'
        for r in active_rules(config) if r['kind'] == 'domain')


def china_dns_filtered(config, source):
    """Remove competing suffix rules, including more-specific subdomains."""
    domains = {r['value'] for r in active_rules(config) if r['kind'] == 'domain'}
    if not domains:
        return source
    result = []
    for line in source.splitlines(keepends=True):
        if line.startswith('server=/'):
            parts = line.rstrip('\n').split('/')
            names = parts[1:-1]
            kept = [name for name in names if not any(
                name == domain or name.endswith('.' + domain) for domain in domains)]
            if names and not kept:
                continue
            if names != kept:
                line = 'server=/' + '/'.join(kept) + '/' + parts[-1] + '\n'
        result.append(line)
    return ''.join(result)


def dns_name(packet, offset, depth=0):
    if depth > 12:
        raise ValueError('DNS 压缩指针异常')
    labels, end = [], None
    while True:
        size = packet[offset]
        if size & 0xc0 == 0xc0:
            pointer = ((size & 0x3f) << 8) | packet[offset + 1]
            value, _ = dns_name(packet, pointer, depth + 1)
            labels.append(value)
            end = offset + 2
            break
        if size & 0xc0 or size > 63:
            raise ValueError('DNS 名称异常')
        offset += 1
        if size == 0:
            end = offset
            break
        labels.append(packet[offset:offset + size].decode('ascii').lower())
        offset += size
    return '.'.join(labels), end


def question(packet):
    if len(packet) < 12 or struct.unpack('!H', packet[4:6])[0] != 1:
        raise ValueError('DNS 查询格式无效')
    name, end = dns_name(packet, 12)
    qtype, qclass = struct.unpack_from('!HH', packet, end)
    if qclass != 1:
        raise ValueError('DNS 查询类别无效')
    return name, qtype, end + 4


def answer_addresses(packet, requested):
    _, _, offset = question(packet)
    count = struct.unpack('!H', packet[6:8])[0]
    records, aliases = [], {}
    for _ in range(count):
        owner, offset = dns_name(packet, offset)
        typ, cls, ttl, length = struct.unpack_from('!HHIH', packet, offset)
        offset += 10
        if offset + length > len(packet):
            raise ValueError('DNS 响应不完整')
        if typ == 5 and cls == 1:
            aliases[owner] = dns_name(packet, offset)[0]
        if typ == 1 and cls == 1 and length == 4:
            records.append((owner, socket.inet_ntoa(packet[offset:offset + 4]), ttl))
        offset += length
    names, current = {requested}, requested
    for _ in range(16):
        current = aliases.get(current)
        if not current or current in names:
            break
        names.add(current)
    return [(ip, max(60, ttl)) for owner, ip, ttl in records if owner in names]


def query_packet(name):
    return (os.urandom(2) + struct.pack('!HHHHH', 0x0100, 1, 0, 0, 0) +
            b''.join(bytes([len(s)]) + s.encode('ascii') for s in name.split('.')) +
            b'\0\0\1\0\1')


def recv_exact(sock, length):
    data = b''
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise ValueError('DNS TCP 响应中断')
        data += part
    return data


class Engine:
    def __init__(self):
        self.lock = threading.RLock()
        self.config = defaults()
        self.signature = None
        self.device = ''
        self.resolved = {}
        self.last_error = ''
        self.applied = -1
        self.retry_at = 0
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=2)
        self.warming = {}

    def upstream(self, packet, device, server, tcp=False):
        typ = socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM
        with socket.socket(socket.AF_INET, typ) as sock:
            sock.settimeout(3)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, device.encode() + b'\0')
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, 0x20000)
            sock.connect((server, 53))
            if tcp:
                sock.sendall(struct.pack('!H', len(packet)) + packet)
                response = recv_exact(sock, struct.unpack('!H', recv_exact(sock, 2))[0])
            else:
                sock.send(packet)
                response = sock.recv(65535)
        if response[:2] != packet[:2] or question(response)[:2] != question(packet)[:2]:
            raise ValueError('DNS 响应不匹配')
        if not response[2] & 0x80:
            raise ValueError('DNS 响应无效')
        if not tcp and response[2] & 2:
            return self.upstream(packet, device, server, tcp=True)
        return response

    def sync_addresses(self):
        now = time.time()
        values = {}
        for row in self.resolved.values():
            for ip, expiry in list(row['addresses'].items()):
                if expiry <= now:
                    del row['addresses'][ip]
                else:
                    values[ip] = max(values.get(ip, 0), expiry)
        if len(values) > 4096:
            raise RuntimeError('域名地址数量超出限制，请缩小白名单范围')
        script = 'flush set inet fw4 kk_company_dns4\n'
        if values:
            script += 'add element inet fw4 kk_company_dns4 { ' + ', '.join(
                ip + ' timeout ' + str(max(1, int(expiry - now))) + 's'
                for ip, expiry in values.items()) + ' }\n'
        run(['nft', '-f', '-'], 5, script)

    def handle(self, packet, tcp=False):
        try:
            name, _, end = question(packet)
            with self.lock:
                matched = [r for r in active_rules(self.config) if r['kind'] == 'domain' and
                           (name == r['value'] or name.endswith('.' + r['value']))]
                if not matched or self.applied != self.config['revision']:
                    raise ValueError('域名未启用或规则尚未生效')
                device, dns, revision = self.device, self.config['dns_server'], self.applied
            error = None
            for server in ([dns] if dns else ['1.1.1.1', '1.0.0.1']):
                try:
                    response = self.upstream(packet, device, server, tcp)
                    if response[3] & 15 == 2:
                        raise ValueError('上游 DNS 暂不可用')
                    break
                except (OSError, ValueError) as exc:
                    error = exc
            else:
                raise RuntimeError('公司 VPN DNS 查询失败：' + str(error))
            addresses = answer_addresses(response, name) if not response[3] & 15 else []
            excluded = excluded_networks()
            with self.lock:
                if revision != self.applied or device != self.device:
                    raise RuntimeError('VPN 正在切换，请重新查询')
                for row in matched:
                    entry = self.resolved.setdefault(row['value'], {'addresses': {}, 'updated': 0})
                    entry['updated'] = time.time()
                    entry['error'] = ''
                    for ip, ttl in addresses:
                        if safe_network(ipaddress.IPv4Network(ip), excluded):
                            entry['addresses'][ip] = time.time() + ttl
                # Route addresses BEFORE giving a successful DNS answer to clients.
                if addresses:
                    self.sync_addresses()
            return response
        except Exception as exc:
            with self.lock:
                if 'matched' in locals():
                    for row in matched:
                        entry = self.resolved.setdefault(row['value'], {'addresses': {}, 'updated': 0})
                        entry['error'] = str(exc)[:180]
            try:
                _, _, end = question(packet)
                return packet[:2] + b'\x81\x82' + b'\0\1\0\0\0\0\0\0' + packet[12:end]
            except (ValueError, IndexError, struct.error):
                return b''

    def configure(self, config, device):
        fragment, dns = nft_fragment(config), dns_fragment(config)
        previous = {path: path.read_text() if path.exists() else None for path in (NFT, DNS, CHINA_DNS)}
        source = CHINA_ORIGINAL.read_text() if CHINA_ORIGINAL.exists() else previous[CHINA_DNS]
        filtered = china_dns_filtered(config, source) if source is not None else None
        script = runtime_script(config)
        run(['nft', '-c', '-f', '-'], 5, script)
        # Syntax-check only our generated DNS fragment, leaving DHCP untouched.
        check = Path('/tmp/kk-car-company-dns-check.conf')
        atomic(check, dns)
        run(['dnsmasq', '--test', '--conf-file=' + str(check)], 5)
        check.unlink(missing_ok=True)
        old_config, old_device = self.config, self.device
        old_resolved, old_warming = copy.deepcopy(self.resolved), self.warming.copy()
        try:
            run(['nft', '-f', '-'], 5, script)
            atomic(NFT, fragment)
            changed_dns = previous[DNS] != dns and (previous[DNS] is not None or 'server=' in dns)
            if filtered is not None and previous[CHINA_DNS] != filtered:
                if not CHINA_ORIGINAL.exists():
                    atomic(CHINA_ORIGINAL, source)
                atomic(CHINA_DNS, filtered)
                changed_dns = True
            if changed_dns:
                atomic(DNS, dns)
                # SIGHUP does not reread conf-dir server= rules. A scoped DNS
                # restart is required; leases persist, netifd/Wi-Fi/VPN stay up.
                run(['/etc/init.d/dnsmasq', 'restart'], 20)
            self.config, self.device = config, device
            enabled = {r['value'] for r in active_rules(config) if r['kind'] == 'domain'}
            self.resolved = {key: value for key, value in self.resolved.items() if key in enabled}
            if device != old_device:
                # Keep still-cached addresses routed through table 300 while
                # refreshing DNS over the new tunnel; never expose them to WAN.
                self.warming = {}
            self.sync_addresses()
            self.applied = config['revision']
            self.last_error = ''
        except Exception:
            self.config, self.device = old_config, old_device
            self.resolved, self.warming = old_resolved, old_warming
            for path, value in previous.items():
                if value is None:
                    path.unlink(missing_ok=True)
                else:
                    atomic(path, value)
            with contextlib.suppress(Exception):
                run(['nft', '-f', '-'], 5, runtime_script(old_config))
                self.sync_addresses()
                run(['/etc/init.d/dnsmasq', 'restart'], 20)
            raise

    def tick(self):
        try:
            raw = read_json(CONFIG, defaults())
            config = dict(validate(raw, excluded_networks()), revision=raw['revision'])
            device = current_device()
            check_routing(device)
            signature = json.dumps(config, sort_keys=True) + device
            with self.lock:
                if signature != self.signature and time.time() >= self.retry_at:
                    self.configure(config, device)
                    self.signature = signature
                # A firewall reload empties the runtime-only DNS address set.
                if self.applied >= 0:
                    self.sync_addresses()
                self.publish()
                for row in active_rules(self.config):
                    name = row['value']
                    if row['kind'] == 'domain' and time.time() - self.warming.get(name, 0) > 300:
                        self.warming[name] = time.time()
                        self.pool.submit(self.handle, query_packet(name))
        except Exception as exc:
            with self.lock:
                self.last_error = str(exc)[:300]
                self.retry_at = time.time() + 30
                self.publish()

    def publish(self):
        now = time.time()
        resolved = {key: dict(value, addresses=sorted(ip for ip, expiry in value['addresses'].items()
                                                     if expiry > now))
                    for key, value in self.resolved.items()}
        # Runtime only: never store DNS history or private rules in the repository.
        atomic(STATE, json.dumps({'timestamp': now, 'applied_revision': self.applied,
                                 'device': self.device, 'error': self.last_error,
                                 'resolved': resolved}, ensure_ascii=False))


class UDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        response = self.server.engine.handle(packet)
        if response:
            sock.sendto(response, self.client_address)


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(10)
            packet = recv_exact(self.request, struct.unpack('!H', recv_exact(self.request, 2))[0])
            response = self.server.engine.handle(packet, tcp=True)
            if response:
                self.request.sendall(struct.pack('!H', len(response)) + response)
        except (OSError, ValueError, struct.error):
            pass


def status():
    config = read_json(CONFIG, defaults())
    state = read_json(STATE, {})
    fresh = time.time() - state.get('timestamp', 0) < 20
    return {'ok': True, 'config': config, 'runtime': state, 'running': fresh,
            'applied': fresh and not state.get('error') and
            state.get('applied_revision') == config['revision']}


def save(data):
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open('w') as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        old = read_json(CONFIG, defaults())
        if type(data.get('revision')) is not int or data['revision'] != old['revision']:
            raise ValueError('设置已被其他页面修改，请重新读取后再保存')
        config = validate(data, excluded_networks())
        config['revision'] = old['revision'] + 1
        atomic(CONFIG, json.dumps(config, ensure_ascii=False, indent=2) + '\n')
    return {'ok': True, 'revision': config['revision'], 'pending': True}


def serve():
    with Path('/var/lock/kk-car-company-worker.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        engine = Engine()
        servers = [UDPServer(('127.0.0.1', PORT), UDPHandler),
                   TCPServer(('127.0.0.1', PORT), TCPHandler)]
        for server in servers:
            server.engine = engine
            threading.Thread(target=server.serve_forever, daemon=True).start()
        while True:
            engine.tick()
            time.sleep(5)


if __name__ == '__main__':
    try:
        mode = sys.argv[1] if len(sys.argv) > 1 else 'status'
        if mode == 'serve':
            serve()
        elif mode == 'status':
            print(json.dumps(status(), ensure_ascii=False))
        elif mode == 'save':
            print(json.dumps(save(json.loads(sys.argv[2])), ensure_ascii=False))
        else:
            raise ValueError('未知操作')
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': str(exc)[:300]}, ensure_ascii=False))
        sys.exit(1)
