"""Persistence/concurrency checks using temporary files, never the live config."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'root/etc/kk-car'))
import device_settings as settings


class DeviceSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.patches = [patch.object(settings, 'SETTINGS', root / 'settings.json'),
                        patch.object(settings, 'LEGACY', root / 'legacy.json')]
        for p in self.patches: p.start()

    def tearDown(self):
        for p in self.patches: p.stop()
        self.temp.cleanup()

    def test_migrate_preserves_rotation_and_refresh(self):
        settings.LEGACY.write_text('{"refresh_seconds":60}')
        current = settings.snapshot()
        self.assertEqual(current['settings']['rotation'], 180)
        self.assertEqual(current['settings']['refresh_seconds'], 60)
        result = settings.save({'grayscale': False}, current['revision'])
        self.assertTrue(result['ok'])
        self.assertEqual(result['settings']['refresh_seconds'], 60)
        self.assertEqual(settings.SETTINGS.stat().st_mode & 0o777, 0o600)

    def test_screen_and_web_cannot_overwrite_stale_values(self):
        first = settings.snapshot()
        self.assertTrue(settings.save({'rotation': 0}, first['revision'])['ok'])
        stale = settings.save({'refresh_seconds': 300}, first['revision'])
        self.assertTrue(stale['conflict'])
        self.assertEqual(settings.snapshot()['settings']['rotation'], 0)
        latest = settings.save({'refresh_seconds': 300}, stale['revision'])
        self.assertTrue(latest['ok'])
        self.assertEqual(latest['settings']['rotation'], 0)

    def test_invalid_values_never_write_config(self):
        for update in ({'rotation': 90}, {'rotation': True}, {'grayscale': 1},
                       {'clean_after': 11}, {'protect_mv': 2500},
                       {'check_interval_seconds': 1}, {'start_page': 7}, {}):
            self.assertFalse(settings.save(update, 0)['ok'], update)
        self.assertFalse(settings.SETTINGS.exists())

    def test_corrupt_or_unknown_values_fall_back(self):
        settings.SETTINGS.write_text('{"rotation":90,"fast_refresh":0,"revision":false}')
        current = settings.snapshot()
        self.assertEqual(current['revision'], 0)
        self.assertEqual(current['settings']['rotation'], 180)
        self.assertTrue(current['settings']['fast_refresh'])
        settings.SETTINGS.write_text('invalid json')
        self.assertEqual(settings.snapshot()['settings'], settings.DEFAULTS)

    def test_partial_update_preserves_other_modules(self):
        first = settings.save({'rotation': 0, 'hdmi_refresh_seconds': 30}, 0)
        second = settings.save({'check_interval_seconds': 900}, first['revision'])
        self.assertEqual(second['settings']['hdmi_refresh_seconds'], 30)
        self.assertEqual(second['settings']['rotation'], 0)
        self.assertEqual(json.loads(settings.SETTINGS.read_text())['revision'], 2)

    def test_nominal_capacity_is_editable_without_changing_power_settings(self):
        self.assertEqual(settings.snapshot()['settings']['battery_capacity_mah'], 3000)
        changed = settings.save({'battery_capacity_mah': 8000}, 0)
        self.assertTrue(changed['ok'])
        self.assertEqual(settings.snapshot()['settings']['battery_capacity_mah'], 8000)
        self.assertFalse(settings.save({'battery_capacity_mah': 8050}, changed['revision'])['ok'])

    def test_fast_refresh_count_persists_at_ten(self):
        saved = settings.save({'clean_after': 10, 'sleep_seconds': 30}, 0)
        self.assertTrue(saved['ok'])
        self.assertEqual(settings.snapshot()['settings']['clean_after'], 10)
        self.assertEqual(settings.snapshot()['settings']['sleep_seconds'], 30)


if __name__ == '__main__': unittest.main()
