#!/usr/bin/env python3
"""KK-Car status for the Waveshare 2.7-inch monochrome e-Paper HAT V2.

The display controller sequence and GPIO mapping follow Waveshare's
epd2in7_V2 example. This service uses OpenWrt's spidev and libgpiod packages
instead of Raspberry Pi OS-specific GPIO libraries.
"""

import argparse
import fcntl
import json
import os
import struct
import subprocess
import time
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 264, 176
REFRESH_SECONDS = 120
STATUS_PATH = Path('/tmp/kk-car-epaper-status.json')
KEYS = (5, 6, 13, 19)  # KEY1..KEY4, BCM numbering


def read_status():
    def call(name):
        try:
            result = subprocess.run(['ubus', 'call', name, 'status'], capture_output=True,
                                    text=True, timeout=7, check=True)
            return json.loads(result.stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            return {}
    return call('kkcar'), call('kkups')


def value(number, suffix='', decimals=0):
    if not isinstance(number, (int, float)) or isinstance(number, bool):
        return '--'
    return f'{number:.{decimals}f}{suffix}'


def font(size):
    return ImageFont.load_default(size=size)


def render(page, car, ups, rates=None):
    """Create a landscape 264x176 one-bit frame. No hardware access here."""
    rates = rates or {}
    image = Image.new('1', (WIDTH, HEIGHT), 1)
    draw = ImageDraw.Draw(image)
    big, normal, small = font(18), font(13), font(10)
    page_names = ('OVERVIEW', 'CELLULAR', 'VPN / DATA', 'UPS / SYSTEM')
    draw.rectangle((0, 0, WIDTH - 1, 29), fill=0)
    draw.text((7, 4), 'KK-CAR', fill=1, font=big)
    draw.text((155, 8), time.strftime('%H:%M'), fill=1, font=small)
    draw.text((7, 34), page_names[page], fill=0, font=normal)
    draw.line((7, 52, WIDTH - 8, 52), fill=0, width=1)

    wan = car.get('wan') or {}
    vpn = car.get('vpn') or {}
    ping = car.get('vpn_ping') or {}
    modem = car.get('modem') or {}
    wifi = car.get('wifi') or {}
    uplink = car.get('uplink') or {}
    battery = ups.get('battery') or {}
    output = ups.get('output') or {}
    power = car.get('power') or {}
    ping_age = (car.get('uptime') or 0) - (ping.get('uptime') or 0)
    if not vpn.get('connected') or not ping.get('timestamp') or not 0 <= ping_age <= 25:
        ping = {}
    modem_age = (car.get('timestamp') or 0) - (modem.get('timestamp') or 0)
    if not modem.get('online') or not 0 <= modem_age < 75:
        modem = {}
    if not ups.get('ok'):
        battery, output = {}, {}
    source = 'Wired' if uplink.get('active') == 'ethernet' else 'LTE'
    battery_text = value(battery.get('percent'), '%')
    voltage = value((output.get('pogo_mv') or 0) / 1000, 'V', 2) if output.get('pogo_mv') else '--'
    lines = []
    if page == 0:
        lines = [
            f'WAN  {source if wan.get("up") else "DOWN"}     VPN  {"UP" if vpn.get("connected") else "DOWN"}',
            f'PING {value(ping.get("avg_ms"), "ms", 1)}   LOSS {value(ping.get("loss_percent"), "%")}',
            f'RSRP {value(modem.get("rsrp"), "dBm")}  SINR {value(modem.get("snr"), "dB", 1)}',
            f'UPS  {battery_text}   OUT {voltage}',
            f'Wi-Fi clients  {wifi.get("clients", "--")}',
        ]
    elif page == 1:
        lines = [
            f'Network  {modem.get("network") or "--"}  {modem.get("band") or ""}',
            f'RSRP  {value(modem.get("rsrp"), " dBm")}',
            f'RSRQ  {value(modem.get("rsrq"), " dB")}',
            f'SINR  {value(modem.get("snr"), " dB", 1)}',
            f'RSSI  {value(modem.get("rssi"), " dBm")}',
        ]
    elif page == 2:
        lines = [
            f'VPN  {"CONNECTED" if vpn.get("connected") else "DOWN"}',
            f'RTT  {value(ping.get("avg_ms"), " ms", 1)}',
            f'Loss {value(ping.get("loss_percent"), " %")}',
            f'Down {value(rates.get("down"), " Mbps", 2)}',
            f'Up   {value(rates.get("up"), " Mbps", 2)}',
        ]
    else:
        external = (ups.get('input') or {}).get('external')
        source_label = 'EXTERNAL' if external is True else 'BATTERY' if external is False else '--'
        pi_power = '--' if not power.get('known') else 'LOW' if power.get('undervoltage') else 'OK'
        lines = [
            f'Source  {source_label}',
            f'Battery {battery_text}',
            f'Output  {voltage}',
            f'Temp    {value(battery.get("temperature_c"), " C")}',
            f'Pi power {pi_power}',
        ]
    for index, line in enumerate(lines):
        draw.text((9, 57 + index * 19), line[:35], fill=0, font=normal)
    draw.line((7, 155, WIDTH - 8, 155), fill=0, width=1)
    labels = ('1 HOME', '2 LTE', '3 VPN', '4 UPS')
    for index, label in enumerate(labels):
        x = 8 + index * 64
        if index == page:
            draw.rectangle((x - 2, 158, x + 56, 174), fill=0)
        draw.text((x, 159), label, fill=1 if index == page else 0, font=small)
    return image


class Paper:
    """Small V2 black/white driver; SPI0 CE0 handles chip-select in hardware."""

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
        fcntl.ioctl(self.spi, 0x40016B01, bytes([0]))  # SPI_IOC_WR_MODE = 0
        fcntl.ioctl(self.spi, 0x40046B04, struct.pack('I', 4_000_000))

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

    def command(self, code):
        self.pin(25, False)
        os.write(self.spi, bytes([code]))

    def data(self, payload):
        self.pin(25, True)
        if isinstance(payload, int):
            payload = bytes([payload])
        for offset in range(0, len(payload), 2048):
            os.write(self.spi, payload[offset:offset + 2048])

    def show(self, image):
        self.pin(18, True)
        try:
            self.reset()
            self.busy()
            self.command(0x12)  # software reset
            self.busy()
            self.command(0x45)  # RAM Y range 0..263
            self.data(bytes((0x00, 0x00, 0x07, 0x01)))
            self.command(0x4F)
            self.data(bytes((0x00, 0x00)))
            self.command(0x11)  # increment X/Y
            self.data(0x03)
            self.command(0x24)
            # Waveshare RAM is portrait 176x264. Rotate the landscape frame.
            portrait = image.rotate(90, expand=True).convert('1')
            assert portrait.size == (176, 264)
            self.data(portrait.tobytes())
            self.command(0x22)
            self.data(0xF7)
            self.command(0x20)
            self.busy()
            self.command(0x10)  # deep sleep; the next frame resets first
            self.data(0x01)
        finally:
            self.pin(18, False)

    def close(self):
        os.close(self.spi)
        self.gpio.release()


def write_status(page, state, error=None, key_counts=None):
    STATUS_PATH.write_text(json.dumps({'page': page + 1, 'state': state,
                                       'updated': int(time.time()), 'error': error,
                                       'key_counts': key_counts or [0, 0, 0, 0]}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--preview', metavar='PNG', help='render one frame without GPIO or SPI')
    parser.add_argument('--once', action='store_true', help='show one frame and exit')
    parser.add_argument('--page', type=int, choices=range(1, 5), default=1)
    args = parser.parse_args()
    if args.preview:
        car, ups = read_status()
        render(args.page - 1, car, ups).save(args.preview)
        return

    paper = Paper()
    page = 0
    last_levels = {pin: 1 for pin in KEYS}
    last_press = 0.0
    key_counts = [0, 0, 0, 0]
    last_render = 0.0
    last_counters = None
    rates = {}
    try:
        while True:
            now = time.monotonic()
            for index, pin in enumerate(KEYS):
                level = paper.gpio.get_value(pin).value
                if level == 0 and last_levels[pin] == 1 and now - last_press > .25:
                    page = index
                    key_counts[index] += 1
                    last_press = now
                    last_render = 0
                last_levels[pin] = level
            if now - last_render >= REFRESH_SECONDS:
                car, ups = read_status()
                wan = car.get('wan') or {}
                counters = (wan.get('counter_source'), wan.get('rx'), wan.get('tx'), now)
                rates = {}
                if last_counters and counters[0] == last_counters[0] and all(
                        isinstance(v, (int, float)) for v in counters[1:3] + last_counters[1:3]):
                    dt = now - last_counters[3]
                    if dt > 0 and counters[1] >= last_counters[1] and counters[2] >= last_counters[2]:
                        rates = {'down': (counters[1] - last_counters[1]) * 8 / dt / 1e6,
                                 'up': (counters[2] - last_counters[2]) * 8 / dt / 1e6}
                last_counters = counters
                try:
                    paper.show(render(page, car, ups, rates))
                    write_status(page, 'ok', key_counts=key_counts)
                    if args.once:
                        return
                except (OSError, TimeoutError) as exc:
                    write_status(page, 'error', str(exc), key_counts=key_counts)
                    raise
                last_render = time.monotonic()
            time.sleep(.08)
    finally:
        paper.close()


if __name__ == '__main__':
    main()
