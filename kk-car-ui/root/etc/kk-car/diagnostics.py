#!/usr/bin/python3
"""Bounded private fault recorder. Raw logs and identifiers never reach disk."""
import fcntl
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

DIRECTORY = Path('/etc/kk-car/private/diagnostics')
LIMIT = 2 * 1024 * 1024
FILES = 8  # active + seven rotations, at most 16 MiB
CACHE = Path('/tmp/kk-car-diagnostics.json')
COUNTS = Path('/tmp/kk-car-diagnostics-counts.json')
BOOT = Path('/proc/sys/kernel/random/boot_id')
ERRORS = {
    'qmi_timeout': r'netifd: wan \(.*(?:Request timed out|Failed to connect to service)',
    'qmi_parse': r'netifd: wan \(.*Failed to parse message',
    'sim_reset': r'netifd: wan \(.*SIM in illegal state',
    'sim_wait': r'netifd: wan \(.*Waiting for SIM initialization',
    'registration_wait': r'netifd: wan \(.*Waiting for network registration',
    'registration_failed': r'netifd: wan \(.*Network registration failed',
    'cellular_setup': r'netifd: wan \(.*Setting up wwan',
    'usb_disconnect': r'kernel:.*usb .*USB disconnect',
    'usb_reset': r'kernel:.*reset .*USB device',
    'usb_error': r'kernel:.*usb .*\b(?:error|failed|timeout)\b',
    'sd_unclean': r'kernel:.*FAT-fs .*not properly unmounted',
    'sd_io_error': r'kernel:.*(?:mmcblk[0-9].*(?:I/O error|Buffer I/O)|mmc[0-9]:\s.*(?:error -\d|timeout)|EXT4-fs.*(?:error|corrupt)|FAT-fs.*(?:error|invalid|read-only))',
    'undervoltage': r'kernel:.*(?:Under-voltage|Voltage normalised)',
    'oom': r'kernel:.*(?:Out of memory|oom-kill|Killed process)',
    'vpn_unreachable': r'ipsec:.*Host is unreachable',
    'collector_error': r'kk-car-(?:diagnostics|ups):.*(?:failed|error)',
}
EVENTS = {'low_voltage_shutdown', 'power_action', 'power_action_failed',
          'ups_countdown_orphaned', 'ups_countdown_cancelled', 'ups_transition'}
NUMERIC = {'controller_mv', 'sensor_mv', 'battery_mv', 'threshold_mv',
           'consecutive', 'shutdown_s', 'restart_s'}
ENUMS = {'action': {'shutdown', 'restart_ups', 'reboot_pi', 'cancel_shutdown',
                    'cancel_restart', 'factory_reset'},
         'voltage_source': {'battery_sensor', 'controller'}}
ENUMS['state'] = {'disabled', 'monitoring', 'external_power', 'on_battery',
                  'low_battery_wait', 'low_battery', 'read_error', 'invalid_voltage'}


def read_json(path):
    try:
        value = json.loads(Path(path).read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def command(args, seconds=5):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=seconds)
        return result.stdout if result.returncode == 0 else ''
    except (OSError, subprocess.TimeoutExpired):
        return ''


def number(value, lo=-1e12, hi=1e12):
    return value if type(value) in (float, int) and math.isfinite(value) and lo <= value <= hi else None


def enum(value, choices):
    return value if isinstance(value, str) and value in choices else None


def fresh(data, now, ttl):
    stamp = number(data.get('timestamp'), 1)
    return stamp is not None and 0 <= now-stamp <= ttl


def identity():
    try:
        boot = BOOT.read_text().strip()
        up = int(float(Path('/proc/uptime').read_text().split()[0]))
    except (OSError, ValueError, IndexError):
        boot, up = '', 0
    return {'timestamp': int(time.time()), 'uptime_s': up, 'boot': boot}


def private_dir():
    DIRECTORY.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(DIRECTORY, 0o700)


def atomic(path, data):
    temp = Path(str(path)+'.new')
    with temp.open('w') as stream:
        os.chmod(temp, 0o600)
        json.dump(data, stream, separators=(',', ':'), allow_nan=False)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def append(data):
    private_dir()
    encoded = (json.dumps(data, ensure_ascii=False, separators=(',', ':'), allow_nan=False)+'\n').encode()
    if len(encoded) > 16384:
        raise ValueError('Diagnostic record too large')
    with (DIRECTORY/'writer.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        active = DIRECTORY/'faults.jsonl'
        # A hard power cut can leave the final JSON line incomplete. Under the
        # shared writer lock, trim only that tail so the next boot/event remains
        # a separate readable record. Complete earlier lines remain intact.
        if active.exists() and active.stat().st_size:
            size = active.stat().st_size
            with active.open('r+b') as stream:
                offset = max(0, size-16384)
                stream.seek(offset)
                tail = stream.read()
                if not tail.endswith(b'\n'):
                    stream.truncate(offset+tail.rfind(b'\n')+1)
        if active.exists() and active.stat().st_size + len(encoded) > LIMIT:
            (DIRECTORY/f'faults.{FILES-1}.jsonl').unlink(missing_ok=True)
            for index in range(FILES-2, 0, -1):
                old = DIRECTORY/f'faults.{index}.jsonl'
                if old.exists():
                    os.replace(old, DIRECTORY/f'faults.{index+1}.jsonl')
            os.replace(active, DIRECTORY/'faults.1.jsonl')
        with active.open('ab') as stream:
            os.chmod(active, 0o600)
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())


