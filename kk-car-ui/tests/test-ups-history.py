#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ups_history', Path(__file__).resolve().parents[1]/'root/etc/kk-car/ups_history.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
BASE = 1790400000


def sample(i, current=-2000, boot='test-boot', **kw):
    row = {'event': 'sample', 'timestamp': BASE + i*60, 'uptime_s': i*60 + 300,
           'boot': boot, 'ups': {'ok': True, 'external': current >= 0,
           'controller_mv': 3900-i, 'percent_estimate': 73, 'temperature_c_estimate': 30,
           'pogo_mv': 5000, 'pi_flags': 0,
           'battery_sensor': {'detected': True, 'bus_mv': 3500-i,
               'current_ma_estimate': current, 'power_mw_estimate': current*3.5},
           'pi_sensor': {'detected': True, 'power_mw_estimate': 7000}}}
    row.update(kw)
    return row


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old = h.DIRECTORY
        h.DIRECTORY = Path(self.temp.name)

    def tearDown(self):
        h.DIRECTORY = self.old
        self.temp.cleanup()

    def write(self, rows, name='faults.jsonl'):
        (h.DIRECTORY/name).write_text(''.join(json.dumps(r)+'\n' for r in rows))

    def query(self, **params):
        return h.history({'range': 'all', **params}, BASE+86400)

    def test_separate_sources_signed_units_and_energy(self):
        self.write([sample(i) for i in range(61)])
        result = self.query()
        row = result['points'][0]
        self.assertEqual(row[3:7], [3.9, 3.5, -2, -7])
        self.assertEqual(result['summary']['energy_estimate']['discharge_wh'], 7)
        self.assertEqual(result['summary']['energy_estimate']['discharge_ah'], 2)
        self.assertEqual(result['summary']['covered_s'], 3600)
        self.assertFalse(result['calibration_verified'])

    def test_charge_idle_and_singletons_not_integrated(self):
        self.write([sample(0, 1000), sample(1, 0), sample(2, 1000)])
        r = self.query()
        self.assertEqual([s['mode'] for s in r['sessions']], ['external'])
        self.assertEqual(r['summary']['energy_estimate']['charge_wh'], 0)
        self.assertEqual(r['summary']['covered_s'], 120)

    def test_gaps_boot_clock_jump_and_missing_not_bridged(self):
        rows = [sample(0), sample(1), sample(8), sample(9, boot='next'), sample(10, boot='next', uptime_s=1)]
        rows.append(sample(11, boot='next', uptime_s=61))
        rows[-1]['ups']['battery_sensor']['bus_mv'] = None
        self.write(rows)
        r = self.query()
        self.assertEqual(r['summary']['covered_s'], 60)
        self.assertEqual(len(r['sessions']), 4)
        self.assertIsNone(r['points'][-1][4])

    def test_null_invalid_bool_nan_never_become_zero(self):
        row = sample(0)
        row['ups']['controller_mv'] = True
        row['ups']['battery_sensor']['bus_mv'] = float('nan')
        row['ups']['temperature_c_estimate'] = '30'
        self.write([row])
        r = self.query()
        self.assertIsNone(r['points'][0][3])
        self.assertIsNone(r['points'][0][4])
        self.assertIsNone(r['points'][0][9])
        json.dumps(r, allow_nan=False)

    def test_failed_ups_hides_stale_metrics(self):
        row = sample(0)
        row['ups']['ok'] = False
        self.write([row])
        self.assertEqual(self.query()['points'][0][3:12], [None]*9)

    def test_partial_malformed_oversized_and_privacy(self):
        row = sample(0)
        row['phone'] = 'private-phone'
        row['ups']['serial'] = 'private-serial'
        self.write([row])
        with (h.DIRECTORY/'faults.jsonl').open('a') as f:
            f.write('invalid\n'+'x'*20000+'\n'+json.dumps(sample(1)))
        r = self.query()
        self.assertEqual(r['reader']['invalid_lines'], 3)
        self.assertEqual(r['summary']['samples'], 1)
        self.assertNotIn('private-', json.dumps(r))

    def test_rotation_duplicates_and_event_allowlist(self):
        self.write([sample(0),sample(1)],'faults.1.jsonl')
        self.write([sample(1),sample(2),{'event':'boot','timestamp':BASE+150,'token':'secret'},
                    {'event':'secret','timestamp':BASE+140}])
        r=self.query()
        self.assertEqual(r['summary']['samples'],3)
        self.assertEqual(r['events'],[{'timestamp':BASE+150,'event':'boot'}])
        self.assertNotIn('secret',json.dumps(r))

    def test_select_session_and_custom_interval(self):
        self.write([sample(0),sample(1),sample(2,1000),sample(3,1000)])
        r=self.query(segment=2)
        self.assertEqual(r['summary']['samples'],2)
        self.assertEqual(len(r['sessions']),2)
        r=self.query(range='custom',start=BASE+60,end=BASE+120)
        self.assertEqual(r['summary']['samples'],2)
        with self.assertRaises(ValueError):self.query(range='custom',start=BASE+60,end=BASE)
        with self.assertRaises(ValueError):self.query(range='../../private')

    def test_downsample_preserves_extrema_boundaries_and_stats(self):
        rows=[sample(i) for i in range(2000)]
        rows[876]['ups']['controller_mv']=4200
        rows[877]['ups']['battery_sensor']['current_ma_estimate']=-19000
        self.write(rows)
        r=h.history({'range':'all'},BASE+200000)
        self.assertTrue(r['downsampled'])
        self.assertLessEqual(len(r['points']),1000)
        self.assertEqual(r['summary']['samples'],2000)
        self.assertIn(4.2,[v[3] for v in r['points']])
        self.assertIn(-19,[v[5] for v in r['points']])
        self.assertEqual(r['points'][0][0],BASE)
        self.assertEqual(r['points'][-1][0],BASE+1999*60)

    def test_raw_export_pages_exact_and_window_identity(self):
        self.write([sample(i) for i in range(2001)])
        q={'range':'custom','start':BASE,'end':BASE+2000*60,'raw':True}
        r=h.history(q,BASE+200000)
        r2=h.history({**q,'offset':1000},BASE+200000)
        r3=h.history({**q,'offset':2000},BASE+200000)
        self.assertEqual([len(x['points']) for x in [r,r2,r3]],[1000,1000,1])
        self.assertEqual(r['window_id'],r2['window_id'])
        self.assertIsNone(r3['next_offset'])
        self.write([sample(i) for i in range(1,2001)])
        self.assertNotEqual(r['window_id'],h.history(q,BASE+200000)['window_id'])

    def test_empty_and_unknown_timestamp(self):
        self.assertTrue(self.query()['ok'])
        self.assertEqual(self.query()['points'],[])
        self.write([sample(0,timestamp=10)])
        self.assertEqual(self.query()['summary']['samples'],0)

    def test_symlink_ignored(self):
        target=h.DIRECTORY/'private.jsonl'
        target.write_text(json.dumps(sample(0))+'\n')
        (h.DIRECTORY/'faults.jsonl').symlink_to(target)
        self.assertEqual(self.query()['summary']['samples'],0)


if __name__ == '__main__':
    unittest.main()
