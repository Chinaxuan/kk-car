#!/usr/bin/python3
"""Keep both tunnels available and select the lower-latency healthy tunnel.

Only the two known VPN devices are eligible.  The physical uplink and the
country-direct rules are never changed here.  PBR's strict enforcement and
table 300's unreachable fallback remain in place during a switch.
"""
import concurrent.futures
import fcntl
import json
import os
import re
import statistics
import subprocess
import time
from pathlib import Path

DEVICES = ('ovpncar', 'wgcar')
TARGET = '10.8.8.8'
STATE = Path('/tmp/kk-car-vpn-select.json')
PAUSED = Path('/tmp/kk-car-vpn-paused')
UPLINK = Path('/tmp/kk-car-uplink.json')
INTERVAL = 300
MIN_DWELL = 600


def run(args, timeout=12):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                           check=False)
        return p.returncode, p.stdout + p.stderr
    except (OSError, subprocess.TimeoutExpired):
        return -1, ''


def uci_get(path):
    return run(['uci', '-q', 'get', path], 3)[1].strip()


def selected():
    value = uci_get('pbr.kk_global.interface')
    return value if value in DEVICES else 'ovpncar'


def interface_up(device):
    code, output = run(['ip', '-o', '-4', 'addr', 'show', 'dev', device], 3)
    return code == 0 and bool(re.search(r'\binet\s+[0-9.]+/', output))


def probe(device):
    if device not in DEVICES or not interface_up(device):
        return {'healthy': False, 'median_ms': None, 'loss_percent': 100, 'received': 0}
    _, output = run(['ping', '-4', '-n', '-I', device, '-c', '5', '-W', '2', '-w', '8', TARGET], 10)
    rtts = [float(x) for x in re.findall(r'\btime[=<]([0-9]+(?:\.[0-9]+)?)\s*ms', output)]
    received = len(rtts)
    loss = (5 - received) * 20
    median = round(statistics.median(rtts), 2) if rtts else None
    return {'healthy': received >= 4, 'median_ms': median,
            'loss_percent': loss, 'received': received,
            'score_ms': round(median + (5 - received) * 30, 2) if median is not None else None}


def choice(current, results, streak, since_switch, recovery):
    other = 'wgcar' if current == 'ovpncar' else 'ovpncar'
    primary, challenger = results[current], results[other]
    if not challenger['healthy']:
        return current, 0, 'challenger_unhealthy'
    if not primary['healthy']:
        return other, 0, 'active_unhealthy'
    improvement = primary['score_ms'] - challenger['score_ms']
    margin = max(10, primary['score_ms'] * 0.15)
    if improvement < margin:
        return current, 0, 'difference_small'
    if not recovery and since_switch < MIN_DWELL:
        return current, 0, 'minimum_dwell'
    streak += 1
    if recovery or streak >= 2:
        return other, 0, 'lower_latency'
    return current, streak, 'await_second_sample'


def dns_servers(device):
    return [f'1.1.1.1@{device}', f'1.0.0.1@{device}']


def write_dns(servers):
    run(['uci', '-q', 'delete', 'dhcp.@dnsmasq[0].server'], 3)
    for server in servers:
        if run(['uci', 'add_list', f'dhcp.@dnsmasq[0].server={server}'], 3)[0] != 0:
            raise RuntimeError('cannot set DNS server')
    if run(['uci', 'commit', 'dhcp'], 5)[0] != 0:
        raise RuntimeError('cannot commit DNS')
    if run(['/etc/init.d/dnsmasq', 'reload'], 25)[0] != 0:
        raise RuntimeError('cannot reload DNS')


