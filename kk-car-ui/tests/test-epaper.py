"""Hardware-free checks for the four-key e-paper console."""

import os
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.environ.get('EPAPER_SOURCE_DIR') or
                str(Path(__file__).resolve().parents[1] / 'root/etc/kk-car'))
import epaper  # noqa: E402
from PIL import Image


class EpaperTests(unittest.TestCase):
    def test_four_gray_planes(self):
        image = Image.new('L', (epaper.WIDTH, epaper.HEIGHT), 255)
        image.putpixel((0, 0), 0)
        image.putpixel((1, 0), 128)
        image.putpixel((2, 0), 192)
        one, two = epaper.Paper.gray_planes(image)
        self.assertEqual((len(one), len(two)), (5808, 5808))
        self.assertEqual(sum(v.bit_count() for v in one), 2)
        self.assertEqual(sum(v.bit_count() for v in two), 2)

    def test_layout_and_key_navigation(self):
        console = epaper.Console()
        self.assertEqual(console.handle(2, .1, {}), 'fast')
        self.assertEqual(console.page, 1)
        self.assertEqual(console.handle(1, .1, {}), 'fast')
        self.assertEqual(console.page, 0)
        self.assertEqual(console.handle(3, .1, {}), 'fast')
        self.assertEqual(console.view, 'menu')
        self.assertEqual(console.handle(2, .1, {}), 'partial')
        self.assertEqual(console.selected, 1)
        self.assertEqual(console.handle(0, .1, {}), 'gray')
        self.assertEqual(console.view, 'pages')
        self.assertEqual(len(epaper.PAGES), 6)
        for page in range(6):
            console.page = page
            if page:
                self.assertEqual(len(epaper.metrics(page, {}, {}, {})), 10)
            else:
                self.assertEqual(len(epaper.metrics(page, {}, {}, {})), 14)
            frame = epaper.render(console, {}, {})
            self.assertEqual((frame.size, frame.mode), ((264, 176), 'L'))
            self.assertEqual(frame.getpixel((240, 171)), 0)  # solid high-contrast footer
            self.assertTrue(set(frame.tobytes()).issubset({0, 192, 255}))

    def test_home_uses_distinct_fresh_sources_and_unread_badge(self):
        now = time.time()
        car = {'ok': True, 'timestamp': now, 'uptime': 1000,
               'wan': {'up': True}, 'vpn': {'connected': True, 'ip': '10.8.250.1', 'age': 700},
               'vpn_ping': {'timestamp': now, 'uptime': 995, 'avg_ms': 23, 'loss_percent': 0},
               'modem': {'online': True, 'timestamp': now, 'rsrp': -87},
               'telemetry': {'loads': ['.12', '.28', '.41']},
               'memory': {'total': 100, 'available': 82}, 'temperature': 54,
               'wifi': {'clients': 2}}
        ups = {'ok': True, 'sensors': {'pi_supply': {'detected': True, 'power_mw': 7100}}}
        aux = {'radio': {'band': 'LTE B1', 'earfcn': 300},
               'traffic': {'estimated_remaining': 193273528320, 'day': {'rx': 200000000, 'tx': 300000000}},
               'sms': {'unread_known': True, 'unread_count': 2}}
        fields = epaper.metrics(0, car, ups, {}, aux)
        self.assertEqual((fields['band'], fields['earfcn'], fields['unread'], fields['memory']),
                         ('B1', 300, 2, '18%'))
        frame = epaper.render(epaper.Console(), car, ups, aux=aux)
        self.assertEqual(frame.getpixel((7, 85)), 0)  # inverted SMS alert
        car['vpn']['connected'] = False
        car['modem']['timestamp'] = now - 100
        fields = epaper.metrics(0, car, ups, {}, aux)
        self.assertIsNone(fields['vpn_ip'])
        self.assertEqual(fields['band'], '--')

    def test_battery_header_uses_current_direction(self):
        ups = {'ok': True, 'battery': {'percent': 85},
               'sensors': {'battery': {'detected': True, 'current_ma': -210}}}
        self.assertEqual(epaper.battery_header(ups), ('85%', 'DISCHARGE'))
        ups['sensors']['battery']['current_ma'] = 480
        self.assertEqual(epaper.battery_header(ups), ('85%', 'CHARGING'))
        self.assertEqual(epaper.battery_header({}), ('--', 'POWER --'))

    def test_setting_needs_long_confirmation(self):
        console = epaper.Console()
        console.view = 'menu'
        console.selected = 3  # VPN pause/start
        self.assertEqual(console.handle(3, .1, {}), 'fast')
        self.assertEqual(console.view, 'confirm')
        with patch.object(epaper, 'perform', return_value={'ok': True, 'accepted': True}) as do:
            self.assertIsNone(console.handle(3, .5, {}))
            do.assert_not_called()
            self.assertEqual(console.handle(3, 1.6, {}), 'fast')
            do.assert_called_once()
        self.assertEqual(console.view, 'result')

    def test_wifi_and_port_use_existing_rollback_api(self):
        car = {'wifi': {'ssid': 'KK-Car', 'band': '5g'},
               'ethernet': {'mode': 'wan'}}
        with patch.object(epaper, 'ubus', return_value={'ok': True, 'pending': {'deadline': 999}}) as call:
            wifi = epaper.perform('wifi_band', car, 180)
            self.assertEqual(wifi['target'], '2g')
            call.assert_called_with('wifi_save', {'ssid': 'KK-Car', 'password': '', 'band': '2g'})
            port = epaper.perform('port_mode', car, 180)
            self.assertEqual(port['target'], 'lan')
            call.assert_called_with('port_save', {'mode': 'lan'})

    def test_wifi_keep_requires_target_ap_and_hold(self):
        console = epaper.Console()
        console.view = 'pending'
        console.pending = {'item': 'wifi_band', 'target': '2g',
                           'started': time.time() - 20, 'deadline': time.time() + 80}
        car = {'wifi': {'enabled': True, 'band': '2g', 'frequency': 5180}}
        with patch.object(epaper, 'ubus', return_value={'ok': True}) as call:
            self.assertIsNone(console.handle(3, .5, car))
            self.assertEqual(console.handle(3, 1.6, car), 'partial')
            call.assert_not_called()
            car['wifi']['frequency'] = 2437
            self.assertEqual(console.handle(3, 1.6, car), 'fast')
            call.assert_called_once_with('wifi_confirm')
        self.assertEqual(console.view, 'result')

    def test_down_wan_has_no_stale_speed(self):
        previous = ('wwan0|wan', 1000, 2000, 10.0)
        rates, _ = epaper.rates_from({'wan': {'up': False, 'counter_source': 'wwan0|wan',
                                              'rx': 5000, 'tx': 6000}}, previous, 20.0)
        self.assertEqual(rates, {})

    def test_partial_region_and_full_after_four_changes(self):
        paper = epaper.Paper.__new__(epaper.Paper)
        paper.mode = 'mono'
        paper.last = Image.new('1', (176, 264), 1)
        paper.partials = 0
        paper.touched = 0
        commands = []
        paper.reset = lambda: None
        paper.command = lambda code, data=None: commands.append((code, data))
        paper.update = lambda value: commands.append(('update', value))
        image = Image.new('L', (264, 176), 255)
        image.paste(0, (0, 0, 10, 10))
        self.assertEqual(paper.display_partial(image), 'partial')
        self.assertIn(('update', 0xFF), commands)
        payload = next(data for code, data in commands if code == 0x24)
        self.assertLess(len(payload), 5808)


if __name__ == '__main__':
    unittest.main()
