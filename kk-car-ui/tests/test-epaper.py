"""Hardware-free checks for the four-key e-paper console."""

import os
import base64
import io
import json
import sys
import time
import unittest
import tempfile
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.environ.get('EPAPER_SOURCE_DIR') or
                str(Path(__file__).resolve().parents[1] / 'root/etc/kk-car'))
import epaper  # noqa: E402
import device_settings
from PIL import Image


class EpaperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.patches = [patch.object(device_settings, 'SETTINGS', root / 'settings.json'),
                        patch.object(device_settings, 'LEGACY', root / 'legacy.json')]
        for item in self.patches: item.start()

    def tearDown(self):
        for item in self.patches: item.stop()
        self.temp.cleanup()

    def test_rotation_menu_persists_and_web_reload_works(self):
        console = epaper.Console()
        console.view = 'menu'
        console.selected = [item[0] for item in epaper.MENU].index('rotation')
        self.assertEqual(console.handle(3, .1, {}), 'gray')
        self.assertEqual(console.settings['rotation'], 0)
        self.assertEqual(device_settings.snapshot()['settings']['rotation'], 0)
        result = device_settings.save({'rotation': 180, 'refresh_seconds': 60}, console.revision)
        self.assertTrue(result['ok'])
        self.assertTrue(console.reload_settings())
        self.assertEqual((console.settings['rotation'], console.refresh), (180, 60))

    def test_rotation_applies_to_mono_and_gray_frames(self):
        image = Image.new('L', (264, 176), 255)
        image.paste(0, (0, 0, 10, 15))
        self.assertEqual(epaper.Paper.portrait(image, 0).size, (176, 264))
        self.assertEqual(epaper.Paper.portrait(image, 0).rotate(180).tobytes(),
                         epaper.Paper.portrait(image, 180).tobytes())
        self.assertNotEqual(epaper.Paper.gray_planes(image, 0), epaper.Paper.gray_planes(image, 180))

    def test_rotation_invalidates_partial_cache(self):
        paper = epaper.Paper.__new__(epaper.Paper)
        paper.rotation = 180
        paper.sleep = lambda: setattr(paper, 'last', None)
        paper.last = Image.new('1', (176, 264))
        self.assertTrue(paper.configure(dict(device_settings.DEFAULTS, rotation=0)))
        self.assertIsNone(paper.last)
        self.assertEqual(paper.rotation, 0)

    def test_black_white_and_start_page_settings(self):
        self.assertTrue(device_settings.save({'grayscale': False, 'start_page': 4}, 0)['ok'])
        console = epaper.Console()
        self.assertEqual(console.page, 3)
        self.assertTrue(set(epaper.render(console, {}, {}).tobytes()).issubset({0, 255}))

    def test_readable_font_is_bundled(self):
        self.assertEqual(Path(epaper.font(11).path).name, 'AtkinsonHyperlegibleNext-Bold.ttf')
        self.assertEqual(Path(epaper.font(20).path).name, 'AtkinsonHyperlegibleNext-Bold.ttf')
        draw = epaper.CrispDraw(Image.new('L', (264, 176), 255))
        loads = '0.53/0.30/0.18'
        home_width = 126 - max(36, int(draw.textlength('LOAD', font=epaper.font(11))) + 4)
        self.assertEqual(epaper.fitted(draw, loads, epaper.font(12), home_width), loads)
        self.assertEqual(epaper.fitted(draw, loads, epaper.font(17), 119), loads)

    def test_large_digits_have_black_core_and_dark_gray_edge(self):
        image = Image.new('L', (264, 176), 255)
        epaper.CrispDraw(image).text((7, 35), '88', fill=0, font=epaper.font(31), smooth=True)
        self.assertTrue({0, 128, 255}.issubset(set(image.tobytes())))

    def test_small_letters_keep_black_cores_and_gray_edges(self):
        image = Image.new('L', (264, 176), 255)
        epaper.CrispDraw(image).text((7, 35), 'SYSTEM UP', fill=0, font=epaper.font(11))
        self.assertTrue({0, 128, 255}.issubset(set(image.tobytes())))

    def test_fractional_text_coordinates_snap_to_whole_pixels(self):
        def glyph(x):
            image = Image.new('L', (100, 32), 255)
            epaper.CrispDraw(image).text((x, 1), '68', fill=0, font=epaper.font(20))
            return image.tobytes()
        self.assertEqual(glyph(10.49), glyph(10))
        self.assertEqual(glyph(10.51), glyph(11))

    def test_traffic_uses_decimal_units(self):
        self.assertEqual(epaper.size(173700000000), '173.7GB')
        self.assertEqual(epaper.size(827500000), '827.5MB')
        self.assertEqual(epaper.size(1073741824), '1.1GB')

    def test_home_labels_and_values_share_top_and_column_edges(self):
        image = Image.new('L', (264, 176), 255)
        draw = epaper.CrispDraw(image)
        data = {'ping': {}, 'modem': {}, 'band': '--', 'earfcn': None,
                'unread': 0, 'vpn_ip': None, 'system_age': '3h 29m',
                'load': '0.14/0.27/0.27', 'memory': '19%', 'temperature': '55 C',
                'clients': '2', 'power': '~7.6W', 'remaining': '173.7GB',
                'today': '827.5MB'}
        calls = []
        original = epaper.CrispDraw.text

        def record(target, xy, content, **kwargs):
            calls.append((xy, content, kwargs.get('font')))
            return original(target, xy, content, **kwargs)

        with patch.object(epaper.CrispDraw, 'text', record):
            epaper.render_home(draw, data)
        for label, value, left, right in (
                ('SYSTEM UP', '3h 29m', 6, 126),
                ('LOAD', '0.14/0.27/0.27', 138, 258),
                ('LEFT', '173.7GB', 6, 126),
                ('TODAY', '827.5MB', 138, 258)):
            label_xy, _, label_face = next(call for call in calls if call[1] == label)
            (x, value_y), _, face = next(call for call in calls if call[1] == value)
            label_end = left + draw.textlength(label, font=label_face)
            self.assertGreaterEqual(x, label_end + 4)
            self.assertAlmostEqual(x + draw.textlength(value, font=face), right)
            self.assertEqual(label_face.size, face.size)
            self.assertEqual(label_xy[1] + draw.textbbox((0, 0), label, font=label_face)[1],
                             value_y + draw.textbbox((0, 0), value, font=face)[1])
            if label == 'SYSTEM UP':
                self.assertEqual(label_xy[1] + draw.textbbox((0, 0), label, font=label_face)[3],
                                 value_y + draw.textbbox((0, 0), value, font=face)[3])

    def test_four_gray_planes(self):
        image = Image.new('L', (epaper.WIDTH, epaper.HEIGHT), 255)
        image.putpixel((0, 0), 0)
        image.putpixel((1, 0), 128)
        image.putpixel((2, 0), 192)
        one, two = epaper.Paper.gray_planes(image)
        self.assertEqual((len(one), len(two)), (5808, 5808))
        self.assertEqual(sum(v.bit_count() for v in one), 2)
        self.assertEqual(sum(v.bit_count() for v in two), 2)

    def test_fast_mono_keeps_dark_gray_rules_and_strokes(self):
        image = Image.new('L', (264, 176), 255)
        image.putpixel((0, 0), 0)
        image.putpixel((1, 0), 128)
        image.putpixel((2, 0), 192)
        fast = epaper.Paper.mono_frame(image).rotate(-270, expand=True)
        self.assertEqual([fast.getpixel((x, 0)) for x in range(4)], [0, 0, 255, 255])
        for page in range(len(epaper.PAGES)):
            console = epaper.Console()
            console.page = page
            frame = epaper.render(console, {}, {})
            fast = epaper.Paper.mono_frame(frame).rotate(-270, expand=True)
            rule = (0, 116) if page == 0 else (7, 65)
            self.assertEqual(frame.getpixel(rule), 128 if page == 0 else 0)
            self.assertEqual(fast.getpixel(rule), 0)
            if page:
                for y in (65, 87, 110, 133, 158):
                    self.assertTrue(all(frame.getpixel((x, y)) == 0
                                        for x in range(epaper.WIDTH)))
                    self.assertTrue(all(fast.getpixel((x, y)) == 0
                                        for x in range(epaper.WIDTH)))
                self.assertTrue(all(frame.getpixel((132, y)) == 0
                                    for y in range(32, 159)))
                self.assertTrue(all(fast.getpixel((132, y)) == 0
                                    for y in range(32, 159)))

    def test_fast_or_gray_refresh_choice(self):
        settings = epaper.Console().settings
        self.assertEqual(epaper.select_refresh_mode(settings, 'fast'), 'fast')
        self.assertEqual(epaper.select_refresh_mode(settings, 'fast', periodic=True), 'gray')
        settings['fast_refresh'] = False
        self.assertEqual(epaper.select_refresh_mode(settings, 'fast'), 'gray')
        settings['grayscale'] = False
        self.assertEqual(epaper.select_refresh_mode(settings, 'fast'), 'full')

    def test_idle_timing_reverts_immediately_on_join_and_unknown_probe(self):
        settings = dict(device_settings.DEFAULTS, refresh_seconds=60, sleep_seconds=30)
        self.assertEqual(epaper.display_timing(settings, 0), (300, 300, True))
        self.assertEqual(epaper.display_timing(settings, 1), (60, 30, False))
        self.assertEqual(epaper.display_timing(settings, None), (60, 30, False))
        self.assertTrue(epaper.joined_since(0, 1))
        self.assertFalse(epaper.joined_since(None, 1))
        self.assertFalse(epaper.joined_since(1, 2))
        settings['refresh_seconds'] = 600
        self.assertEqual(epaper.display_timing(settings, 0), (600, 300, True))

    def test_only_authorized_wifi_or_live_lan_counts_as_terminal(self):
        stations = {'one': {'authorized': True}, 'two': {'authorized': False}}
        replies = [SimpleNamespace(returncode=0, stdout=json.dumps({'clients': stations})),
                   SimpleNamespace(returncode=0, stdout='0\n')]
        with patch.object(epaper.subprocess, 'run', side_effect=replies), \
             patch.object(epaper.Path, 'read_text', return_value='1\n'):
            self.assertEqual(epaper.connected_terminals(), 2)
        replies = [SimpleNamespace(returncode=0, stdout=json.dumps({'clients': {'pending': {'authorized': False}}})),
                   SimpleNamespace(returncode=0, stdout='1\n')]
        with patch.object(epaper.subprocess, 'run', side_effect=replies):
            self.assertEqual(epaper.connected_terminals(), 0)
        with patch.object(epaper.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout='')):
            self.assertIsNone(epaper.connected_terminals())

    def test_idle_sleep_waits_five_minutes_but_normal_delay_is_preserved(self):
        paper = epaper.Paper.__new__(epaper.Paper)
        paper.mode, paper.touched, paper.sleep_seconds = 'mono', 0, 30
        paper.sleep = lambda: setattr(paper, 'mode', None)
        paper.sleep_if_idle(31, 300)
        self.assertEqual(paper.mode, 'mono')
        paper.sleep_if_idle(301, 300)
        self.assertIsNone(paper.mode)

    def test_fast_and_partial_updates_share_the_full_refresh_limit(self):
        paper = epaper.Paper.__new__(epaper.Paper)
        paper.mode, paper.partials, paper.clean_after = 'mono', 0, 10
        paper.last = epaper.Paper.mono_frame(Image.new('L', (264, 176), 255))
        paper.rotation = 180
        paper.prepare_fast = lambda: None
        paper.command = lambda *args: None
        paper.update = lambda *args: None
        paper.reset = lambda: setattr(paper, 'partials', 0)
        def full(_):
            paper.partials = 0
            return 'full'
        paper.full_mono = full
        image = Image.new('L', (264, 176), 255)
        for count in range(1, 11):
            self.assertEqual(paper.display_fast(image), 'fast')
            self.assertEqual(paper.partials, count)
        self.assertEqual(paper.display_fast(image), 'full')
        image.putpixel((7, 7), 0)
        self.assertEqual(paper.display_partial(image), 'partial')
        self.assertEqual(paper.partials, 1)
        image.putpixel((8, 7), 0)
        self.assertEqual(paper.display_partial(image), 'partial')
        self.assertEqual(paper.partials, 2)

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
            self.assertTrue(set(frame.tobytes()).issubset({0, 128, 192, 255}))

    def test_all_detail_pages_keep_last_row_clear_of_footer(self):
        console = epaper.Console()
        calls = []
        original = epaper.CrispDraw.text

        def record(target, xy, content, **kwargs):
            calls.append((xy, str(content), kwargs.get('font')))
            return original(target, xy, content, **kwargs)

        with patch.object(epaper.CrispDraw, 'text', record):
            for page in range(1, len(epaper.PAGES)):
                console.page = page
                calls.clear()
                epaper.render(console, {}, {})
                content_calls = [(xy, text, face) for xy, text, face in calls
                                 if 33 <= xy[1] < 159]
                self.assertEqual(len(content_calls), 20)
                self.assertLessEqual(max(y + face.getbbox(text)[3]
                                         for (x, y), text, face in content_calls), 156)

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
        self.assertEqual(fields['system_age'], '16m 40s')
        frame = epaper.render(epaper.Console(), car, ups, aux=aux)
        self.assertEqual(frame.getpixel((7, 85)), 0)  # inverted SMS alert
        car['vpn']['connected'] = False
        car['modem']['timestamp'] = now - 100
        fields = epaper.metrics(0, car, ups, {}, aux)
        self.assertIsNone(fields['vpn_ip'])
        self.assertEqual(fields['band'], '--')

    def test_web_mirror_is_last_rendered_frame_and_private(self):
        frame = Path(self.temp.name) / 'epaper-frame.json'
        with patch.object(epaper, 'FRAME_PATH', frame):
            console = epaper.Console()
            image = Image.new('L', (epaper.WIDTH, epaper.HEIGHT), 255)
            image.putpixel((7, 11), 0)
            epaper.write_frame(console, image)
            payload = json.loads(frame.read_text())
        self.assertEqual(frame.stat().st_mode & 0o777, 0o600)
        self.assertEqual((payload['width'], payload['height'], payload['page']), (264, 176, 1))
        decoded = Image.open(io.BytesIO(base64.b64decode(payload['data'])))
        self.assertEqual(decoded.getpixel((7, 11)), 0)

    def test_battery_header_uses_current_direction(self):
        ups = {'ok': True, 'battery': {'percent': 85},
               'sensors': {'battery': {'detected': True, 'current_ma': -210}}}
        self.assertEqual(epaper.battery_header(ups), ('85%', 'DISCHARGE --'))
        ups['sensors']['battery']['current_ma'] = 480
        self.assertEqual(epaper.battery_header(ups), ('85%', 'CHARGING --'))
        ups['battery']['percent_calibration_unverified'] = True
        self.assertEqual(epaper.battery_header(ups), ('~85%', 'CHARGING --'))
        self.assertEqual(epaper.battery_header({}), ('--', 'POWER --'))

    def test_charging_power_uses_valid_battery_sensor_and_fits_header(self):
        ups = {'ok': True, 'input': {'external': True},
               'battery': {'percent': 95, 'percent_calibration_unverified': True},
               'sensors': {'battery': {'detected': True, 'conversion_ready': True,
                                       'overflow': False, 'current_ma': 534,
                                       'power_mw': 2056.968}}}
        self.assertEqual(epaper.charging_power(ups), '~2.1W')
        draw = epaper.CrispDraw(Image.new('L', (264, 176), 255))
        calls = []
        original = epaper.CrispDraw.text

        def record(target, xy, content, **kwargs):
            calls.append((xy, content, kwargs.get('font')))
            return original(target, xy, content, **kwargs)

        with patch.object(epaper.CrispDraw, 'text', record):
            epaper.render(epaper.Console(), {}, ups)
        date = next((xy, text, face) for xy, text, face in calls
                    if '/' in text and ':' in text and xy[1] == 2)
        power = next((xy, text, face) for xy, text, face in calls
                     if '~2.1W' in text)
        self.assertEqual(power[1], '~2.1W ~95%')
        self.assertGreaterEqual(power[0][0],
                                date[0][0] + draw.textlength(date[1], font=date[2]) + 4)
        ups['input']['external'] = False
        self.assertIsNone(epaper.charging_power(ups))
        ups['input']['external'] = True
        ups['sensors']['battery']['conversion_ready'] = False
        self.assertIsNone(epaper.charging_power(ups))

    def test_battery_header_estimates_charge_and_discharge_without_percentage(self):
        ups = {'ok': True,
               'battery': {'percent': 90, 'percent_calibration_unverified': True,
                           'millivolts': 3600, 'configured_full_mv': 4200,
                           'configured_protect_mv': 3000, 'nominal_capacity_mah': 3000},
               'input': {'external': False},
               'sensors': {'battery': {'detected': True, 'current_ma': -500},
                           'pi_supply': {'detected': True, 'power_mw': 6000}}}
        self.assertEqual(epaper.battery_header(ups), ('~90%', 'DISCHARGE ~45m'))
        ups['input']['external'] = True
        ups['sensors']['battery']['current_ma'] = 500
        self.assertEqual(epaper.battery_header(ups), ('~90%', 'CHARGING ~3h45'))

    def test_battery_eta_drops_invalid_or_unsafe_readings(self):
        ups = {'ok': True,
               'battery': {'millivolts': 3600, 'configured_full_mv': 4200,
                           'configured_protect_mv': 3000, 'nominal_capacity_mah': 3000},
               'input': {'external': False},
               'sensors': {'battery': {'detected': True, 'current_ma': -500},
                           'pi_supply': {'detected': True, 'power_mw': 6000}}}
        self.assertEqual(epaper.battery_eta(ups, 'DISCHARGE'), '~45m')
        ups['sensors']['pi_supply']['overflow'] = True
        self.assertEqual(epaper.battery_eta(ups, 'DISCHARGE'), '--')
        ups['sensors']['pi_supply']['overflow'] = False
        ups['battery']['millivolts'] = 3030
        self.assertEqual(epaper.battery_eta(ups, 'DISCHARGE'), '--')
        ups['battery']['millivolts'] = 3600
        ups['input']['external'] = True
        ups['sensors']['battery']['current_ma'] = 0
        self.assertEqual(epaper.battery_eta(ups, 'CHARGING'), '--')
        ups['sensors']['battery']['current_ma'] = float('nan')
        self.assertEqual(epaper.battery_eta(ups, 'CHARGING'), '--')

    def test_setting_needs_long_confirmation(self):
        console = epaper.Console()
        console.view = 'menu'
        console.selected = [item[0] for item in epaper.MENU].index('vpn_toggle')
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
