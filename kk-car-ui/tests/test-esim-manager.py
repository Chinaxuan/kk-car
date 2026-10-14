"""Safety regression checks for the SMS-only secondary eSIM controller."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / 'root/etc/kk-car'
sys.path.insert(0, str(SOURCE))
spec = importlib.util.spec_from_file_location('esim_manager', SOURCE / 'esim-manager.py')
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


def profile(number, enabled):
    return {'iccid': number, 'profileState': 'enabled' if enabled else 'disabled',
            'profileName': 'Test profile', 'serviceProviderName': 'Test'}


class ESIMSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.patchers = [
            mock.patch.object(manager, 'CONFIG', base / 'config.json'),
            mock.patch.object(manager, 'STATE', base / 'state.json'),
            mock.patch.object(manager, 'REQUEST', base / 'request.json'),
        ]
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_one_profile_never_enables_or_disables(self):
        with mock.patch.object(manager, 'run', return_value=[profile('8901000000000000001', True)]) as run:
            token = manager.profiles()[0]['token']
            with self.assertRaisesRegex(RuntimeError, '只有一个配置'):
                manager.do_switch(token)
            self.assertEqual(run.call_args_list, [mock.call(['profile', 'list']), mock.call(['profile', 'list'])])

    def test_switch_uses_only_card_listed_iccid_and_verifies(self):
        before = [profile('8901000000000000001', True), profile('8901000000000000002', False)]
        after = [profile('8901000000000000001', False), profile('8901000000000000002', True)]
        with mock.patch.object(manager, 'run', side_effect=[before, None, after]) as run:
            token = manager.hashlib.sha256(before[1]['iccid'].encode()).hexdigest()
            result = manager.do_switch(token)
            self.assertTrue(result['changed'])
            self.assertEqual(run.call_args_list[1], mock.call(['profile', 'enable', before[1]['iccid']], deadline_seconds=90))
            self.assertNotIn('iccid', manager.load(manager.STATE))

    def test_auto_switch_cannot_be_enabled_for_one_profile(self):
        item = profile('8901000000000000001', True)
        token = manager.hashlib.sha256(item['iccid'].encode()).hexdigest()
        manager.REQUEST.write_text(json.dumps({'auto': True, 'interval_minutes': 60, 'rotation': [token]}))
        with mock.patch.object(manager, 'run', return_value=[item]) as run:
            with self.assertRaisesRegex(RuntimeError, '至少两个配置'):
                manager.save_config()
            self.assertFalse(manager.CONFIG.exists())
            self.assertEqual(run.call_count, 1)

    def test_disabled_rotation_never_reads_or_switches_card(self):
        with mock.patch.object(manager, 'run') as run:
            self.assertEqual(manager.tick()['skipped'], 'disabled')
            run.assert_not_called()

    def test_storage_reports_encrypted_files_and_capacity_without_opening_sms(self):
        base = Path(self.temp.name)
        history, archive = base / 'history', base / 'archive'
        history.mkdir()
        archive.mkdir()
        (history / ('a' * 64 + '.der')).write_bytes(b'encrypted-history')
        (archive / ('a' * 64 + '.der')).write_bytes(b'encrypted-archive')
        for name in ('esim-sms-history-index.json', 'sms-local-cert.pem',
                     'sms-local-key.pem', 'sms-archive-recipient.pem'):
            (base / name).write_text('test')
        with mock.patch.object(manager, 'PRIVATE', base), \
             mock.patch.object(manager, 'HISTORY', history), \
             mock.patch.object(manager, 'ARCHIVE', archive), \
             mock.patch.object(manager.os, 'statvfs', return_value=SimpleNamespace(
                 f_bavail=4096, f_blocks=8192, f_frsize=32768)):
            result = manager.storage_status()
        self.assertTrue(result['ready'])
        self.assertEqual(result['history_count'], 1)
        self.assertEqual(result['archive_count'], 1)
        self.assertEqual(result['history_bytes'], len(b'encrypted-history'))
        self.assertGreater(result['free_bytes'], 64 * 1024 * 1024)


if __name__ == '__main__':
    unittest.main()
