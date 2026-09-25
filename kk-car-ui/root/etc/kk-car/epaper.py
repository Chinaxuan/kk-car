#!/usr/bin/env python3
"""KK-Car four-key console for the Waveshare 2.7-inch e-Paper HAT V2.

Hardware commands follow Waveshare's epd2in7_V2 reference. The vendor's
four-gray LUT is kept separately with its license notice in epaper_lut.py.
"""

import argparse
import fcntl
import json
import os
import struct
import subprocess
import time
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont
from epaper_lut import LUT_DATA_4GRAY

WIDTH, HEIGHT = 264, 176
KEYS = (5, 6, 13, 19)  # KEY1=home/back, KEY2=up, KEY3=down, KEY4=menu/confirm
PAGES = ('OVERVIEW', 'CELLULAR', 'VPN / DATA', 'UPS / POWER', 'SYSTEM')
MENU = (
    ('diagnose', 'Run network check'),
    ('modem_refresh', 'Refresh LTE status'),
    ('vpn_restart', 'Reconnect VPN'),
    ('vpn_toggle', 'VPN start / pause'),
    ('vpn_auto', 'VPN auto on boot'),
    ('wifi_band', 'Wi-Fi 2.4 / 5 GHz'),
    ('port_mode', 'Ethernet LAN / WAN'),
    ('refresh', 'Screen refresh time'),
)
REFRESH_CHOICES = (180, 300, 600)
MAX_QUICK_UPDATES = 3  # clean sooner than the vendor's five-update upper guidance
STATUS_PATH = Path('/tmp/kk-car-epaper-status.json')
SETTINGS_PATH = Path('/etc/kk-car/private/epaper-settings.json')


