#!/usr/bin/env python3
"""Decision tests; no device or credentials required."""
import importlib.util
from pathlib import Path
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / 'root/etc/kk-car/vpn-select.py'
spec = importlib.util.spec_from_file_location('vpn_select', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def data(ovpn, wg, loss_ovpn=0, loss_wg=0):
    return {'ovpncar': {'healthy': loss_ovpn <= 20, 'score_ms': ovpn + loss_ovpn * 1.5},
            'wgcar': {'healthy': loss_wg <= 20, 'score_ms': wg + loss_wg * 1.5}}


assert module.choice('ovpncar', data(120, 70), 0, 999, False)[:2] == ('ovpncar', 1)
assert module.choice('ovpncar', data(120, 70), 1, 999, False)[0] == 'wgcar'
assert module.choice('ovpncar', data(120, 70), 0, 999, True)[0] == 'wgcar'
assert module.choice('ovpncar', data(120, 70), 0, 5, False)[0] == 'ovpncar'
assert module.choice('wgcar', data(75, 70), 1, 999, False)[0] == 'wgcar'
assert module.choice('wgcar', data(75, 70, loss_wg=100), 0, 1, False)[0] == 'ovpncar'

# Regression: a company-only ping must not make a broken foreign exit eligible.
good_dns = '{"Status":0,"Answer":[{"type":1,"data":"142.251.153.119"}]}'
assert module.dns_addresses(good_dns) == ['142.251.153.119']
assert module.dns_addresses('{"Status":0,"Answer":[{"type":1,"data":"192.168.1.2"}]}') == []


def incident_run(args, timeout=12):
    if args[0] == 'ping':
        return 0, '64 bytes time=50.0 ms\n' * 5
    if 'dns-query' in ' '.join(args):
        return (0, good_dns) if 'ovpncar' in args else (28, '')
    return 0, '200'


with patch.object(module, 'interface_up', return_value=True), patch.object(module, 'run', side_effect=incident_run):
    openvpn = module.probe('ovpncar')
    wireguard = module.probe('wgcar')
assert openvpn['healthy'] and openvpn['internet_ok']
assert not wireguard['healthy'] and wireguard['internet_reason'] == 'encrypted_dns_failed'
assert module.choice('wgcar', {'ovpncar': openvpn, 'wgcar': wireguard}, 0, 0, False)[0] == 'ovpncar'
print('vpn selector decisions: OK')