def event(kind, details):
    if kind not in EVENTS:
        raise ValueError('Unsupported diagnostic event')
    clean = {key: number(details.get(key)) for key in NUMERIC if key in details}
    for key, choices in ENUMS.items():
        if key in details:
            clean[key] = enum(details[key], choices)
    if type(details.get('external')) is bool:
        clean['external'] = details['external']
    append(dict(identity(), event=kind, details=clean))


def error_counts(raw):
    # Persist categories/counts only: raw lines may contain SMS, IPs or credentials.
    return {key: len(re.findall(pattern, raw, re.I)) for key, pattern in ERRORS.items()}


def network(status):
    codes = {'NO_DEVICE', 'NO_IFACE', 'SIM_NOT_INITIALIZED', 'SIM_ILLEGAL_STATE',
             'PIN_FAILED', 'PUK_NEEDED', 'PIN_NOT_SPECIFIED', 'PIN_STATUS_FAILED',
             'NETWORK_REGISTRATION_FAILED', 'NO_CID', 'CALL_FAILED'}
    return {'up': status.get('up') is True, 'pending': status.get('pending') is True,
            'available': status.get('available') is True,
            'uptime_s': number(status.get('uptime'), 0),
            'errors': [item['code'] for item in status.get('errors', [])
                       if isinstance(item, dict) and item.get('code') in codes]}


def select_snapshot(ups, modem, at, uplink, ping, watch, wan, now):
    mf, af = fresh(modem, now, 75), fresh(at, now, 120)
    b, inp, out = ups.get('battery', {}), ups.get('input', {}), ups.get('output', {})
    ctrl = ups.get('controller', {})
    sensors = ups.get('sensors', {})
    def sensor(name):
        s = sensors.get(name, {})
        return {'detected': s.get('detected') is True,
                'bus_mv': number(s.get('bus_mv'), 0, 15000),
                'current_ma_estimate': number(s.get('current_ma'), -20000, 20000),
                'power_mw_estimate': number(s.get('power_mw'), -100000, 100000)}
    def metric(qkey, akey, low, high):
        value = number(modem.get(qkey), low, high) if mf else None
        return value if value is not None else number(at.get(akey), low, high) if af else None
    return {
        'ups': {'ok': ups.get('ok') is True, 'external': inp.get('external') if type(inp.get('external')) is bool else None,
                'usb_c_mv': number(inp.get('usb_c_mv'), 0, 15000),
                'micro_usb_mv': number(inp.get('micro_usb_mv'), 0, 15000),
                'controller_mv': number(b.get('millivolts'), 0, 5000),
                'percent_estimate': number(b.get('percent'), 0, 100),
                'temperature_c_estimate': number(b.get('temperature_c'), -20, 100),
                'pogo_mv': number(out.get('pogo_mv'), 0, 6000),
                'pi_flags': number(out.get('power_flags'), 0),
                'shutdown_s': number(ctrl.get('shutdown_countdown_s'), 0, 255),
                'restart_s': number(ctrl.get('restart_countdown_s'), 0, 255),
                'auto_start_on_ac': ctrl.get('auto_start_on_ac') is True,
                'run_s': number(ctrl.get('current_run_s'), 0),
                'battery_sensor': sensor('battery'), 'pi_sensor': sensor('pi_supply'),
                'watch': {'state': enum(watch.get('status'), {'disabled', 'monitoring', 'external_power',
                         'on_battery', 'low_battery_wait', 'low_battery', 'read_error', 'invalid_voltage'}),
                         'consecutive': number(watch.get('consecutive'), 0, 10000),
                         'threshold_mv': number(watch.get('threshold_mv'), 3300, 3900)}},
        'cellular': {'usb_qmi_present': Path('/sys/class/usbmisc/cdc-wdm0/device').exists(),
                     'telemetry_fresh': mf, 'at_fresh': af,
                     'qmi_rc': number(modem.get('collector_rc'), 0, 255),
                     'state': enum(modem.get('collector_state'), {'wan_initializing', 'sampled', 'timeout'}),
                     'registered': mf and modem.get('registration') == 'registered',
                     'connected': modem.get('connected') if mf and type(modem.get('connected')) is bool else None,
                     'sim': enum(modem.get('sim_state'), {'ready', 'unknown', 'absent', 'blocked', 'pin_required', 'puk_required'}) if mf else None,
                     'rsrp': metric('rsrp', 'rsrp_dbm', -150, -30),
                     'rsrq': metric('rsrq', 'rsrq_db', -40, 20),
                     'rssi': metric('rssi', 'rssi_dbm', -140, -1),
                     'sinr': metric('snr', 'sinr_db', -30, 50),
                     'band': at.get('band') if af and re.fullmatch(r'LTE B\d{1,3}', str(at.get('band', ''))) else None,
                     'temperature_c': number(at.get('module_temperature_c'), -30, 100) if af else None,
                     'wan': network(wan)},
        'uplink': enum(uplink.get('active'), {'ethernet', 'cellular', 'none'}) if fresh(uplink, now, 30) else None,
        'vpn': {'state': enum(ping.get('state'), {'ok', 'error', 'offline', 'no_reply'}) if fresh(ping, now, 60) else None,
                'latency_ms': number(ping.get('avg_ms'), 0, 60000) if fresh(ping, now, 60) else None,
                'loss_percent': number(ping.get('loss_percent'), 0, 100) if fresh(ping, now, 60) else None},
    }


