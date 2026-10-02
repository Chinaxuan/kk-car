#!/usr/bin/python3
"""Interface-bound health probes and conservative, rate-limited recovery.

No UCI, route, Wi-Fi, DHCP, USB power or firmware writes. Inspired by ROOter's
multiple-target monitor; existing kk-car-uplink remains the only route selector.
"""
import concurrent.futures
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

BASE = Path('/etc/kk-car/private/network-health')
CONFIG = BASE / 'settings.json'
JOURNAL = BASE / 'events.jsonl'
CACHE = Path('/tmp/kk-car-network-health.json')
STATE = Path('/tmp/kk-car-network-health-state.json')
REQUEST = Path('/tmp/kk-car-network-health-check')
DEFAULTS = dict(enabled=True, interval_seconds=30, fail_rounds=3, recover_rounds=2,
                cooldown_seconds=300, max_actions_hour=2, boot_grace_seconds=120,
                recover_vpn=True, recover_cellular=False,
                wan_targets=['223.5.5.5', '119.29.29.29'],
                vpn_targets=['10.8.8.8', '1.1.1.1'])
LIMITS = dict(interval_seconds=(30, 300), fail_rounds=(3, 10), recover_rounds=(2, 5),
              cooldown_seconds=(300, 3600), max_actions_hour=(1, 4), boot_grace_seconds=(120, 600))
BOOLS = ('enabled', 'recover_vpn', 'recover_cellular')
STATES = {'healthy', 'degraded', 'failed', 'unavailable', 'paused', 'unknown', 'disabled'}
LABELS = {'healthy': '正常', 'degraded': '部分目标无响应', 'failed': '连续无响应',
          'unavailable': '接口未就绪', 'paused': '已手动暂停', 'unknown': '待确认', 'disabled': '已关闭'}
JOURNAL_LIMIT = 512 * 1024  # active + one rotation, at most 1 MiB


