#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('diagnostics', Path(__file__).resolve().parents[1]/'root/etc/kk-car/diagnostics.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)

class RecorderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old = d.DIRECTORY, d.LIMIT, d.FILES
        d.DIRECTORY = Path(self.temp.name)/'private'
        d.LIMIT, d.FILES = 1024, 4

    def tearDown(self):
        d.DIRECTORY, d.LIMIT, d.FILES = self.old
        self.temp.cleanup()

    def test_privacy_and_rotation(self):
        for i in range(40):
            d.event('power_action', {'action':'shutdown', 'controller_mv':3700,
                'phone':'13800138000', 'text':'private SMS', 'token':'secret',
                'ip':'203.0.113.42', 'voltage_source':'private-secret'})
        files=list(d.DIRECTORY.glob('faults*.jsonl'))
        self.assertEqual(len(files), 4)
        self.assertLessEqual(sum(p.stat().st_size for p in files), 4096)
        for p in files:
            self.assertEqual(p.stat().st_mode&0o777, 0o600)
            for line in p.read_text().splitlines():
                item=json.loads(line)
                self.assertEqual(item['details']['controller_mv'],3700)
                self.assertIsNone(item['details']['voltage_source'])
            for secret in ['13800138000','private SMS','secret','203.0.113.42']:
                self.assertNotIn(secret,p.read_text())
        self.assertEqual(d.DIRECTORY.stat().st_mode&0o777,0o700)

    def test_error_categories_no_raw(self):
        counts=d.error_counts('netifd: wan (123): Request timed out private-token\n'
                              'kernel: FAT-fs (mmcblk0p1): Volume was not properly unmounted\n'
                              'ipsec: Host is unreachable 203.0.113.2')
        self.assertEqual(counts['qmi_timeout'],1)
        self.assertEqual(counts['sd_unclean'],1)
        self.assertEqual(counts['vpn_unreachable'],1)
        self.assertEqual(counts['sd_io_error'],0)
        self.assertEqual(d.error_counts('kernel: brcmfmac mmc1:0001:1: Direct firmware load failed with error -2')['sd_io_error'],0)
        self.assertEqual(d.error_counts('kernel: mmcblk0: I/O error')['sd_io_error'],1)
        self.assertNotIn('private-token',json.dumps(counts))

    def test_stale_signal_and_identifiers(self):
        ups={'ok':True,'battery':{'millivolts':3800,'percent':73},
             'controller':{'serial':'secret-uid','shutdown_countdown_s':120},
             'input':{'external':False},'sensors':{'battery':{'bus_mv':3550,'detected':True}}}
        modem={'timestamp':100,'rsrp':-90,'connected':True,'management_ip':'203.0.113.42'}
        at={'timestamp':199,'rsrp_dbm':-102,'band':'LTE B3','cell_id':'secret-cell'}
        sample=d.select_snapshot(ups,modem,at,{}, {}, {}, {},200)
        self.assertEqual(sample['cellular']['rsrp'],-102)
        self.assertIsNone(sample['cellular']['connected'])
        self.assertEqual(sample['ups']['shutdown_s'],120)
        for secret in ['secret-uid','secret-cell','203.0.113.42']:
            self.assertNotIn(secret,json.dumps(sample))
        at['timestamp']=201
        self.assertIsNone(d.select_snapshot(ups,modem,at,{}, {}, {}, {},200)['cellular']['rsrp'])

    def test_clean_and_unclean_boot(self):
        d.lifecycle('start')
        first=json.loads((d.DIRECTORY/'lifecycle.json').read_text())
        self.assertFalse(first['clean'])
        d.lifecycle('shutdown')
        self.assertTrue(json.loads((d.DIRECTORY/'lifecycle.json').read_text())['clean'])
        d.atomic(d.DIRECTORY/'lifecycle.json',{'boot':'different-boot','clean':False})
        d.lifecycle('start')
        last=json.loads((d.DIRECTORY/'faults.jsonl').read_text().splitlines()[-1])
        self.assertEqual(last['event'],'boot')
        self.assertFalse(last['previous_clean'])

    def test_reject_unknown_event(self):
        with self.assertRaises(ValueError):
            d.event('raw_sms',{'text':'private'})
        self.assertIsNone(d.number(float('nan')))
        self.assertIsNone(d.number(True))

    def test_incomplete_power_loss_tail(self):
        d.event('power_action', {'action':'shutdown'})
        p=d.DIRECTORY/'faults.jsonl'
        previous=p.read_bytes()
        with p.open('ab') as stream:
            stream.write(b'{"event":"partially-written')
        d.LIMIT=len(previous)+30
        d.event('power_action', {'action':'reboot_pi'})
        rotated=d.DIRECTORY/'faults.1.jsonl'
        self.assertEqual(rotated.read_bytes(),previous)
        rows=[json.loads(line) for f in [rotated,p] for line in f.read_text().splitlines()]
        self.assertEqual(len(rows),2)
        self.assertEqual(rows[-1]['details']['action'],'reboot_pi')

if __name__ == '__main__':
    unittest.main()
