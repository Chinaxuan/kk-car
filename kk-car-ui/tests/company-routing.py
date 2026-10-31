#!/usr/bin/env python3
"""Safety, DNS parsing, atomic application/rollback and revision regressions."""
import importlib.util
import ipaddress
import json
import struct
import tempfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('routing', Path(__file__).resolve().parents[1] /
                                            'root/etc/kk-car/company-routing.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def config(value='portal.example.com'):
    return dict(m.validate({'enabled': True, 'dns_server': '', 'rules': [
        {'value': value, 'enabled': True, 'note': '测试'}]}), revision=1)


def invalid(value):
    try:
        config(value)
    except ValueError:
        return
    raise AssertionError('accepted unsafe target: ' + value)


for value in ['192.168.1.1', '192.168.88.0/24', '0.0.0.0/0', '192.0.0.0/8',
              '127.0.0.1', '224.1.2.3', '169.254.0.1', '999.1.2.3', '2001:db8::1',
              'example.com;reboot', 'https://example.com/a', 'example.com:443',
              'bad..example.com', '-bad.example.com', '*.com', 'x\nreboot']:
    invalid(value)
assert m.normalize('*.Example.COM.') == ('domain', 'example.com')
assert m.normalize('10.9.20.31/24') == ('ip', '10.9.20.0/24')
assert m.normalize('10.9.20.31') == ('ip', '10.9.20.31')
assert m.normalize('公司.example')[1].endswith('.example')
try:
    m.normalize('198.51.100.1', [ipaddress.IPv4Network('198.51.100.1/32')])
except ValueError:
    pass
else:
    raise AssertionError('VPN endpoint must be protected')

cfg = config()
source = ('server=/example.com/223.5.5.5\nserver=/portal.example.com/223.5.5.5\n'
          'server=/a.portal.example.com/223.5.5.5\nserver=/unrelated.example/223.5.5.5\n')
filtered = m.china_dns_filtered(cfg, source)
assert 'server=/example.com/' in filtered  # Less-specific suffix is overridden by dnsmasq.
assert '/portal.example.com/' not in filtered and '/a.portal.example.com/' not in filtered
assert '/unrelated.example/' in filtered
assert m.china_dns_filtered(dict(cfg, enabled=False), source) == source
fragment = m.nft_fragment(config('198.51.100.23'))
assert 'priority -152' in fragment and 'type route hook output' in fragment
assert fragment.index('ip daddr 192.168.0.0/16 return') < fragment.index('ip daddr @')
assert '0xff00ffff' in fragment and '0x00020000' in fragment
assert 'type filter hook postrouting priority -2' in fragment
assert 'ip daddr @kk_company_static4 counter drop' in fragment
assert 'ip daddr @kk_company_dns4 counter drop' in fragment
assert '/portal.example.com/127.0.0.1#1054' in m.dns_fragment(cfg)
assert 'rebind-domain-ok=/portal.example.com/' in m.dns_fragment(cfg)
with patch.object(m, 'run', side_effect=[
        '10000: from all fwmark 0x20000/0xff0000 lookup 300',
        'default dev ovpncar metric 10\nunreachable default metric 32767']):
    m.check_routing('ovpncar')
with patch.object(m, 'run', side_effect=['', 'default dev wgcar']):
    try:
        m.check_routing('wgcar')
    except RuntimeError:
        pass
    else:
        raise AssertionError('missing fail-closed table accepted')

query = m.query_packet('portal.example.com')
name, typ, end = m.question(query)
assert name == 'portal.example.com' and typ == 1


def response(ip=b'\xc6\x33\x64\x17'):
    return (query[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0) + query[12:] +
            b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 120, 4) + ip)


assert m.answer_addresses(response(), name) == [('198.51.100.23', 120)]
alias = b'\x04edge\x07example\x03net\0'
cname_response = (query[:2] + struct.pack('!HHHHH', 0x8180, 1, 2, 0, 0) + query[12:] +
                  b'\xc0\x0c' + struct.pack('!HHIH', 5, 1, 120, len(alias)) + alias +
                  alias + struct.pack('!HHIH', 1, 1, 120, 4) + b'\xc6\x33\x64\x17')
assert m.answer_addresses(cname_response, name) == [('198.51.100.23', 120)]
unrelated = (query[:2] + struct.pack('!HHHHH', 0x8180, 1, 1, 0, 0) + query[12:] +
             alias + struct.pack('!HHIH', 1, 1, 120, 4) + b'\xc6\x33\x64\x17')
assert m.answer_addresses(unrelated, name) == []

with tempfile.TemporaryDirectory() as directory:
    base = Path(directory)
    constants = {key: base / key for key in ['CONFIG', 'STATE', 'NFT', 'DNS', 'LOCK',
                                            'CHINA_DNS', 'CHINA_ORIGINAL']}
    with patch.multiple(m, **constants), patch.object(m, 'excluded_networks', return_value=[]):
        m.CHINA_DNS.write_text(source)
        saved = m.save(dict(cfg, revision=0))
        assert saved['revision'] == 1
        assert m.CONFIG.stat().st_mode & 0o777 == 0o600
        try:
            m.save(dict(cfg, revision=0))
        except ValueError:
            pass
        else:
            raise AssertionError('stale write accepted')
        assert json.loads(m.CONFIG.read_text())['revision'] == 1
        engine = m.Engine()
        commands = []
        with patch.object(m, 'run', side_effect=lambda args, timeout=10, text=None:
                          commands.append((args, text)) or ''):
            engine.configure(cfg, 'ovpncar')
            assert m.CHINA_ORIGINAL.read_text() == source
            assert m.CHINA_DNS.read_text() == filtered
            assert engine.applied == 1
            answer = engine.handle(query)
            assert answer[3] & 15 == 2  # No upstream, must fail closed.
            with patch.object(engine, 'upstream', return_value=response()):
                answer = engine.handle(query)
                assert answer == response()
                assert '198.51.100.23' in engine.resolved[name]['addresses']
                assert any('198.51.100.23 timeout' in (cmd[1] or '') for cmd in commands)
            engine.configure(cfg, 'wgcar')
            assert '198.51.100.23' in engine.resolved[name]['addresses']
            assert engine.device == 'wgcar'
            # Even successful DNS cannot escape before its nft addresses install.
            with patch.object(engine, 'upstream', return_value=response()), \
                    patch.object(engine, 'sync_addresses', side_effect=RuntimeError('nft unavailable')):
                assert engine.handle(query)[3] & 15 == 2
            engine.configure(dict(cfg, enabled=False, revision=2), 'wgcar')
            assert m.CHINA_DNS.read_text() == source
            assert not engine.resolved
            assert not m.dns_fragment(engine.config).count('server=')
        original_nft = m.NFT.read_text()
        failed_once = [False]

        def fail_apply(args, timeout=10, text=None):
            if args == ['/etc/init.d/dnsmasq', 'restart'] and not failed_once[0]:
                failed_once[0] = True
                raise RuntimeError('reload rejected')
            return ''

        with patch.object(m, 'run', side_effect=fail_apply):
            try:
                engine.configure(dict(cfg, revision=3), 'wgcar')
            except RuntimeError:
                pass
            else:
                raise AssertionError('failed apply accepted')
        assert m.NFT.read_text() == original_nft
        assert m.CHINA_DNS.read_text() == source
        assert engine.applied == 2
        engine.pool.shutdown(wait=False)
print('company routing: validation, DNS/CNAME, no-leak failure, persistence and rollback OK')