def read_json(path):
    try:
        value = json.loads(Path(path).read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.new')
    with temp.open('w') as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(value, stream, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
        stream.write('\n')
        stream.flush()
        if str(path).startswith(str(BASE)):
            os.fsync(stream.fileno())
    temp.replace(path)


def validate(values):
    if not isinstance(values, dict) or set(values) != set(DEFAULTS):
        raise ValueError('设置项目不完整或不受支持')
    for key in BOOLS:
        if type(values[key]) is not bool:
            raise ValueError('开关设置无效')
    for key, (lo, hi) in LIMITS.items():
        if type(values[key]) is not int or not lo <= values[key] <= hi:
            raise ValueError('检测周期、连续轮数或重连限额超出允许范围')
    for key in ('wan_targets', 'vpn_targets'):
        targets = values[key]
        if not isinstance(targets, list) or not 2 <= len(targets) <= 4 or len(set(map(str, targets))) != len(targets):
            raise ValueError('每条线路需要 2–4 个不重复的 IPv4 目标')
        for target in targets:
            try:
                ip = ipaddress.IPv4Address(target) if isinstance(target, str) else None
            except ipaddress.AddressValueError:
                ip = None
            if not ip or ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local or str(ip) != target or target == '255.255.255.255':
                raise ValueError('探测地址须为可达的单播 IPv4 地址')
    return dict(values)


def settings():
    raw = read_json(CONFIG)
    try:
        values = validate(dict(DEFAULTS, **raw.get('settings', {})))
    except (ValueError, TypeError):
        values = dict(DEFAULTS)
    revision = raw.get('revision', 0)
    return dict(settings=values, revision=revision if type(revision) is int and revision >= 0 else 0)


def save(payload):
    values = validate(payload.get('settings'))
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(BASE, 0o700)
    with (BASE / 'settings.lock').open('a') as lock:
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = settings()
        if type(payload.get('revision')) is not int or payload['revision'] != before['revision']:
            return dict(ok=False, conflict=True, error='另一页面已修改设置，请刷新后重试')
        value = dict(settings=values, revision=before['revision'] + 1)
        atomic(CONFIG, value)
    REQUEST.touch(mode=0o600)
    return dict(ok=True, **value)


def command(args, timeout=4):
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=timeout, text=True)
        return result.returncode, result.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 124, ''


def ubus(obj, method='status', timeout=4):
    code, text = command(['ubus', '-t', str(max(1, int(timeout)-1)), 'call', obj, method], timeout)
    try:
        value = json.loads(text)
        return value if code == 0 and isinstance(value, dict) else {}
    except ValueError:
        return {}


def identity():
    return dict(boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                uptime_s=int(float(Path('/proc/uptime').read_text().split()[0])), timestamp=int(time.time()))


def fresh(data, now, ttl):
    stamp = data.get('timestamp')
    return type(stamp) in (int, float) and 0 <= now - stamp <= ttl


def interface(value):
    return value if isinstance(value, str) and re.fullmatch(r'(?:eth|wwan|usb)[0-9]+', value) else ''


def ping(dev, target):
    # Validate again at the process boundary. Never retry without -I.
    if dev not in ('ikecar', 'ovpncar') and not interface(dev):
        return dict(target=target, ok=None, latency_ms=None, reason='invalid_interface')
    code, raw = command(['ping', '-4', '-n', '-I', dev, '-c', '1', '-W', '2', '-w', '3', target], 4)
    match = re.search(r'time[=<]([0-9]+(?:\.[0-9]+)?)\s*ms', raw)
    return dict(target=target, ok=code == 0, latency_ms=float(match[1]) if match and code == 0 else None)


def context():
    current = identity()
    uplink = read_json('/tmp/kk-car-uplink.json')
    modem = read_json('/tmp/kk-car-modem.json')
    wan = ubus('network.interface.wan')
    backend = command(['uci', '-q', 'get', 'openvpn.kkcar.enabled'], 2)[1].strip() == '1'
    ike = ubus('network.interface.ovpncar' if backend else 'network.interface.ikecar')
    if backend:
        running = bool(command(['pidof', 'openvpn'], 2)[1].strip())
        assigned = bool(re.search(r'\binet\s+[0-9.]+/', command(['ip', '-o', '-4', 'addr', 'show', 'dev', 'ovpncar'], 2)[1]))
        connected = running and assigned
        ike['up'] = connected
        code = 0
    else:
        running = Path('/var/run/charon.pid').exists()
        code, raw = command(['/usr/sbin/swanctl', '--list-sas'], 3) if running else (0, '')
        connected = code == 0 and 'ESTABLISHED' in raw and 'INSTALLED' in raw
    return dict(**current, uplink=uplink, modem=modem, wan=wan, ike=ike,
                running=running, connected=connected, sa_known=code == 0,
                vpn_device='ovpncar' if backend else 'ikecar', vpn_backend='openvpn' if backend else 'ike')


def plan_groups(ctx):
    uplink, now = ctx['uplink'], ctx['timestamp']
    valid = fresh(uplink, now, 30)
    groups = {}
    for name, key in [('cellular', 'cell'), ('ethernet', 'wire')]:
        link = uplink.get(key, {}) if valid else {}
        dev = interface(link.get('device'))
        reason = 'ready' if link.get('up') and link.get('default_route') and dev else 'no_address'
        if not valid:
            reason = 'uplink_stale'
        elif name == 'ethernet' and uplink.get('mode') != 'wan':
            reason = 'lan_mode'
        elif name == 'ethernet' and not uplink.get('carrier'):
            reason = 'no_cable'
        elif name == 'cellular' and fresh(ctx['modem'], now, 90) and ctx['modem'].get('sim_state') in ('absent', 'blocked', 'pin_required', 'puk_required'):
            reason = 'sim_' + ctx['modem']['sim_state']
        groups[name] = dict(device=dev, reason=reason, available=reason == 'ready',
                            identity=f"{dev}/{link.get('ip', '')}/{link.get('gateway', '')}")
    reason = 'ready' if ctx['connected'] and ctx['ike'].get('up') else 'not_connected'
    if not ctx['running']:
        reason = 'user_paused'
    elif not ctx['sa_known'] or not ctx['ike']:
        reason = 'status_unreadable'
    groups['vpn'] = dict(device=ctx.get('vpn_device', 'ikecar'), reason=reason, available=reason == 'ready',
                         identity=str(ctx['ike'].get('ipv4-address', [])))
    return groups


def advance(group, probes, previous, config):
    """All-target failure hysteresis. A single missed target cannot reconnect."""
    same = previous.get('identity') == group['identity']
    old = previous if same else {}
    good, bad = old.get('good', 0), old.get('bad', 0)
    reason = group['reason']
    if reason in ('uplink_stale', 'status_unreadable'):
        state, good, bad = 'unknown', 0, 0
    elif reason == 'user_paused':
        state, good, bad = 'paused', 0, 0
    elif reason in ('lan_mode', 'no_cable') or reason.startswith('sim_'):
        state, good, bad = 'unavailable', 0, 0
    else:
        known = [p for p in probes if p.get('ok') is not None]
        passes = sum(p['ok'] is True for p in known)
        if group['available'] and not known:
            state, good, bad = 'unknown', 0, 0
        elif passes:
            good, bad = min(good + 1, 100), 0
            state = 'healthy' if passes == len(known) else 'degraded'
            if old.get('state') == 'failed' and good < config['recover_rounds']:
                state = 'failed'
                reason = 'recovering'
        else:
            good, bad = 0, min(bad + 1, 100)
            state = 'failed' if bad >= config['fail_rounds'] or old.get('state') == 'failed' else 'unknown'
            reason = 'all_targets_failed' if group['available'] else reason
    return dict(group, state=state, reason=reason, good=good, bad=bad, targets=probes,
                responding=sum(p.get('ok') is True for p in probes), total=len(probes))


def candidate(groups, ctx, config):
    active = ctx['uplink'].get('active')
    physical = groups.get(active, {})
    cell, vpn = groups['cellular'], groups['vpn']
    if config['recover_cellular'] and active in ('cellular', 'none') and cell['state'] == 'failed' and not cell['reason'].startswith('sim_'):
        return 'cellular_reconnect'
    if config['recover_vpn'] and vpn['state'] == 'failed' and physical.get('responding', 0) > 0 and physical.get('state') in ('healthy', 'degraded'):
        return 'vpn_reconnect' if ctx['connected'] else 'vpn_initiate'
    return None


def budget(state, ctx, config):
    # Monotonic uptime + boot ID: NTP corrections cannot release cooldowns.
    attempts = [a for a in state.get('attempts', []) if a.get('boot') == ctx['boot'] and
                0 <= ctx['uptime_s'] - a.get('uptime_s', -3600) < 3600]
    if ctx['uptime_s'] < config['boot_grace_seconds']:
        return attempts, 'boot_grace'
    if attempts and ctx['uptime_s'] - attempts[-1]['uptime_s'] < config['cooldown_seconds']:
        return attempts, 'cooldown'
    if len(attempts) >= config['max_actions_hour']:
        return attempts, 'hour_limit'
    return attempts, None


def guarded(action, ctx, config):
    """Check all manual settings again after taking the shared UI operation lock."""
    for path in ('/tmp/kk-car-settings-service-lock', '/tmp/kk-car-dji-control-lock',
                 '/etc/kk-car/ui-wifi-pending.json', '/etc/kk-car/ui-port-pending.json'):
        if Path(path).exists():
            return 'manual_operation'
    uplink = ctx['uplink']
    if not fresh(uplink, ctx['timestamp'], 30) or not uplink.get('ready'):
        return 'uplink_stale'
    changed = uplink.get('changed', ctx['timestamp'])
    if type(changed) not in (int, float) or ctx['timestamp'] - changed < 90:
        return 'uplink_settling'
    if action.startswith('vpn_'):
        if not config['recover_vpn'] or not ctx['running']:
            return 'vpn_paused'
        if not ctx['sa_known'] or not ctx['ike'].get('autostart'):
            return 'status_unreadable'
    elif action == 'cellular_reconnect':
        if not config['recover_cellular'] or ctx['wan'].get('autostart') is not True or ctx['wan'].get('pending'):
            return 'cellular_paused_or_initializing'
        for path in ('/tmp/kk-car-voice-ready', '/tmp/kk-car-voice-outgoing-pending'):
            if Path(path).exists():
                return 'call_active'
        # Only a successful, explicitly idle voice probe permits QMI recovery.
        if ctx['wan'].get('proto') == 'qmi':
            voice = ubus('kkdji', 'voice_probe', 22)
            if not voice.get('ok') or voice.get('call_query_accepted') is not True:
                return 'call_unknown'
            if voice.get('active_calls') != 0 or voice.get('call_state') != 'idle':
                return 'call_active'
        else:
            return 'call_unknown'
    return None


def recover(action):
    if action.startswith('vpn_') and command(['uci', '-q', 'get', 'openvpn.kkcar.enabled'], 2)[1].strip() == '1':
        return command(['/etc/init.d/openvpn', 'restart'], 8)[0] == 0
    if action == 'vpn_reconnect':
        code, _ = command(['/usr/sbin/swanctl', '--terminate', '--child', 'kk-car-internet', '--timeout', '3'], 5)
        if code != 0:
            return False
    if action.startswith('vpn_'):
        return command(['/usr/sbin/swanctl', '--initiate', '--child', 'kk-car-internet', '--timeout', '3'], 5)[0] == 0
    if action == 'cellular_reconnect':
        code, _ = command(['ubus', '-t', '3', 'call', 'network.interface.wan', 'down'], 4)
        if code != 0:
            return False
        try:
            time.sleep(2)
        finally:
            # Stopping the monitor during this wait must still bring WAN back.
            code, _ = command(['ubus', '-t', '3', 'call', 'network.interface.wan', 'up'], 4)
        return code == 0
    return False


def append_event(event):
    BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(BASE, 0o700)
    encoded = (json.dumps(event, ensure_ascii=False, separators=(',', ':')) + '\n').encode()
    with (BASE / 'events.lock').open('a') as lock:
        os.fchmod(lock.fileno(), 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if JOURNAL.exists():
            with JOURNAL.open('r+b') as stream:
                size = stream.seek(0, 2)
                stream.seek(max(0, size - 16384))
                offset = stream.tell()
                tail = stream.read()
                if tail and not tail.endswith(b'\n'):
                    stream.truncate(offset + tail.rfind(b'\n') + 1)
            if JOURNAL.stat().st_size + len(encoded) > JOURNAL_LIMIT:
                JOURNAL.replace(BASE / 'events.1.jsonl')
        with JOURNAL.open('ab') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())


def events():
    records = []
    for path in (BASE / 'events.1.jsonl', JOURNAL):
        try:
            with path.open('rb') as stream:
                stream.seek(max(0, path.stat().st_size - 60000))
                for line in stream:
                    try:
                        value = json.loads(line)
                        if isinstance(value, dict):
                            records.append(value)
                    except ValueError:
                        pass
        except OSError:
            pass
    return records[-80:][::-1]


def step(config, state, allow_recovery=True):
    ctx = context()
    same = state.get('boot') == ctx['boot'] and state.get('revision') == config['revision']
    old_groups = state.get('groups', {}) if same else {}
    values = config['settings']
    plans = plan_groups(ctx)
    probes = {name: [] for name in plans}
    if values['enabled']:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
            jobs = {executor.submit(ping, group['device'], target): name
                    for name, group in plans.items() if group['available']
                    for target in values['vpn_targets' if name == 'vpn' else 'wan_targets']}
            for future in concurrent.futures.as_completed(jobs):
                probes[jobs[future]].append(future.result())
        groups = {name: advance(group, sorted(probes[name], key=lambda p: p['target']), old_groups.get(name, {}), values)
                  for name, group in plans.items()}
        code, raw = command(['nslookup', '-timeout=2', '-retry=1', 'www.baidu.com', '127.0.0.1'], 4)
        # The resolver address alone is not a successful DNS answer.
        answers = re.findall(r'Address(?: [0-9]+)?:\s*([0-9]+(?:\.[0-9]+){3})', raw)
        dns = dict(state='healthy' if code == 0 and any(a != '127.0.0.1' for a in answers) else 'failed', target='www.baidu.com')
    else:
        groups = {name: dict(**group, state='disabled', good=0, bad=0, targets=[], responding=0, total=0) for name, group in plans.items()}
        dns = dict(state='disabled', target='www.baidu.com')
    attempts, suppressed = budget(state, ctx, values)
    action = candidate(groups, ctx, values) if values['enabled'] else None
    action_result = None
    lock = Path('/tmp/kk-car-ui-lock')
    if action and not suppressed:
        if not allow_recovery:
            suppressed = 'observe_only'
        else:
            owned = False
            try:
                lock.mkdir(mode=0o700)
                owned = True
                # Take a fresh snapshot and config; user pause wins over stale intent.
                fresh_ctx, fresh_config = context(), settings()
                if fresh_config['revision'] != config['revision'] or not fresh_config['settings']['enabled']:
                    suppressed = 'settings_changed'
                else:
                    # Check guards after network probes so the voice check is as
                    # close to a possible QMI reconnect as practicable.
                    # All-target failure is still required immediately before any mutation.
                    active = fresh_ctx['uplink'].get('active')
                    group_name = 'cellular' if action == 'cellular_reconnect' else 'vpn'
                    new_plan = plan_groups(fresh_ctx)[group_name]
                    targets = values['wan_targets' if group_name == 'cellular' else 'vpn_targets']
                    if new_plan['available'] and any(ping(new_plan['device'], t)['ok'] for t in targets):
                        suppressed = 'probe_recovered'
                    elif group_name == 'vpn' and (active not in ('ethernet', 'cellular') or
                          not any(ping(plan_groups(fresh_ctx)[active]['device'], t)['ok'] for t in values['wan_targets'])):
                        suppressed = 'physical_failed'
                    else:
                        final_config, final_ctx = settings(), context()
                        if final_config['revision'] != config['revision'] or not final_config['settings']['enabled']:
                            suppressed = 'settings_changed'
                        else:
                            suppressed = guarded(action, final_ctx, final_config['settings'])
                        if not suppressed:
                            # Settings may change during the bounded voice query.
                            final_config = settings()
                            if final_config['revision'] != config['revision'] or not final_config['settings']['enabled']:
                                suppressed = 'settings_changed'
                        if not suppressed:
                            attempt = identity()
                            attempts.append(dict(boot=attempt['boot'], uptime_s=attempt['uptime_s']))
                            # Persist the limit before invoking any recovery command.
                            state.update(boot=ctx['boot'], attempts=attempts)
                            atomic(STATE, state)
                            success = recover(action)
                            action_result = dict(action=action, accepted=success, timestamp=attempt['timestamp'])
                            append_event(dict(**identity(), event='recovery', action=action, accepted=success))
            except FileExistsError:
                suppressed = 'manual_operation'
            finally:
                if owned:
                    lock.rmdir()
    for name, group in groups.items():
        old = old_groups.get(name, {})
        # Log settled health transitions, not every probe or caller/IP identifier.
        if old.get('state') != group['state'] or old.get('reason') != group['reason']:
            append_event(dict(**ctx_identity(ctx), event='health', group=name,
                              state=group['state'], reason=group['reason'], responding=group['responding'], total=group['total']))
    if state.get('dns_state') != dns['state']:
        append_event(dict(**ctx_identity(ctx), event='health', group='dns', state=dns['state']))
    last = action_result or state.get('last_action')
    state = dict(**ctx_identity(ctx), revision=config['revision'], groups=groups, dns_state=dns['state'], attempts=attempts, last_action=last)
    atomic(STATE, state)
    # No internal IP identity is exposed as a metric. Target addresses are admin-only settings.
    visible = {name: {k: v for k, v in group.items() if k != 'identity'} for name, group in groups.items()}
    atomic(CACHE, dict(**ctx_identity(ctx), enabled=values['enabled'], groups=visible, dns=dns,
                       active=ctx['uplink'].get('active', 'unknown'), candidate=action, suppressed=suppressed if action else None,
                       last_action=last, actions_hour=len(attempts), next_in_seconds=values['interval_seconds']))
    return state


def ctx_identity(ctx):
    return {k: ctx[k] for k in ('boot', 'uptime_s', 'timestamp')}


def status():
    config = settings()
    value = read_json(CACHE)
    current = identity()
    value['fresh'] = value.get('boot') == current['boot'] and 0 <= current['uptime_s'] - value.get('uptime_s', -1000) <= config['settings']['interval_seconds'] + 25
    return dict(ok=True, **config, status=value, events=events(), timestamp=current['timestamp'])


def run():
    with Path('/var/lock/kk-car-network-health.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        state = read_json(STATE)
        # Preserve per-boot action budgets through service restarts.
        started = identity()
        append_event(dict(**started, event='service_start'))
        next_tick = 0
        while True:
            config = settings()
            requested = REQUEST.exists()
            if time.monotonic() >= next_tick or requested or state.get('revision') != config['revision']:
                cycle_started = time.monotonic()
                REQUEST.unlink(missing_ok=True)
                try:
                    state = step(config, state)
                except Exception:
                    # A collector failure stays unknown; it is never grounds for recovery.
                    atomic(CACHE, dict(**identity(), enabled=config['settings']['enabled'], error='collector_error', groups={}))
                    append_event(dict(**identity(), event='collector_error'))
                next_tick = max(time.monotonic() + 1, cycle_started + config['settings']['interval_seconds'])
            time.sleep(2)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    try:
        mode = sys.argv[1] if len(sys.argv) > 1 else 'status'
        if mode == 'run':
            run()
        elif mode == 'status':
            print(json.dumps(status(), ensure_ascii=False))
        elif mode == 'save':
            print(json.dumps(save(json.loads(sys.argv[2])), ensure_ascii=False))
        elif mode == 'check':
            REQUEST.touch(mode=0o600)
            print(json.dumps(dict(ok=True, accepted=True)))
        elif mode == 'once':
            # Deployment smoke test is explicitly read-only.
            with Path('/var/lock/kk-car-network-health.lock').open('a') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    print(json.dumps(dict(ok=False, error='守护服务正在运行，请通过页面立即探测'), ensure_ascii=False))
                    sys.exit(1)
                step(settings(), read_json(STATE), allow_recovery=False)
            print(json.dumps(status(), ensure_ascii=False))
        else:
            raise ValueError('不支持的操作')
    except (ValueError, OSError, IndexError) as exc:
        print(json.dumps(dict(ok=False, error=str(exc)), ensure_ascii=False))
        sys.exit(1)