def ubus(method, payload=None, timeout=8):
    try:
        command = ['ubus', '-t', str(timeout), 'call', 'kkcar', method]
        if payload is not None:
            command.append(json.dumps(payload, separators=(',', ':')))
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout + 2)
        if result.returncode:
            return {'ok': False, 'error': 'Control service unavailable'}
        return json.loads(result.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return {'ok': False, 'error': 'Control service unavailable'}


def read_status():
    car = ubus('status', timeout=8)
    try:
        result = subprocess.run(['ubus', '-t', '8', 'call', 'kkups', 'status'],
                                capture_output=True, text=True, timeout=10)
        ups = json.loads(result.stdout) if result.returncode == 0 else {}
    except (OSError, ValueError, subprocess.SubprocessError):
        ups = {}
    return car, ups


def load_refresh():
    try:
        value = json.loads(SETTINGS_PATH.read_text()).get('refresh_seconds')
        return value if value in REFRESH_CHOICES else 180
    except (OSError, ValueError, TypeError):
        return 180


def save_refresh(value):
    SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    staging = SETTINGS_PATH.with_suffix('.tmp')
    staging.write_text(json.dumps({'refresh_seconds': value}) + '\n')
    staging.chmod(0o600)
    staging.replace(SETTINGS_PATH)


def number(v, suffix='', decimals=0):
    if not isinstance(v, (int, float)) or isinstance(v, bool):
        return '--'
    return f'{v:.{decimals}f}{suffix}'


def age(v):
    if not isinstance(v, (int, float)) or v < 0:
        return '--'
    v = int(v)
    return f'{v // 3600}h {v % 3600 // 60}m' if v >= 3600 else f'{v // 60}m {v % 60}s'


def mib(v):
    return number(v / 1048576, ' MiB', 1) if isinstance(v, (int, float)) else '--'


def fresh_data(car, ups):
    wan, vpn = car.get('wan') or {}, car.get('vpn') or {}
    ping, modem = car.get('vpn_ping') or {}, car.get('modem') or {}
    ping_age = (car.get('uptime') or 0) - (ping.get('uptime') or 0)
    if not vpn.get('connected') or not ping.get('timestamp') or not 0 <= ping_age <= 25:
        ping = {}
    modem_age = (car.get('timestamp') or 0) - (modem.get('timestamp') or 0)
    if not modem.get('online') or not 0 <= modem_age < 75:
        modem = {}
    if not ups.get('ok'):
        ups = {}
    return wan, vpn, ping, modem, ups


def metrics(page, car, ups, rates):
    wan, vpn, ping, modem, ups = fresh_data(car, ups)
    uplink, wifi = car.get('uplink') or {}, car.get('wifi') or {}
    eth, power = car.get('ethernet') or {}, car.get('power') or {}
    battery, output, inputs = ups.get('battery') or {}, ups.get('output') or {}, ups.get('input') or {}
    source = 'WIRED' if uplink.get('active') == 'ethernet' else 'LTE'
    source = source if wan.get('up') else 'DOWN'
    volts = number(output.get('pogo_mv') / 1000, ' V', 2) if isinstance(output.get('pogo_mv'), (int, float)) else '--'
    batt = number(battery.get('percent'), ' %')
    temp = number(car.get('temperature'), ' C', 1)
    ping_ms = number(ping.get('avg_ms'), ' ms', 1)
    loss = number(ping.get('loss_percent'), ' %')
    net = modem.get('network') or '--'
    band = modem.get('band') or '--'
    peers = wifi.get('clients') if isinstance(wifi.get('clients'), int) else None
    uptime = car.get('uptime')
    if page == 0:
        return (
            ('PING / LOSS', f'{number(ping.get("avg_ms"), "ms", 0)}/{number(ping.get("loss_percent"), "%")}' if ping else '--'), ('RSRP', number(modem.get('rsrp'), ' dBm')),
            ('UPLINK', source), ('SINR', number(modem.get('snr'), ' dB', 1)),
            ('VPN', 'ONLINE' if vpn.get('connected') else 'OFFLINE'), ('BAND', str(band)),
            ('DOWN', number(rates.get('down'), ' Mbps', 2)), ('UPS OUTPUT', volts),
            ('UP', number(rates.get('up'), ' Mbps', 2)), ('CLIENTS', number(peers)),
        )
    if page == 1:
        return (
            ('NETWORK', net), ('OPERATOR', modem.get('operator') or '--'),
            ('BAND', str(band)), ('SIM', modem.get('sim_state') or '--'),
            ('RSRP', number(modem.get('rsrp'), ' dBm')), ('RSRQ', number(modem.get('rsrq'), ' dB')),
            ('SINR', number(modem.get('snr'), ' dB', 1)), ('RSSI', number(modem.get('rssi'), ' dBm')),
            ('REGISTERED', str(modem.get('registration') or '--')), ('SESSION', age(modem.get('connection_uptime'))),
        )
    if page == 2:
        return (
            ('TUNNEL', 'ONLINE' if vpn.get('connected') else 'OFFLINE'), ('AUTO START', 'ON' if vpn.get('auto') else 'OFF'),
            ('ROUTE', 'READY' if vpn.get('route') else 'MISSING'), ('UPTIME', age(vpn.get('age')) if vpn.get('connected') else '--'),
            ('VPN RTT', ping_ms), ('PING LOSS', loss),
            ('DOWN', number(rates.get('down'), ' Mbps', 2)), ('UP', number(rates.get('up'), ' Mbps', 2)),
            ('WAN RX', mib(wan.get('rx'))), ('WAN TX', mib(wan.get('tx'))),
        )
    if page == 3:
        external = inputs.get('external')
        origin = 'EXTERNAL' if external is True else 'BATTERY' if external is False else '--'
        millivolts = battery.get('millivolts')
        return (
            ('SOURCE', origin), ('PI POWER', 'LOW' if power.get('undervoltage') else 'OK' if power.get('known') else '--'),
            ('BATTERY', batt), ('UPS OUTPUT', volts),
            ('BATTERY V', number(millivolts / 1000, ' V', 2) if isinstance(millivolts, (int, float)) else '--'), ('BATTERY T', number(battery.get('temperature_c'), ' C', 1)),
            ('USB-C IN', number(inputs.get('usb_c_mv') / 1000, ' V', 1) if isinstance(inputs.get('usb_c_mv'), (int, float)) else '--'), ('MICRO IN', number(inputs.get('micro_usb_mv') / 1000, ' V', 1) if isinstance(inputs.get('micro_usb_mv'), (int, float)) else '--'),
            ('PI TEMP', temp), ('THROTTLED', 'YES' if power.get('throttled') else 'NO' if power.get('known') else '--'),
        )
    memory = car.get('memory') or {}
    free = memory.get('available')
    auto = car.get('diagnostics_auto') or {}
    return (
        ('WI-FI SSID', wifi.get('ssid') or '--'), ('CLIENTS', number(peers)),
        ('WI-FI BAND', (wifi.get('band') or '--').upper()), ('CHANNEL', str(wifi.get('channel') or '--')),
        ('ETH PORT', (eth.get('mode') or '--').upper()), ('ETH LINK', 'UP' if eth.get('carrier') else 'DOWN'),
        ('PI TEMP', temp), ('MEM FREE', mib(free)),
        ('UPTIME', age(uptime)), ('AUTO CHECK', 'ON' if auto.get('enabled') else 'OFF'),
    )


def label_for(item, car, refresh):
    if item == 'vpn_toggle':
        return 'Pause VPN' if (car.get('vpn') or {}).get('running') else 'Start VPN'
    if item == 'vpn_auto':
        return 'VPN autostart: ON' if (car.get('vpn') or {}).get('auto') else 'VPN autostart: OFF'
    if item == 'wifi_band':
        return 'Wi-Fi band: ' + str((car.get('wifi') or {}).get('band') or '--').upper()
    if item == 'port_mode':
        return 'Ethernet: ' + str((car.get('ethernet') or {}).get('mode') or '--').upper()
    if item == 'refresh':
        return 'Refresh every ' + str(refresh // 60) + ' min'
    return dict(MENU)[item]


def perform(item, car, refresh):
    if item == 'refresh':
        next_value = REFRESH_CHOICES[(REFRESH_CHOICES.index(refresh) + 1) % len(REFRESH_CHOICES)]
        save_refresh(next_value)
        return {'ok': True, 'message': f'Screen refresh: {next_value // 60} min', 'refresh': next_value}
    if not car or car.get('ok') is False or car.get('busy'):
        return {'ok': False, 'error': 'Control service busy/unavailable'}
    if item in ('diagnose', 'modem_refresh', 'vpn_restart'):
        return ubus('action', {'action': item})
    if item == 'vpn_toggle':
        action = 'vpn_stop' if (car.get('vpn') or {}).get('running') else 'vpn_start'
        return ubus('action', {'action': action})
    if item == 'vpn_auto':
        return ubus('auto_connect', {'enabled': not bool((car.get('vpn') or {}).get('auto'))})
    if item == 'wifi_band':
        wifi = car.get('wifi') or {}
        if not wifi.get('ssid') or wifi.get('band') not in ('2g', '5g'):
            return {'ok': False, 'error': 'Current Wi-Fi state unknown'}
        target = '2g' if wifi['band'] == '5g' else '5g'
        result = ubus('wifi_save', {'ssid': wifi['ssid'], 'password': '', 'band': target})
        result['target'] = target
        return result
    if item == 'port_mode':
        mode = (car.get('ethernet') or {}).get('mode')
        if mode not in ('lan', 'wan'):
            return {'ok': False, 'error': 'Current port mode unknown'}
        target = 'lan' if mode == 'wan' else 'wan'
        result = ubus('port_save', {'mode': target})
        result['target'] = target
        return result
    return {'ok': False, 'error': 'Unsupported setting'}


class Console:
    def __init__(self):
        self.view = 'pages'
        self.page = 0
        self.selected = 0
        self.item = None
        self.notice = ''
        self.pending = None
        self.refresh = load_refresh()

    def sync_pending(self, car):
        if self.view != 'pending' or not self.pending:
            return False
        if not car or car.get('ok') is False:
            return False
        field = 'wifi_pending' if self.pending['item'] == 'wifi_band' else 'port_pending'
        active = car.get(field) or {}
        if active.get('deadline'):
            self.pending['deadline'] = active['deadline']
            return False
        if time.time() > self.pending['deadline'] or not car.get('busy'):
            field = 'band' if self.pending['item'] == 'wifi_band' else 'mode'
            current = (car.get('wifi') or {}) if self.pending['item'] == 'wifi_band' else (car.get('ethernet') or {})
            self.notice = 'Setting kept' if current.get(field) == self.pending['target'] else 'Auto rollback complete'
            self.view = 'result'
            self.pending = None
            return True
        return False

    def handle(self, key, duration, car):
        """Return fast/partial if the key changes the visible view, else None."""
        if duration < .04:
            return None
        if self.view == 'pages':
            if key == 0:
                self.page = 0
            elif key == 1:
                self.page = (self.page - 1) % len(PAGES)
            elif key == 2:
                self.page = (self.page + 1) % len(PAGES)
            else:
                self.view = 'menu'
            return 'fast'
        if self.view == 'menu':
            if key == 0:
                self.view = 'pages'
                self.page = 0
                return 'gray'
            if key in (1, 2):
                self.selected = (self.selected + (-1 if key == 1 else 1)) % len(MENU)
                return 'partial'
            self.item = MENU[self.selected][0]
            if self.item in ('diagnose', 'modem_refresh', 'refresh'):
                return self.execute(car)
            self.view = 'confirm'
            return 'fast'
        if self.view == 'confirm':
            if key == 0:
                self.view = 'menu'
                return 'fast'
            if key == 3 and duration >= 1.5:
                return self.execute(car)
            return None
        if self.view == 'pending':
            if key != 3 or duration < 1.5:
                return None
            if time.time() >= self.pending['deadline']:
                self.notice = 'Deadline passed; waiting for rollback'
                return 'partial'
            if self.pending['item'] == 'wifi_band':
                wifi = car.get('wifi') or {}
                frequency = wifi.get('frequency') or 0
                on_target = frequency >= 5000 if self.pending['target'] == '5g' else 2300 <= frequency < 2500
                ready = wifi.get('enabled') and wifi.get('band') == self.pending['target'] and on_target
                method = 'wifi_confirm'
            else:
                ready = (car.get('ethernet') or {}).get('mode') == self.pending['target']
                method = 'port_confirm'
            if time.time() - self.pending['started'] < 10 or not ready:
                self.notice = 'Target state not ready; wait'
                return 'partial'
            result = ubus(method)
            self.notice = 'Setting confirmed' if result.get('ok') else str(result.get('error') or 'Confirm failed')
            if result.get('ok'):
                self.view = 'result'
                self.pending = None
            return 'fast'
        if self.view == 'result':
            if key == 0:
                self.view = 'pages'
            else:
                self.view = 'menu'
            return 'fast'
        return None

    def execute(self, car):
        try:
            result = perform(self.item, car, self.refresh)
        except OSError:
            result = {'ok': False, 'error': 'Could not save screen setting'}
        if 'refresh' in result:
            self.refresh = result['refresh']
        if result.get('ok') and result.get('pending') and self.item in ('wifi_band', 'port_mode'):
            self.pending = {'item': self.item, 'target': result['target'], 'started': time.time(),
                            'deadline': result['pending']['deadline']}
            self.notice = 'Check connection, then hold KEY4'
            self.view = 'pending'
        else:
            self.notice = str(result.get('message') or result.get('error') or
                              ('Job started' if result.get('accepted') else 'Setting saved'))
            self.view = 'result'
        return 'fast'


@lru_cache(maxsize=8)
def font(size):
    face = Path(__file__).resolve().parent / 'fonts' / 'Blinker-SemiBold.ttf'
    try:
        return ImageFont.truetype(str(face), size)
    except OSError:
        return ImageFont.load_default(size=size)


class CrispDraw:
    """Keep text at solid ink levels instead of dithered anti-aliased edges."""

    def __init__(self, image):
        self.image = image
        self.draw = ImageDraw.Draw(image)

    def __getattr__(self, name):
        return getattr(self.draw, name)

    def text(self, xy, content, fill=0, font=None):
        mask = Image.new('L', self.image.size, 0)
        ImageDraw.Draw(mask).text(xy, content, fill=255, font=font)
        self.image.paste(fill, (0, 0), mask.point(lambda value: 255 if value >= 128 else 0).convert('1'))


def battery_header(ups):
    if not ups.get('ok'):
        return '--', 'POWER --'
    battery = ups.get('battery') or {}
    level = number(battery.get('percent'), '%')
    sensor = ((ups.get('sensors') or {}).get('battery') or {})
    current = sensor.get('current_ma') if sensor.get('detected') else None
    if isinstance(current, (int, float)) and not isinstance(current, bool):
        state = 'CHARGING' if current > 100 else 'DISCHARGE' if current < -100 else 'IDLE'
    else:
        external = (ups.get('input') or {}).get('external')
        state = 'EXT POWER' if external is True else 'ON BAT' if external is False else 'POWER --'
    return level, state


def fitted(draw, text, face, width):
    text = str(text)
    if draw.textlength(text, font=face) <= width:
        return text
    while text and draw.textlength(text + '..', font=face) > width:
        text = text[:-1]
    return text + '..'


def render(console, car, ups, rates=None):
    """Render an actual four-level 264x176 frame without touching the HAT."""
    rates = rates or {}
    image = Image.new('L', (WIDTH, HEIGHT), 255)
    draw = CrispDraw(image)
    small, value_font, title_font = font(11), font(14), font(19)
    draw.rectangle((0, 0, WIDTH - 1, 31), fill=0)
    title = PAGES[console.page] if console.view == 'pages' else {
        'menu': 'SETTINGS', 'confirm': 'CONFIRM', 'pending': 'PENDING', 'result': 'RESULT'}[console.view]
    draw.text((7, 0), 'KK-CAR', fill=255, font=title_font)
    stamp = time.strftime('%m/%d %H:%M')
    draw.text(((WIDTH - draw.textlength(stamp, font=font(14))) / 2, 2), stamp,
              fill=255, font=font(14))
    charge, state = battery_header(ups)
    draw.text((WIDTH - 7 - draw.textlength(charge, font=font(14)), 2), charge,
              fill=255, font=font(14))
    draw.text((7, 18), fitted(draw, title, small, 205), fill=255, font=small)
    page_no = f'{console.page + 1} / {len(PAGES)}' if console.view == 'pages' else 'SET'
    draw.text(((WIDTH - draw.textlength(page_no, font=small)) / 2, 18), page_no,
              fill=255, font=small)
    draw.text((WIDTH - 7 - draw.textlength(state, font=small), 18), state,
              fill=255, font=small)
    controls = None
    if console.view == 'pages':
        items = metrics(console.page, car, ups, rates)
        for i, (label, value) in enumerate(items):
            row, col = divmod(i, 2)
            x, y = 7 + col * 130, 33 if row == 0 else 67 + (row - 1) * 23
            draw.text((x, y), fitted(draw, label, small, 120), fill=0, font=small)
            face = font(20) if console.page == 0 and row == 0 else value_font
            draw.text((x, y + (7 if row == 0 else 8)),
                      fitted(draw, value, face, 119), fill=0, font=face)
            if row < 4:
                rule_y = 65 if row == 0 else y + 23
                draw.line((x, rule_y, x + 120, rule_y), fill=192)
        footer = '1 HOME  2 UP  3 DOWN  4 SET'
        controls = ('1 HOME', '2 UP', '3 DOWN', '4 SET')
    elif console.view == 'menu':
        start = min(max(console.selected - 3, 0), max(0, len(MENU) - 7))
        for slot, index in enumerate(range(start, min(start + 7, len(MENU)))):
            y = 34 + slot * 18
            selected = index == console.selected
            if selected:
                draw.rectangle((4, y + 2, 6, y + 13), fill=0)
            draw.text((9, y), '>' if selected else f'{index + 1}.',
                      fill=0, font=value_font)
            item = MENU[index][0]
            draw.text((31, y), fitted(draw, label_for(item, car, console.refresh), value_font, 224),
                      fill=0, font=value_font)
        footer = '1 BACK  2 UP  3 DOWN  4 OK'
        controls = ('1 BACK', '2 UP', '3 DOWN', '4 OK')
    elif console.view == 'confirm':
        item = console.item
        target = ''
        if item == 'wifi_band':
            target = '2.4 GHz' if (car.get('wifi') or {}).get('band') == '5g' else '5 GHz'
        if item == 'port_mode':
            target = 'LAN' if (car.get('ethernet') or {}).get('mode') == 'wan' else 'WAN'
        lines = [label_for(item, car, console.refresh),
                 ('Target: ' + target) if target else 'Change current setting',
                 'Wi-Fi may disconnect' if item == 'wifi_band' else
                 'Network will reload' if item == 'port_mode' else
                 'Company access pauses' if item == 'vpn_toggle' else 'Confirm physical action',
                 'Auto rollback in 125s' if item in ('wifi_band', 'port_mode') else
                 'Applied after confirmation',
                 'Hold KEY4 for 2 seconds']
        for i, line in enumerate(lines):
            draw.text((9, 34 + i * 22), fitted(draw, line, value_font, 246), fill=0, font=value_font)
        footer = '1 CANCEL                 4 HOLD'
    elif console.view == 'pending':
        kind = console.pending['item']
        state = (car.get('wifi') or {}) if kind == 'wifi_band' else (car.get('ethernet') or {})
        label = 'Wi-Fi band' if kind == 'wifi_band' else 'Ethernet port'
        current = str(state.get('band' if kind == 'wifi_band' else 'mode') or '--').upper()
        lines = [f'{label}: {current}', f'Target: {console.pending["target"].upper()}',
                 'Rollback at ' + time.strftime('%H:%M:%S', time.localtime(console.pending['deadline'])),
                 f'AP clients: {(car.get("wifi") or {}).get("clients", "--")}',
                 'Check link before keeping', fitted(draw, console.notice, small, 245)]
        for i, line in enumerate(lines):
            draw.text((9, 34 + i * 20), fitted(draw, line, value_font if i < 5 else small, 246),
                      fill=0, font=value_font if i < 5 else small)
        footer = '4 HOLD TO KEEP; ELSE REVERT'
    else:
        draw.text((9, 40), fitted(draw, console.notice, value_font, 246), fill=0, font=value_font)
        job = car.get('job') or {}
        if job.get('state') == 'running':
            draw.text((9, 65), 'Working in background...', fill=0, font=value_font)
        draw.text((9, 100), 'Read status in dashboard', fill=0, font=value_font)
        footer = '1 HOME      2/3/4 SETTINGS'
    draw.rectangle((0, 159, WIDTH - 1, HEIGHT - 1), fill=0)
    if controls:
        for x in (67, 127, 198):
            draw.line((x, 162, x, 172), fill=255)
        for x, label in zip((7, 75, 135, 206), controls):
            draw.text((x, 160), label, fill=255, font=small)
    else:
        draw.text((7, 160), fitted(draw, footer, small, 249), fill=255, font=small)
    return image


class Paper:
    """SPI/GPIO port of the vendor V2 full, fast, partial and four-gray modes."""

    def __init__(self):
        import gpiod
        from gpiod.line import Bias, Direction, Value
        self.Value = Value
        settings = {
            17: gpiod.LineSettings(direction=Direction.OUTPUT, output_value=Value.ACTIVE),
            25: gpiod.LineSettings(direction=Direction.OUTPUT, output_value=Value.INACTIVE),
            18: gpiod.LineSettings(direction=Direction.OUTPUT, output_value=Value.INACTIVE),
            24: gpiod.LineSettings(direction=Direction.INPUT),
        }
        settings.update({pin: gpiod.LineSettings(direction=Direction.INPUT, bias=Bias.PULL_UP)
                         for pin in KEYS})
        self.gpio = gpiod.request_lines('/dev/gpiochip0', consumer='kk-car-epaper', config=settings)
        self.spi = os.open('/dev/spidev0.0', os.O_RDWR)
        fcntl.ioctl(self.spi, 0x40016B01, bytes([0]))
        fcntl.ioctl(self.spi, 0x40046B04, struct.pack('I', 4_000_000))
        self.mode = None
        self.last = None
        self.partials = 0
        self.fast_prepared = False
        self.touched = 0

    def pin(self, number, active):
        self.gpio.set_value(number, self.Value.ACTIVE if active else self.Value.INACTIVE)

    def busy(self):
        deadline = time.monotonic() + 20
        while self.gpio.get_value(24) == self.Value.ACTIVE:
            if time.monotonic() > deadline:
                raise TimeoutError('e-paper BUSY stayed high for 20 seconds')
            time.sleep(.02)

    def reset(self):
        self.pin(17, True)
        time.sleep(.2)
        self.pin(17, False)
        time.sleep(.002)
        self.pin(17, True)
        time.sleep(.2)

    def command(self, code, data=None):
        self.pin(25, False)
        os.write(self.spi, bytes([code]))
        if data is not None:
            self.pin(25, True)
            if isinstance(data, int):
                data = bytes([data])
            for offset in range(0, len(data), 2048):
                os.write(self.spi, data[offset:offset + 2048])

    def update(self, mode):
        self.command(0x22, mode)
        self.command(0x20)
        self.busy()

    def wake(self):
        self.pin(18, True)
        self.reset()
        self.busy()
        self.command(0x12)
        self.busy()
        self.touched = time.monotonic()

    def init_mono(self):
        self.wake()
        self.command(0x45, bytes((0, 0, 7, 1)))
        self.command(0x4F, bytes((0, 0)))
        self.command(0x11, 0x03)
        self.mode = 'mono'
        self.fast_prepared = False
        self.partials = 0

    def init_gray(self):
        self.wake()
        for cmd, data in ((0x74, 0x54), (0x7E, 0x3B), (0x01, bytes((7, 1, 0))),
                          (0x11, 0x03), (0x44, bytes((0, 0x15))),
                          (0x45, bytes((0, 0, 7, 1))), (0x3C, 0),
                          (0x2C, LUT_DATA_4GRAY[158]), (0x3F, LUT_DATA_4GRAY[153]),
                          (0x03, LUT_DATA_4GRAY[154]), (0x04, LUT_DATA_4GRAY[155:158]),
                          (0x32, LUT_DATA_4GRAY), (0x4E, 0), (0x4F, bytes((0, 0)))):
            self.command(cmd, data)
        self.busy()
        self.mode = 'gray'
        self.last = None
        self.partials = 0

    def prepare_fast(self):
        if self.fast_prepared:
            return
        self.command(0x18, 0x80)
        self.update(0xB1)
        self.command(0x1A, bytes((0x64, 0)))
        self.update(0x91)
        self.fast_prepared = True

    @staticmethod
    def portrait(image):
        return image.rotate(90, expand=True)

    @staticmethod
    def gray_planes(image):
        pixels = Paper.portrait(image).convert('L').tobytes()
        assert len(pixels) == 176 * 264
        one = bytearray(len(pixels) // 8)
        two = bytearray(len(pixels) // 8)
        for i, shade in enumerate(pixels):
            bit = 0x80 >> (i & 7)
            if shade < 64:  # black
                one[i >> 3] |= bit
                two[i >> 3] |= bit
            elif shade < 160:  # dark gray
                two[i >> 3] |= bit
            elif shade < 224:  # light gray
                one[i >> 3] |= bit
        return bytes(one), bytes(two)

    def display_gray(self, image):
        self.init_gray()
        one, two = self.gray_planes(image)
        self.command(0x24, one)
        self.command(0x26, two)
        self.update(0xC7)
        self.sleep()
        return 'gray'

    def full_mono(self, image):
        if self.mode != 'mono' or self.partials:
            self.init_mono()
        frame = self.portrait(image).convert('1')
        self.command(0x24, frame.tobytes())
        self.command(0x26, frame.tobytes())
        self.update(0xF7)
        self.last = frame
        self.partials = 0
        self.touched = time.monotonic()
        return 'full'

    def display_fast(self, image):
        if self.mode != 'mono' or self.partials >= MAX_QUICK_UPDATES:
            return self.full_mono(image)
        self.prepare_fast()
        frame = self.portrait(image).convert('1')
        self.command(0x24, frame.tobytes())
        self.command(0x26, frame.tobytes())
        self.update(0xC7)
        self.last = frame
        self.partials += 1
        self.touched = time.monotonic()
        return 'fast'

    def display_partial(self, image):
        if self.mode != 'mono' or self.last is None or self.partials >= MAX_QUICK_UPDATES:
            return self.display_fast(image)
        frame = self.portrait(image).convert('1')
        box = ImageChops.difference(frame.convert('L'), self.last.convert('L')).getbbox()
        if box is None:
            return 'unchanged'
        x0, y0, x1, y1 = box
        if (x1 - x0) * (y1 - y0) > 176 * 264 * .45:
            return self.display_fast(image)
        x0 = x0 // 8 * 8
        x1 = min(176, (x1 + 7) // 8 * 8)
        self.reset()
        self.command(0x3C, 0x80)
        self.command(0x44, bytes((x0 // 8, x1 // 8 - 1)))
        self.command(0x45, bytes((y0 & 255, y0 >> 8, (y1 - 1) & 255, (y1 - 1) >> 8)))
        self.command(0x4E, x0 // 8)
        self.command(0x4F, bytes((y0 & 255, y0 >> 8)))
        raw, stride = frame.tobytes(), 176 // 8
        section = b''.join(raw[y * stride + x0 // 8:y * stride + x1 // 8] for y in range(y0, y1))
        self.command(0x24, section)
        self.update(0xFF)
        self.last = frame
        self.partials += 1
        self.touched = time.monotonic()
        return 'partial'

    def display(self, image, mode):
        if mode == 'gray':
            return self.display_gray(image)
        if mode == 'full':
            return self.full_mono(image)
        if mode == 'partial':
            return self.display_partial(image)
        return self.display_fast(image)

    def sleep(self):
        if self.mode:
            self.command(0x10, 0x01)
            self.pin(18, False)
            self.mode = None
            self.last = None
            self.fast_prepared = False
            self.partials = 0

    def sleep_if_idle(self, now):
        if self.mode and now - self.touched > 18:
            self.sleep()

    def close(self):
        try:
            self.sleep()
        finally:
            self.pin(18, False)
            os.close(self.spi)
            self.gpio.release()


def write_status(console, state, mode, paper=None, error=None, key_counts=None):
    payload = {'view': console.view, 'page': console.page + 1,
               'selected': console.selected + 1 if console.view == 'menu' else None,
               'refresh_seconds': console.refresh, 'refresh_mode': mode,
               'partial_count': paper.partials if paper else 0,
               'state': state, 'updated': int(time.time()), 'error': error,
               'key_counts': key_counts or [0, 0, 0, 0]}
    staging = STATUS_PATH.with_suffix('.tmp')
    staging.write_text(json.dumps(payload))
    staging.replace(STATUS_PATH)


def rates_from(car, last_counters, now):
    wan = car.get('wan') or {}
    counters = (wan.get('counter_source'), wan.get('rx'), wan.get('tx'), now)
    rates = {}
    if wan.get('up') and last_counters and counters[0] == last_counters[0] and all(
            isinstance(v, (int, float)) for v in counters[1:3] + last_counters[1:3]):
        dt = now - last_counters[3]
        if dt > 0 and counters[1] >= last_counters[1] and counters[2] >= last_counters[2]:
            rates = {'down': (counters[1] - last_counters[1]) * 8 / dt / 1e6,
                     'up': (counters[2] - last_counters[2]) * 8 / dt / 1e6}
    return rates, counters


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--preview', metavar='PNG')
    parser.add_argument('--page', type=int, choices=range(1, 6), default=1)
    parser.add_argument('--view', choices=('pages', 'menu', 'confirm', 'pending', 'result'), default='pages')
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--mode', choices=('gray', 'fast'), default='gray')
    args = parser.parse_args()
    console = Console()
    console.page = args.page - 1
    console.view = args.view
    if console.view == 'confirm':
        console.item = 'wifi_band'
    if console.view == 'pending':
        console.pending = {'item': 'wifi_band', 'target': '2g',
                           'started': time.time() - 25, 'deadline': time.time() + 100}
    if args.preview:
        car, ups = read_status()
        render(console, car, ups).save(args.preview)
        return
    paper = Paper()
    counts = [0, 0, 0, 0]
    held = {pin: None for pin in KEYS}
    levels = {pin: 1 for pin in KEYS}
    redraw = 'gray'
    last_periodic = 0
    last_pending_read = 0
    last_counters = None
    rates = {}
    car, ups = {}, {}
    try:
        while True:
            now = time.monotonic()
            for index, pin in enumerate(KEYS):
                level = paper.gpio.get_value(pin).value
                if level == 0 and levels[pin] == 1:
                    held[pin] = now
                elif level == 1 and levels[pin] == 0 and held[pin] is not None:
                    duration = now - held[pin]
                    held[pin] = None
                    if duration >= .04:
                        counts[index] += 1
                        car, ups = read_status()
                        requested = console.handle(index, duration, car)
                        if requested:
                            redraw = requested
                levels[pin] = level
            periodic = now - last_periodic >= console.refresh
            pending_poll = console.view == 'pending' and now - last_pending_read >= 15
            pending_changed = False
            if pending_poll:
                car, ups = read_status()
                pending_changed = console.sync_pending(car)
                last_pending_read = now
            if periodic or pending_changed or redraw:
                car, ups = read_status()
                rates, last_counters = rates_from(car, last_counters, now)
                image = render(console, car, ups, rates)
                mode = 'gray' if periodic and console.view == 'pages' else redraw or 'partial'
                if args.once:
                    mode = args.mode
                try:
                    actual = paper.display(image, mode)
                    write_status(console, 'ok', actual, paper, key_counts=counts)
                except (OSError, TimeoutError, ValueError) as exc:
                    write_status(console, 'error', mode, paper, str(exc), counts)
                    raise
                redraw = None
                if periodic:
                    last_periodic = time.monotonic()
                if args.once:
                    return
            paper.sleep_if_idle(time.monotonic())
            time.sleep(.06)
    finally:
        paper.close()


if __name__ == '__main__':
    main()
