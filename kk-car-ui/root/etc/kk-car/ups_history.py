#!/usr/bin/env python3
"""Read retained diagnostic snapshots; never sample or change UPS hardware."""
import fcntl
import hashlib
import json
import math
from pathlib import Path
import sys
import time

DIRECTORY = Path('/etc/kk-car/private/diagnostics')
COLUMNS = ['timestamp', 'segment', 'mode', 'controller_v', 'sensor_v',
           'battery_a', 'battery_w', 'pi_v', 'pi_w', 'temperature_c',
           'percent_estimate', 'external', 'undervoltage']
METRICS = COLUMNS[3:11]
RANGES = {'1h': 3600, '24h': 86400, '7d': 604800, '30d': 2592000, 'all': None, 'custom': None}
POINT_LIMIT = 1000
GAP = 180


def num(value, low, high, scale=1):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        return None
    return round(value / scale, 4)


def normalize(item):
    if not isinstance(item, dict) or item.get('event') != 'sample':
        return None
    stamp = num(item.get('timestamp'), 1704067200, 4102444800)
    if stamp is None:
        return None
    u = item.get('ups')
    if not isinstance(u, dict):
        u = {}
    battery = u.get('battery_sensor') if isinstance(u.get('battery_sensor'), dict) else {}
    pi = u.get('pi_sensor') if isinstance(u.get('pi_sensor'), dict) else {}
    ok = u.get('ok') is True
    external = u.get('external') if type(u.get('external')) is bool and ok else None
    current = num(battery.get('current_ma_estimate'), -20000, 20000, 1000) if ok and battery.get('detected') is True else None
    mode = ('discharge' if external is False or current is not None and current < -0.05 else
            'charge' if current is not None and current > 0.05 else
            'idle' if external is True and current is not None else 'unknown')
    flags = num(u.get('pi_flags'), 0, 0xffffffff)
    values = [stamp, 0, mode,
              num(u.get('controller_mv'), 0, 5000, 1000) if ok else None,
              num(battery.get('bus_mv'), 0, 5000, 1000) if ok and battery.get('detected') is True else None,
              current,
              num(battery.get('power_mw_estimate'), -100000, 100000, 1000) if current is not None else None,
              num(u.get('pogo_mv'), 0, 6000, 1000) if ok else None,
              num(pi.get('power_mw_estimate'), -100000, 100000, 1000) if ok and pi.get('detected') is True else None,
              num(u.get('temperature_c_estimate'), -20, 100) if ok else None,
              num(u.get('percent_estimate'), 0, 100) if ok else None,
              external, bool(int(flags) & 1) if flags is not None else None]
    return {'values': values, 'boot': str(item.get('boot', ''))[:64],
            'uptime': num(item.get('uptime_s'), 0, 1e12)}


def read_records():
    records, events = [], []
    stats = {'invalid_lines': 0, 'files': 0}
    if not DIRECTORY.is_dir():
        return records, events, stats
    lock_path = DIRECTORY / 'writer.lock'
    lock = lock_path.open('rb') if lock_path.exists() and not lock_path.is_symlink() else None
    try:
        if lock:
            fcntl.flock(lock, fcntl.LOCK_SH)
        for name in [f'faults.{i}.jsonl' for i in range(7, 0, -1)] + ['faults.jsonl']:
            path = DIRECTORY / name
            if not path.is_file() or path.is_symlink():
                continue
            stats['files'] += 1
            with path.open('rb') as source:
                consumed = 0
                while consumed < 2 * 1024 * 1024 + 16384:
                    line = source.readline(16385)
                    if not line:
                        break
                    consumed += len(line)
                    if len(line) > 16384:
                        while line and not line.endswith(b'\n'):
                            line = source.readline(16385)
                            consumed += len(line)
                        stats['invalid_lines'] += 1
                        continue
                    if not line.endswith(b'\n'):
                        stats['invalid_lines'] += 1
                        continue
                    try:
                        item = json.loads(line)
                        row = normalize(item)
                        if row:
                            records.append(row)
                        elif isinstance(item, dict) and item.get('event') in ('boot', 'os_shutdown', 'low_voltage_shutdown', 'ups_transition', 'power_action'):
                            stamp = num(item.get('timestamp'), 1704067200, 4102444800)
                            if stamp:
                                events.append({'timestamp': stamp, 'event': item['event']})
                    except (ValueError, TypeError, UnicodeError):
                        stats['invalid_lines'] += 1
    finally:
        if lock:
            lock.close()
    return records, events, stats


def connected(a, b):
    dt = b['values'][0] - a['values'][0]
    if not 0 < dt <= GAP or a['boot'] != b['boot'] or not a['boot']:
        return False
    if a['uptime'] is None or b['uptime'] is None:
        return False
    return abs(b['uptime'] - a['uptime'] - dt) <= 15