def write_pbr(device):
    for policy in ('kk_global', 'kk_dns'):
        if run(['uci', 'set', f'pbr.{policy}.interface={device}'], 3)[0] != 0:
            raise RuntimeError('cannot set PBR policy')
    if run(['uci', 'commit', 'pbr'], 5)[0] != 0:
        raise RuntimeError('cannot commit PBR')
    if run(['/etc/init.d/pbr', 'restart'], 35)[0] != 0:
        raise RuntimeError('cannot restart PBR')
    if run(['/etc/kk-car/ike-route-ensure.sh'], 10)[0] != 0:
        raise RuntimeError('cannot apply VPN route')


def switched_route(device):
    # PBR allocates mark values dynamically when interfaces are added.  Check
    # the stable project mark and PBR's current mark, never a hard-coded PBR ID.
    _, rules = run(['ip', '-4', 'rule', 'show'], 4)
    policy = re.search(r'fwmark (0x[0-9a-f]+)/0x[0-9a-f]+ lookup pbr_' + device + r'\b', rules)
    if not policy:
        return False
    for mark in ('0x20000', policy.group(1)):
        code, route = run(['ip', '-4', 'route', 'get', TARGET, 'from', '192.168.88.123',
                           'iif', 'br-lan', 'mark', mark], 4)
        if code != 0 or f'dev {device}' not in route:
            return False
    return True


def switch(device):
    old = selected()
    if device == old:
        return True
    if device not in DEVICES or not interface_up(device):
        return False
    original_dns = uci_get('dhcp.@dnsmasq[0].server').split()
    try:
        write_pbr(device)
        if not switched_route(device):
            raise RuntimeError('new route is not selected')
        # Keep unrelated DNS rules; replace only this project's two global DNS servers.
        preserved = [s for s in original_dns if s not in dns_servers(old) + dns_servers(device)]
        write_dns(preserved + dns_servers(device))
        if not probe(device)['healthy']:
            raise RuntimeError('new tunnel failed after switching')
        return True
    except Exception:
        try:
            write_pbr(old)
            write_dns(original_dns)
        except Exception:
            pass  # The watchdog and the next loop will inspect and retry.
        return False


def publish(data):
    tmp = STATE.with_suffix('.json.new')
    tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':')))
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE)


def read_uplink():
    try:
        return json.loads(UPLINK.read_text())
    except (OSError, ValueError):
        return {}


def main():
    with open('/var/lock/kk-car-vpn-select.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        last_check = 0.0
        last_switch = 0.0
        seen_uplink = None
        streak = 0
        while True:
            now = time.monotonic()
            link = read_uplink()
            active = selected()
            identity = (link.get('active'), link.get('applied_identity'))
            recovery = identity != seen_uplink and identity[0] in ('ethernet', 'cellular')
            if identity != seen_uplink:
                seen_uplink = identity
                last_check = 0.0
                streak = 0
            if PAUSED.exists() or identity[0] not in ('ethernet', 'cellular') or not link.get('ready'):
                publish({'timestamp': time.time(), 'selected': active, 'state': 'paused' if PAUSED.exists() else 'uplink_offline'})
                time.sleep(5)
                continue
            if last_check and now - last_check < INTERVAL:
                time.sleep(5)
                continue
            if not interface_up('wgcar'):
                run(['/sbin/ifup', 'wgcar'], 12)
                time.sleep(5)
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                jobs = {dev: pool.submit(probe, dev) for dev in DEVICES}
                results = {dev: job.result() for dev, job in jobs.items()}
            chosen, streak, reason = choice(active, results, streak, now - last_switch, recovery)
            if chosen != active:
                if switch(chosen):
                    active = chosen
                    last_switch = time.monotonic()
                else:
                    reason = 'switch_rolled_back'
                    streak = 0
            last_check = time.monotonic()
            publish({'timestamp': time.time(), 'selected': active, 'state': reason,
                     'interval_seconds': INTERVAL, 'next_check': time.time() + INTERVAL,
                     'last_switch_uptime': last_switch, 'uplink': identity[0],
                     'results': results})
            time.sleep(5)


if __name__ == '__main__':
    main()
