#!/usr/bin/env python3
"""Decision tests; no device or credentials required."""
import importlib.util
from pathlib import Path

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
print('vpn selector decisions: OK')