def snapshot():
    current = identity()
    raw = command(['ucode', '-e', 'import {sample} from "/etc/kk-car/ups-read.uc"; printf("%J",sample());'], 8)
    try:
        ups = json.loads(raw)
    except ValueError:
        ups = {}
    try:
        wan = json.loads(command(['ubus', '-t', '3', 'call', 'network.interface.wan', 'status']))
    except ValueError:
        wan = {}
    data = select_snapshot(ups, read_json('/tmp/kk-car-modem.json'), read_json('/tmp/kk-car-dji-at.json'),
                           read_json('/tmp/kk-car-uplink.json'), read_json('/tmp/kk-car-vpn-ping.json'),
                           read_json('/tmp/kk-car-ups-watch.json'), wan, current['timestamp'])
    counts = error_counts(command(['logread'], 5))
    previous = read_json(COUNTS)
    old = previous.get('counts', {}) if previous.get('boot') == current['boot'] else {}
    data['errors_total'] = counts
    # The first snapshot establishes a baseline; old boot-buffer errors did not
    # necessarily happen during this minute. Keep them only in errors_total.
    data['errors_new'] = {key: max(0, value-old.get(key, value)) for key, value in counts.items()}
    data['system'] = {'load': list(os.getloadavg()), 'cpu_temperature_c': None, 'memory_used_percent': None}
    try:
        data['system']['cpu_temperature_c'] = int(Path('/sys/class/thermal/thermal_zone0/temp').read_text())/1000
        mem = {key: int(value) for key, value in re.findall(r'^(MemTotal|MemAvailable):\s+(\d+)', Path('/proc/meminfo').read_text(), re.M)}
        data['system']['memory_used_percent'] = round((1-mem['MemAvailable']/mem['MemTotal'])*100, 1)
    except (OSError, ValueError, KeyError, ZeroDivisionError):
        pass
    append(dict(current, event='sample', **data))
    atomic(COUNTS, {'boot': current['boot'], 'counts': counts})
    atomic(CACHE, dict(current, ok=True, interval_s=60, max_bytes=LIMIT*FILES, **data))


def lifecycle(kind):
    private_dir()
    current = identity()
    marker = DIRECTORY/'lifecycle.json'
    previous = read_json(marker)
    if kind == 'start':
        changed = previous.get('boot') != current['boot']
        append(dict(current, event='boot' if changed else 'recorder_restart',
                    previous_clean=previous.get('clean') if changed else None,
                    previous_boot=previous.get('boot') if changed else None))
        if changed:
            atomic(marker, dict(current, clean=False))
    elif kind == 'shutdown':
        append(dict(current, event='os_shutdown'))
        atomic(marker, dict(current, clean=True))


def main():
    os.umask(0o077)
    mode = sys.argv[1] if len(sys.argv) > 1 else 'once'
    if mode == 'event':
        value = json.load(sys.stdin)
        event(value.get('event'), value.get('details', {}))
    elif mode == 'shutdown':
        lifecycle('shutdown')
    elif mode == 'once':
        snapshot()
    elif mode == 'run':
        private_dir()
        with (DIRECTORY/'daemon.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lifecycle('start')
            while True:
                started = time.monotonic()
                try:
                    snapshot()
                except Exception:
                    command(['logger', '-t', 'kk-car-diagnostics', 'snapshot failed'])
                time.sleep(max(1, 60-(time.monotonic()-started)))
    else:
        raise ValueError('Unknown recorder mode')


if __name__ == '__main__':
    main()
