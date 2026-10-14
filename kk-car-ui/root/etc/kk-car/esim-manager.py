#!/usr/bin/python3
"""Secondary DJI eSIM profiles: read, selected enable, and guarded rotation.

No data, delete, disable, or download command is exposed. ICCIDs are only
held in memory while calling lpac; persistent preferences use SHA-256 tokens.
"""
import fcntl
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

from esim_bridge import run, secondary_tty

PRIVATE = Path('/etc/kk-car/private')
CONFIG = PRIVATE / 'esim-secondary.json'
STATE = PRIVATE / 'esim-switch-state.json'
LOCK = '/tmp/kk-car-esim-at.lock'
OPERATION_LOCK = '/tmp/kk-car-esim-operation.lock'
REQUEST = Path('/tmp/kk-car-esim-request/config.json')


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def save(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.new')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, ensure_ascii=False, separators=(',', ':'))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def profiles():
    data = run(['profile', 'list'])
    if not isinstance(data, list):
        raise RuntimeError('eSIM 配置列表格式异常')
    result = []
    for item in data:
        iccid = str(item.get('iccid') or '')
        if not re.fullmatch(r'[0-9]{18,22}', iccid):
            raise RuntimeError('eSIM 配置标识异常')
        result.append({
            'iccid': iccid,
            'token': hashlib.sha256(iccid.encode('ascii')).hexdigest(),
            'last4': iccid[-4:],
            'name': str(item.get('profileNickname') or item.get('profileName') or '')[:60],
            'provider': str(item.get('serviceProviderName') or '')[:60],
            'enabled': str(item.get('profileState') or '').lower() == 'enabled'
        })
    if sum(item['enabled'] for item in result) > 1:
        raise RuntimeError('卡片报告多个启用配置，已停止自动操作')
    return result


def public_profiles(items):
    return [{key: item[key] for key in ('token', 'last4', 'name', 'provider', 'enabled')}
            for item in items]


def secondary_network_devices():
    devices = []
    for net in Path('/sys/class/net').glob('*'):
        try:
            node = (net / 'device').resolve()
            for parent in (node, *node.parents):
                vendor = parent / 'idVendor'
                product = parent / 'idProduct'
                if vendor.exists() and product.exists():
                    if vendor.read_text().strip() == '2ca3' and product.read_text().strip() == '4006':
                        devices.append(net.name)
                    break
        except OSError:
            continue
    return devices


def status():
    config = load(CONFIG)
    result = {'ok': True, 'present': False, 'sms_only': True,
              'data_devices': secondary_network_devices(),
              'auto': config.get('auto') is True,
              'interval_minutes': config.get('interval_minutes', 60),
              'rotation': config.get('rotation', []),
              'last_switch': load(STATE).get('at'), 'profiles': []}
    try:
        secondary_tty()
    except RuntimeError as error:
        result['error'] = str(error)
        return result
    result['present'] = True
    try:
        result['profiles'] = public_profiles(profiles())
    except RuntimeError as error:
        result['error'] = str(error)
    return result


def do_switch(token):
    if not re.fullmatch(r'[0-9a-f]{64}', token or ''):
        raise RuntimeError('配置选择无效')
    before = profiles()
    if len(before) < 2:
        raise RuntimeError('卡内只有一个配置，不能切卡')
    target = next((item for item in before if item['token'] == token), None)
    previous = next((item for item in before if item['enabled']), None)
    if not target or not previous:
        raise RuntimeError('未找到目标或当前配置')
    if target['enabled']:
        return {'ok': True, 'changed': False, 'active': token}
    try:
        run(['profile', 'enable', target['iccid']], deadline_seconds=90)
    except RuntimeError:
        # A timeout may mean that the card committed the change. Verify first.
        pass
    for _ in range(4):
        try:
            after = profiles()
            if any(item['token'] == token and item['enabled'] for item in after):
                save(STATE, {'at': int(time.time()), 'token': token})
                return {'ok': True, 'changed': True, 'active': token}
        except RuntimeError:
            pass
        time.sleep(3)
    # Re-enable the previously verified profile if a switch was not confirmed.
    try:
        run(['profile', 'enable', previous['iccid']], deadline_seconds=90)
    except RuntimeError:
        pass
    raise RuntimeError('切卡未确认，已尝试恢复原配置；请手动检查卡片状态')


def save_config():
    request = load(REQUEST)
    auto = request.get('auto')
    interval = request.get('interval_minutes')
    rotation = request.get('rotation')
    if type(auto) is not bool or type(interval) is not int or not 30 <= interval <= 1440:
        raise RuntimeError('自动切卡设置无效')
    if not isinstance(rotation, list) or len(rotation) > 8 or len(set(rotation)) != len(rotation):
        raise RuntimeError('轮换列表无效')
    if not all(isinstance(token, str) and re.fullmatch(r'[0-9a-f]{64}', token) for token in rotation):
        raise RuntimeError('配置标识无效')
    found = {item['token'] for item in profiles()}
    if any(token not in found for token in rotation):
        raise RuntimeError('卡内配置已变化，请刷新后再保存')
    if auto and (len(rotation) < 2 or not any(item['enabled'] and item['token'] in rotation for item in profiles())):
        raise RuntimeError('自动切卡需要至少两个配置，且包含当前启用的配置')
    save(CONFIG, {'auto': auto, 'interval_minutes': interval, 'rotation': rotation})
    if auto and not load(STATE).get('at'):
        current = next((item for item in profiles() if item['enabled']), None)
        save(STATE, {'at': int(time.time()), 'token': current['token'] if current else None})
    return {'ok': True}


def tick():
    config = load(CONFIG)
    if config.get('auto') is not True:
        return {'ok': True, 'skipped': 'disabled'}
    interval = config.get('interval_minutes')
    rotation = config.get('rotation')
    if type(interval) is not int or not 30 <= interval <= 1440 or not isinstance(rotation, list) or len(rotation) < 2:
        raise RuntimeError('自动切卡设置无效')
    state = load(STATE)
    now = int(time.time())
    if not state.get('at'):
        current = next((item for item in profiles() if item['enabled']), None)
        save(STATE, {'at': now, 'token': current['token'] if current else None})
        return {'ok': True, 'skipped': 'initialized'}
    if now - int(state['at']) < interval * 60:
        return {'ok': True, 'skipped': 'waiting'}
    current = next((item for item in profiles() if item['enabled']), None)
    if not current or current['token'] not in rotation:
        raise RuntimeError('当前配置不在轮换表内，已停止自动切换')
    target = rotation[(rotation.index(current['token']) + 1) % len(rotation)]
    return do_switch(target)


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ''
    if action not in ('status', 'switch', 'save', 'tick'):
        raise RuntimeError('不支持的操作')
    with open(OPERATION_LOCK, 'a+') as operation:
        if action in ('switch', 'tick'):
            try:
                fcntl.flock(operation, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError('副卡正在归档短信，请稍后切卡')
        return locked_action(action)


def locked_action(action):
    with open(LOCK, 'a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('副卡正在执行短信或切卡操作')
        if action == 'status':
            return status()
        if action == 'switch':
            return do_switch(sys.argv[2] if len(sys.argv) == 3 else '')
        if action == 'save':
            return save_config()
        return tick()


if __name__ == '__main__':
    try:
        print(json.dumps(main(), ensure_ascii=False, separators=(',', ':')))
    except (OSError, RuntimeError, ValueError) as error:
        print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False))
        sys.exit(1)