def downsample(rows, limit=POINT_LIMIT):
    """Keep actual samples, overall ends and extrema of all plotted metrics."""
    if len(rows) <= limit:
        return [r['values'] for r in rows], False
    selected = {0, len(rows) - 1}
    buckets = max(1, limit // (len(METRICS) * 2 + 2))
    size = math.ceil(len(rows) / buckets)
    for start in range(0, len(rows), size):
        stop = min(start + size, len(rows))
        selected.update((start, stop - 1))
        for col in range(3, 11):
            available = [i for i in range(start, stop) if rows[i]['values'][col] is not None]
            if available:
                selected.add(min(available, key=lambda i: rows[i]['values'][col]))
                selected.add(max(available, key=lambda i: rows[i]['values'][col]))
    # Segment IDs still prohibit joining missing spans after reduction.
    return [rows[i]['values'] for i in sorted(selected)], True


def summary(rows):
    ranges = {}
    for idx, key in enumerate(METRICS, 3):
        values = [r['values'][idx] for r in rows if r['values'][idx] is not None]
        ranges[key] = {'min': min(values), 'max': max(values), 'first': values[0], 'last': values[-1]} if values else None
    covered = 0
    energy = {'charge_wh': 0, 'discharge_wh': 0, 'charge_ah': 0, 'discharge_ah': 0, 'integrated_s': 0}
    modes = {'charge': 0, 'discharge': 0, 'idle': 0, 'unknown': 0}
    for a, b in zip(rows, rows[1:]):
        if not connected(a, b) or a['values'][1] != b['values'][1]:
            continue
        dt = b['values'][0] - a['values'][0]
        covered += dt
        if a['values'][2] == b['values'][2]:
            modes[b['values'][2]] += dt
            current = [a['values'][5], b['values'][5]]
            power = [a['values'][6], b['values'][6]]
            if b['values'][2] in ('charge', 'discharge') and all(v is not None for v in current + power):
                sign = 1 if b['values'][2] == 'charge' else -1
                # Reject a sign conflict; do not label a sensor inconsistency capacity.
                if all(sign * v >= 0 for v in current + power):
                    prefix = b['values'][2]
                    energy[prefix + '_wh'] += sign * sum(power) / 2 * dt / 3600
                    energy[prefix + '_ah'] += sign * sum(current) / 2 * dt / 3600
                    energy['integrated_s'] += dt
    return {'samples': len(rows), 'start': rows[0]['values'][0] if rows else None,
            'end': rows[-1]['values'][0] if rows else None, 'covered_s': covered,
            'mode_seconds': modes, 'ranges': ranges,
            'energy_estimate': {k: round(v, 4) for k, v in energy.items()},
            'undervoltage_samples': sum(r['values'][12] is True for r in rows)}


def history(query, now=None):
    now = time.time() if now is None else now
    chosen = query.get('range', '24h')
    if chosen not in RANGES:
        raise ValueError('不支持的时间范围')
    end = now
    start = now - RANGES[chosen] if RANGES[chosen] else 1704067200
    if chosen == 'custom':
        start = num(query.get('start'), 1704067200, now)
        end = num(query.get('end'), 1704067200, now + 60)
        if start is None or end is None or start >= end:
            raise ValueError('请输入有效的开始与结束时间')
    records, events, stats = read_records()
    # Establish segments in storage order before sorting wall-clock times.
    unique, seen, previous, segment, session = [], set(), None, 0, 0
    for row in records:
        key = (row['values'][0], row['boot'], row['uptime'])
        if key in seen:
            continue
        seen.add(key)
        if previous is None or not connected(previous, row) or any(
                (previous['values'][i] is None) != (row['values'][i] is None) for i in range(3, 11)):
            segment += 1
        if previous is None or not connected(previous, row) or previous['values'][11] != row['values'][11]:
            session += 1
        row['values'][1] = segment
        row['session'] = session
        previous = row
        if row['values'][0] <= now + 60:
            unique.append(row)
    unique.sort(key=lambda r: r['values'][0])
    rows = [r for r in unique if start <= r['values'][0] <= end]
    sessions = []
    for row in rows:
        if not sessions or sessions[-1]['segment'] != row['session']:
            sessions.append({'segment': row['session'], 'mode': 'external' if row['values'][11] is True else 'discharge' if row['values'][11] is False else 'unknown',
                             'start': row['values'][0], 'end': row['values'][0], 'samples': 0})
        sessions[-1]['end'] = row['values'][0]
        sessions[-1]['samples'] += 1
    selected = query.get('segment', 0)
    if type(selected) is not int or selected < 0:
        raise ValueError('无效的充放电过程')
    if selected:
        rows = [r for r in rows if r['session'] == selected]
        if rows:
            start, end = rows[0]['values'][0], rows[-1]['values'][0]
    window_id = hashlib.sha256(json.dumps([r['values'] for r in rows], separators=(',', ':'), allow_nan=False).encode()).hexdigest()
    raw = query.get('raw', False)
    offset = query.get('offset', 0)
    if type(raw) is not bool or type(offset) is not int or offset < 0:
        raise ValueError('无效的导出参数')
    if raw:
        points, reduced = [r['values'] for r in rows[offset:offset + POINT_LIMIT]], False
    else:
        points, reduced = downsample(rows)
    return {'ok': True, 'timestamp': int(now), 'range': chosen,
            'requested': {'start': start, 'end': end}, 'columns': COLUMNS, 'points': points,
            'downsampled': reduced, 'summary': summary(rows), 'sessions': sessions[-200:],
            'window_id': window_id, 'next_offset': offset + len(points) if raw and offset + len(points) < len(rows) else None,
            'session_count': len(sessions), 'events': [e for e in events if start <= e['timestamp'] <= end][-200:],
            'retained': {'start': unique[0]['values'][0] if unique else None,
                         'end': unique[-1]['values'][0] if unique else None, 'samples': len(unique)},
            'reader': stats, 'sample_interval_s': 60, 'gap_after_s': GAP,
            'retention_max_bytes': 16 * 1024 * 1024, 'calibration_verified': False}


def main():
    try:
        query = json.loads(sys.argv[1]) if len(sys.argv) == 2 else {}
        if not isinstance(query, dict):
            raise ValueError('无效查询')
        result = history(query)
    except Exception as exc:
        # Never expose paths, log lines or exception details from files.
        result = {'ok': False, 'error': str(exc) if isinstance(exc, ValueError) else '历史日志暂时无法读取'}
    print(json.dumps(result, ensure_ascii=False, separators=(',', ':'), allow_nan=False))


if __name__ == '__main__':
    main()
