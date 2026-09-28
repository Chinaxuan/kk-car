#!/usr/bin/env python3
"""Shared display/scheduler settings. No networking or UPS register writes."""
import fcntl
import json
import os
import subprocess
import sys
import time
from pathlib import Path

SETTINGS = Path('/etc/kk-car/private/device-settings.json')
LEGACY = Path('/etc/kk-car/private/epaper-settings.json')
DEFAULTS = dict(rotation=180, refresh_seconds=180, grayscale=True, fast_refresh=True,
                partial_refresh=True, clean_after=5, sleep_seconds=30, start_page=1,
                auto_page_seconds=0, hdmi_refresh_seconds=5, check_interval_seconds=600,
                battery_capacity_mah=3000)
CHOICES = dict(rotation=(0, 180), refresh_seconds=(60, 180, 300, 600),
               clean_after=(1, 2, 3, 4, 5), sleep_seconds=(18, 30, 60), start_page=tuple(range(1, 7)),
               auto_page_seconds=(0, 60, 180, 300), hdmi_refresh_seconds=(5, 10, 15, 30, 60),
               check_interval_seconds=(300, 600, 900, 1800, 3600),
               battery_capacity_mah=tuple(range(500, 10001, 100)))
SERVICES = ('epaper', 'hdmi', 'auto-check', 'diagnostics', 'modem', 'vpn-ping',
            'notify', 'dji-sms-forward', 'voice-runtime', 'voice-gateway', 'network-health')
JOB = Path('/tmp/kk-car-settings-job.json')
SERVICE_LOCK = Path('/tmp/kk-car-settings-service-lock')


def filejson(path):
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def valid(key, value):
    if key not in DEFAULTS:
        return False
    if type(DEFAULTS[key]) is bool:
        return type(value) is bool
    return type(value) is int and value in CHOICES[key]


def snapshot():
    data = filejson(SETTINGS)
    values = dict(DEFAULTS)
    # Preserve the previously accepted one-minute setting on first migration.
    legacy = filejson(LEGACY).get('refresh_seconds')
    if valid('refresh_seconds', legacy):
        values['refresh_seconds'] = legacy
    values.update({k: v for k, v in data.items() if valid(k, v)})
    revision = data.get('revision', 0)
    return dict(settings=values, revision=revision if type(revision) is int and revision >= 0 else 0)


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.new')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as out:
        os.fchmod(out.fileno(), 0o600)
        json.dump(data, out, separators=(',', ':'))
        out.write('\n')
        out.flush()
        os.fsync(out.fileno())
    temp.replace(path)


def save(updates, expected):
    if not isinstance(updates, dict) or not updates or any(not valid(k, v) for k, v in updates.items()):
        return dict(ok=False, error='设置值无效或超出支持范围')
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    with open(SETTINGS.with_suffix('.lock'), 'a') as lock:
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = snapshot()
        if type(expected) is not int or expected != current['revision']:
            return dict(ok=False, conflict=True, error='设置已被屏幕或另一页面修改，请重新读取后再保存', **current)
        values = dict(current['settings'], **updates)
        revision = current['revision'] + 1
        atomic(SETTINGS, dict(values, revision=revision))
        return dict(ok=True, settings=values, revision=revision)


def service_run(name, action):
    """Only reached by the allow-listed RPC; report completion, not launch success."""
    try:
        if name not in SERVICES or action not in ('start', 'stop', 'restart', 'enable', 'disable'):
            raise ValueError('Unsupported service action')
        result = subprocess.run(['/etc/init.d/kk-car-' + name, action],
                                capture_output=True, timeout=45)
        atomic(JOB, dict(state='done' if result.returncode == 0 else 'error', name=name,
                         action=action, timestamp=int(time.time()),
                         error=None if result.returncode == 0 else '服务操作失败，请查看故障日志'))
    except (OSError, ValueError, subprocess.SubprocessError):
        atomic(JOB, dict(state='error', name=name, action=action,
                         timestamp=int(time.time()), error='服务操作失败或超时'))
    finally:
        if SERVICE_LOCK.exists():
            SERVICE_LOCK.rmdir()


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'get':
            result = dict(ok=True, **snapshot())
        elif sys.argv[1] == 'save':
            args = json.loads(sys.argv[2])
            result = save(args['settings'], args['revision'])
        elif sys.argv[1] == 'service-run':
            service_run(sys.argv[2], sys.argv[3])
            result = dict(ok=True)
        else:
            result = dict(ok=False, error='Unsupported operation')
    except (OSError, ValueError, KeyError, IndexError):
        result = dict(ok=False, error='设置无法读取或保存')
    print(json.dumps(result, ensure_ascii=False))
