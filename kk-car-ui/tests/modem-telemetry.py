#!/usr/bin/env python3
"""Mock USB/QMI discovery locally; run pure parser fixtures on the router via stdin.

No live modem is queried, no device files/config are written, and no network
connection is started. KK_CAR_TEST_HOST can select another ucode-equipped host.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ETC = ROOT / 'kk-car-ui/root/etc/kk-car'

with tempfile.TemporaryDirectory(prefix='kkcar-modem-test-') as temporary:
    base = Path(temporary)
    sysfs, dev, bindir = (base / name for name in ['sys', 'dev', 'bin'])
    (sysfs / 'class/usbmisc').mkdir(parents=True)
    (sysfs / 'class/net').mkdir(parents=True)
    dev.mkdir(); bindir.mkdir()
    driver = sysfs / 'bus/usb/drivers/qmi_wwan'
    driver.mkdir(parents=True)
    usb = sysfs / 'devices/usb1/1-1'
    usb.mkdir(parents=True)
    (usb / 'idVendor').write_text('2ca3\n')
    (usb / 'idProduct').write_text('4006\n')
    (usb / 'product').write_text('DJI USB Modem\n')
    def interface(number, index):
        iface = usb / ('1-1:1.' + str(number))
        iface.mkdir()
        (iface / 'bInterfaceNumber').write_text(f'{number:02x}\n')
        (iface / 'driver').symlink_to(driver)
        control = sysfs / f'class/usbmisc/cdc-wdm{index}'
        control.mkdir(); (control / 'device').symlink_to(iface)
        net = sysfs / f'class/net/wwan{index}'
        net.mkdir(); (net / 'device').symlink_to(iface)
        (net / 'statistics').mkdir()
        for direction, value in [('rx', 1234), ('tx', 5678)]:
            (net / f'statistics/{direction}_bytes').write_text(str(value))
        return control
    # A mistaken dynamic binding can expose earlier cdc-wdm/wwan nodes.
    interface(1, 0); correct = interface(4, 7)
    mock = bindir / 'uqmi'
    mock.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$KK_CAR_TEST_LOG"
case "$*" in
  *--get-signal-info) echo '{"type":"lte","rssi":-66,"rsrp":-93,"rsrq":-10,"snr":13.4}' ;;
  *--get-data-status) echo '"connected"' ;;
  *--get-serving-system) echo '{"registration":"registered","plmn_description":"Example Mobile","roaming":false}' ;;
  *--get-capabilities) echo '{"networks":["lte"]}' ;;
  *--uim-get-sim-state) echo '{"card_application_state":"ready","pin1_status":"disabled"}' ;;
  *) exit 1 ;;
esac
''')
    mock.chmod(0o700)
    env = dict(os.environ, KK_CAR_SYSFS_ROOT=str(sysfs), KK_CAR_DEV_ROOT=str(dev),
               KK_CAR_TEST_LOG=str(base/'calls'), PATH=str(bindir)+':'+os.environ['PATH'])
    def read():
        return subprocess.run(['sh', str(ETC/'modem-qmi-read.sh')], env=env,
                              text=True, capture_output=True, timeout=15)
    result = read()
    assert result.returncode == 0, result
    qmi_raw = result.stdout
    calls = (base/'calls').read_text().splitlines()
    assert len(calls) == 5 and all(str(dev/'cdc-wdm7') in call for call in calls), calls
    assert 'network_device=wwan7' in qmi_raw
    discovery = subprocess.run(['sh', str(ETC/'modem-qmi-read.sh'), 'discover'], env=env,
                               text=True, capture_output=True, timeout=5)
    assert discovery.returncode == 0 and 'network_device=wwan7' in discovery.stdout
    assert (base/'calls').read_text().splitlines() == calls, 'Discovery must not query QMI while netifd initializes'
    (usb/'idVendor').write_text('2c7c\n'); (usb/'idProduct').write_text('0125\n')
    assert read().returncode == 0, 'Standard Quectel identity must also work'
    # One unresponsive QMI request must not block later signal/SIM requests.
    mock.write_text(mock.read_text().replace("echo '\"connected\"'", "exec python3 -c 'import time; time.sleep(30)'"))
    started = time.monotonic()
    stalled = read()
    assert stalled.returncode == 0 and time.monotonic()-started < 12, stalled
    assert 'qmi_sim=' in stalled.stdout, 'Collector must continue after a timed-out data query'
    (correct/'device').unlink()
    assert read().returncode == 3, 'Wrong interface must never be selected'

def raw(**values):
    return '\n'.join(key+'='+ (json.dumps(value) if key.startswith('qmi_') else str(value))
                     for key, value in values.items())

cases = [
    [qmi_raw, 0],
    [raw(transport='QMI', kkcar_probe=1, qmi_signal={'type':'lte','rsrp':-108}, qmi_data='disconnected'), 0],
    [raw(transport='QMI', kkcar_probe=1, qmi_capabilities={'networks':['lte']}, qmi_data='Request timed out'), 0],
    [raw(transport='QMI', kkcar_probe=1, qmi_signal={'type':'lte','rsrp':-200,'rssi':999,'rsrq':-90,'snr':100}, cellular_rx='-1', cellular_tx='nan'), 0],
    [raw(transport='QMI', kkcar_probe=1, qmi_data='connected'), 124],
    ['transport=QMI\nkkcar_probe=1\nqmi_signal={broken\nqmi_data="Request timed out"', 0],
    [raw(transport='QMI', kkcar_probe=1, qmi_data='disconnected', qmi_sim={'card_application_state':'pin1_or_upin_required'}), 0],
    [raw(transport='QMI', kkcar_probe=1, qmi_data='disconnected', qmi_sim={'card_application_state':'absent'}), 0],
    [raw(transport='ADB', kkcar_probe=1, management_ip='192.168.1.1', uptime='3.5', network_provider='Example Mobile', network_type='LTE', ppp_status='ppp_connected', signalbar=4, lte_rsrp=-94, rssi=-70, simcard_roam='Home', realtime_time=2, cellular_rx=123, cellular_tx=456), 0],
    [raw(transport='ADB', kkcar_probe=1, management_ip='203.0.113.2', uptime=5, ppp_status='disconnected'), 0],
    [raw(transport='ADB', kkcar_probe=1, uptime='not a number'), 0],
    ['transport=QMI\nkkcar_probe=1\nqmi_signal="ERROR"\nqmi_data=\nqmi_serving="ERROR"\nqmi_capabilities="ERROR"', 0],
    [stalled.stdout, 0],
]
source = (ETC/'modem-parse.uc').read_text().split('// CLI entry point;')[0]
source += '\nfor (let fixture in '+json.dumps(cases)+') printf("%J\\n", parse_modem(fixture[0], fixture[1], 42));\n'
command = ['ssh', '-i', str(ROOT/'work/private/pi-admin'), '-o', 'IdentitiesOnly=yes',
           '-o', 'UserKnownHostsFile='+str(ROOT/'work/pi-reflash-known-hosts'),
           '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
           'root@'+os.environ.get('KK_CAR_TEST_HOST', '192.168.88.1'), 'ucode -']
result = subprocess.run(command, input=source, text=True, capture_output=True, timeout=15)
assert result.returncode == 0, result.stderr
rows = [json.loads(line) for line in result.stdout.splitlines()]
assert len(rows) == len(cases), rows
assert rows[0]['online'] and rows[0]['connected'] and rows[0]['sim_state']=='ready', rows[0]
assert rows[0]['rsrp']==-93 and rows[0]['snr']==13.4 and rows[0]['rx']==1234, rows[0]
assert rows[0]['roaming'] is False, rows[0]
assert rows[1]['online'] and rows[1]['connected'] is False and rows[1]['sim_state']=='unknown', rows[1]
assert rows[2]['online'] and rows[2]['connected'] is None, rows[2]
assert all(rows[3][key] is None for key in ['rssi','rsrp','rsrq','snr','rx','tx']), rows[3]
assert not rows[4]['online'] and not rows[5]['online'], rows[4:6]
assert rows[6]['sim_state']=='pin_required' and rows[7]['sim_state']=='absent', rows[6:8]
assert rows[8]['online'] and rows[8]['connected'] and rows[8]['management_ip']=='192.168.1.1', rows[8]
assert rows[8]['uptime']==3.5 and rows[8]['rx']==123 and rows[8]['bars']==4, rows[8]
assert rows[9]['management_ip'] is None and rows[9]['connected'] is False, rows[9]
assert not rows[10]['online'], rows[10]
assert not rows[11]['online'], rows[11]
assert rows[12]['online'] and rows[12]['connected'] is None and rows[12]['sim_state']=='ready', rows[12]
assert not any(key in json.dumps(rows) for key in ['pin1_status','verify_tries','imei','imsi','phone']), rows
source = (ETC/'modem-parse.uc').read_text().split('// CLI entry point;')[0]
source += '''
let at={timestamp:42,rsrp_dbm:-85,rsrq_db:-8,rssi_dbm:-65,sinr_db:16,
    technology:'FDD LTE',band:'LTE B3',sim_pin_state:'ready',cell_id:'private-cell'};
let waiting=parse_modem('transport=QMI\\nkkcar_probe=1\\ncollector_state=wan_initializing',0,42);
let merged=merge_at(waiting,at,43);
if (!merged.online || merged.connected!==null || merged.rsrp!=-85 || merged.signal_source!='AT' || merged.bars!=4 || merged.cell_id) exit(1);
if (merge_at(parse_modem('transport=QMI',124,42),at,118).online) exit(2);
if (merge_at(parse_modem('transport=QMI',124,42),at,41).online) exit(3);
print('PASS AT fallback without claiming data connection, stale and future rejection\\n');
'''
result = subprocess.run(command, input=source, text=True, capture_output=True, timeout=15)
assert result.returncode == 0, result.stderr or result.stdout
print(result.stdout.strip())
print('PASS: both USB identities, IF04/node association, QMI connected/disconnected/unknown, SIM states, bounds, privacy and F30A compatibility')
