"""Fault/recovery policy tests. No real probes, routes or recovery commands."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('health', Path(__file__).parents[1] / 'root/etc/kk-car/network_health.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)


class Policy(unittest.TestCase):
    def setUp(self):
        self.config = dict(h.DEFAULTS)
        self.group = dict(device='wwan0', identity='test-cell', reason='ready', available=True)

    def probes(self, *answers):
        return [dict(target=f'192.0.2.{i+1}', ok=v, latency_ms=12 if v else None) for i, v in enumerate(answers)]

    def test_one_target_cannot_reconnect_and_hysteresis(self):
        prev = {}
        for _ in range(10):
            prev = h.advance(self.group, self.probes(True, False), prev, self.config)
        self.assertEqual(prev['state'], 'degraded')
        self.assertEqual(prev['bad'], 0)
        for i in range(3):
            prev = h.advance(self.group, self.probes(False, False), prev, self.config)
            self.assertEqual(prev['state'], 'failed' if i == 2 else 'unknown')
        prev = h.advance(self.group, self.probes(True, True), prev, self.config)
        self.assertEqual(prev['state'], 'failed')
        prev = h.advance(self.group, self.probes(True, True), prev, self.config)
        self.assertEqual(prev['state'], 'healthy')

    def test_identity_change_and_unknown_reset_failure(self):
        bad = dict(self.group, state='failed', bad=8, good=0)
        changed = dict(self.group, identity='new-cell')
        self.assertEqual(h.advance(changed, self.probes(False, False), bad, self.config)['bad'], 1)
        for reason in ('uplink_stale', 'status_unreadable', 'user_paused', 'sim_absent', 'sim_pin_required', 'no_cable', 'lan_mode'):
            row = h.advance(dict(self.group, reason=reason, available=False), [], bad, self.config)
            self.assertEqual(row['bad'], 0, reason)

    def test_paused_vpn_no_physical_success_dns_do_not_recover(self):
        ctx = dict(uplink=dict(active='cellular'), connected=False)
        groups = dict(cellular=dict(state='healthy', responding=2, reason='ready'),
                      vpn=dict(state='paused', reason='user_paused'))
        self.assertIsNone(h.candidate(groups, ctx, self.config))
        groups['vpn']['state'] = 'failed'
        self.assertEqual(h.candidate(groups, ctx, self.config), 'vpn_initiate')
        groups['cellular'] = dict(state='failed', responding=0, reason='all_targets_failed')
        self.assertIsNone(h.candidate(groups, ctx, self.config))
        self.config['recover_cellular'] = True
        self.assertEqual(h.candidate(groups, ctx, self.config), 'cellular_reconnect')
        ctx['uplink']['active'] = 'ethernet'
        groups['ethernet'] = dict(state='healthy', responding=2)
        self.assertEqual(h.candidate(groups, ctx, self.config), 'vpn_initiate')

    def test_boot_grace_cooldown_hour_limit_survive_clock_jumps(self):
        ctx = dict(boot='b', uptime_s=60, timestamp=1)
        self.assertEqual(h.budget({}, ctx, self.config)[1], 'boot_grace')
        attempts = dict(attempts=[dict(boot='b', uptime_s=800)])
        ctx.update(uptime_s=900, timestamp=9999999999)
        self.assertEqual(h.budget(attempts, ctx, self.config)[1], 'cooldown')
        attempts['attempts'].append(dict(boot='b', uptime_s=1200))
        ctx.update(uptime_s=1600, timestamp=0)
        self.assertEqual(h.budget(attempts, ctx, self.config)[1], 'hour_limit')
        ctx['uptime_s'] = 5000
        self.assertIsNone(h.budget(attempts, ctx, self.config)[1])

    def test_settings_reject_injection_duplicate_multicast_and_bad_limits(self):
        for target in ('1.1.1.1; reboot', '127.0.0.1', '224.0.0.1', '0.0.0.0', '255.255.255.255', '169.254.2.3'):
            with self.assertRaises(ValueError):
                h.validate(dict(self.config, wan_targets=[target, '223.5.5.5']))
        for override in (dict(wan_targets=['1.1.1.1'] * 2), dict(fail_rounds=1), dict(cooldown_seconds=1), dict(enabled=1)):
            with self.assertRaises(ValueError):
                h.validate(dict(self.config, **override))

    def test_pin_every_ping_no_fallback_and_reject_invalid_interface(self):
        with patch.object(h, 'command', return_value=(1, '')) as cmd:
            self.assertFalse(h.ping('ikecar', '10.8.8.8')['ok'])
            self.assertEqual(cmd.call_args[0][0][0:5], ['ping', '-4', '-n', '-I', 'ikecar'])
            self.assertEqual(cmd.call_count, 1)
            self.assertIsNone(h.ping('eth0;reboot', '1.1.1.1')['ok'])
            self.assertEqual(cmd.call_count, 1)

    def test_manual_pause_voice_and_initializing_guards(self):
        ctx = dict(timestamp=1000, uplink=dict(timestamp=1000, ready=True, changed=10),
                   running=False, sa_known=True, ike=dict(autostart=True),
                   wan=dict(autostart=True, pending=False, proto='qmi'))
        with patch.object(Path, 'exists', return_value=False):
            self.assertEqual(h.guarded('vpn_initiate', ctx, self.config), 'vpn_paused')
            self.config['recover_cellular'] = True
            with patch.object(h, 'ubus', return_value=dict(ok=True, call_query_accepted=True, active_calls=1, call_state='通话中')):
                self.assertEqual(h.guarded('cellular_reconnect', ctx, self.config), 'call_active')
            with patch.object(h, 'ubus', return_value={}):
                self.assertEqual(h.guarded('cellular_reconnect', ctx, self.config), 'call_unknown')
            with patch.object(h, 'ubus', return_value=dict(ok=True, call_query_accepted=True, active_calls=0, call_state='idle')):
                self.assertIsNone(h.guarded('cellular_reconnect', ctx, self.config))
            ctx['wan']['pending'] = True
            self.assertEqual(h.guarded('cellular_reconnect', ctx, self.config), 'cellular_paused_or_initializing')

    def test_revision_conflict_private_storage_and_truncated_journal(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            with patch.object(h, 'BASE', base), patch.object(h, 'CONFIG', base/'settings.json'), patch.object(h, 'REQUEST', base/'request'), patch.object(h, 'JOURNAL', base/'events.jsonl'):
                self.assertTrue(h.save(dict(settings=self.config, revision=0))['ok'])
                self.assertFalse(h.save(dict(settings=self.config, revision=0))['ok'])
                self.assertEqual((base/'settings.json').stat().st_mode & 0o777, 0o600)
                (base/'events.jsonl').write_bytes(b'{"event":"first"}\n{"event":"cut')
                h.append_event(dict(event='second'))
                self.assertEqual([e['event'] for e in h.events()], ['second', 'first'])
                self.assertEqual((base/'events.jsonl').stat().st_mode & 0o777, 0o600)

    def test_interrupted_cellular_recovery_still_brings_wan_up(self):
        with patch.object(h, 'command', return_value=(0, '')) as cmd, patch.object(h.time, 'sleep', side_effect=SystemExit):
            with self.assertRaises(SystemExit):
                h.recover('cellular_reconnect')
            self.assertEqual(cmd.call_args_list[-1][0][0][-1], 'up')

    def test_observe_only_complete_cycle_cannot_run_recovery(self):
        ctx = dict(boot='b', uptime_s=500, timestamp=1000, running=True, connected=False, sa_known=True,
            uplink=dict(timestamp=1000, mode='wan', active='cellular', ready=True, changed=1, carrier=False,
                cell=dict(up=True, default_route=True, device='wwan0', ip='192.0.2.2'), wire={}),
            modem={}, wan=dict(autostart=True), ike=dict(up=True, autostart=True))
        plans = h.plan_groups(ctx)
        state = dict(boot='b', revision=0, groups=dict(vpn=dict(plans['vpn'], bad=2, good=0, state='unknown')))
        config = dict(settings=self.config, revision=0)
        with patch.object(h, 'context', return_value=ctx), patch.object(h, 'ping', side_effect=lambda dev,t: dict(target=t, ok=True, latency_ms=10)), patch.object(h, 'command', return_value=(0, 'Address: 192.0.2.3')), patch.object(h, 'atomic') as writes, patch.object(h, 'append_event'), patch.object(h, 'recover') as recovery:
            result = h.step(config, state, allow_recovery=False)
            self.assertEqual(result['groups']['vpn']['state'], 'failed')
            self.assertEqual(writes.call_args[0][1]['suppressed'], 'observe_only')
            recovery.assert_not_called()

    def test_disabled_monitor_cannot_probe_or_recover(self):
        ctx = dict(boot='b', uptime_s=500, timestamp=1000, running=False, connected=False, sa_known=True,
                   uplink={}, modem={}, wan={}, ike={})
        with patch.object(h, 'context', return_value=ctx), patch.object(h, 'atomic'), patch.object(h, 'append_event'), patch.object(h, 'ping') as probe, patch.object(h, 'recover') as recovery:
            result = h.step(dict(settings=dict(self.config, enabled=False), revision=0), {})
            self.assertTrue(all(g['state']=='disabled' for g in result['groups'].values()))
            probe.assert_not_called(); recovery.assert_not_called()

    def test_recovery_records_attempt_before_command_and_cannot_repeat_in_cooldown(self):
        ctx = dict(boot='b', uptime_s=500, timestamp=1000, running=True, connected=False, sa_known=True,
            uplink=dict(timestamp=1000, mode='wan', active='cellular', ready=True, changed=1, carrier=False,
                cell=dict(up=True, default_route=True, device='wwan0', ip='192.0.2.2'), wire={}),
            modem={}, wan=dict(autostart=True), ike=dict(up=True, autostart=True))
        plans = h.plan_groups(ctx);config = dict(settings=self.config, revision=0)
        state = dict(boot='b', revision=0, groups=dict(vpn=dict(plans['vpn'], bad=2, good=0, state='unknown')))
        writes = []
        def recover(action):
            self.assertEqual(action, 'vpn_initiate')
            self.assertEqual(writes[-1][0], h.STATE)
            self.assertEqual(len(writes[-1][1]['attempts']), 1)
            return True
        with patch.object(h, 'context', return_value=ctx), patch.object(h, 'identity', return_value=h.ctx_identity(ctx)), patch.object(h, 'settings', return_value=config), patch.object(h, 'ping', side_effect=lambda dev,t: dict(target=t, ok=True, latency_ms=10)), patch.object(h, 'command', return_value=(0, 'Address: 192.0.2.3')), patch.object(h, 'atomic', side_effect=lambda path,data: writes.append((path, json.loads(json.dumps(data))))), patch.object(h, 'append_event'), patch.object(h, 'recover', side_effect=recover) as recovery, patch.object(Path, 'mkdir'), patch.object(Path, 'rmdir'), patch.object(Path, 'exists', return_value=False):
            result = h.step(config, state)
            self.assertEqual(recovery.call_count, 1)
            self.assertEqual(result['last_action']['accepted'], True)
            h.step(config, result)
            self.assertEqual(recovery.call_count, 1)
            self.assertEqual(writes[-1][1]['suppressed'], 'cooldown')


if __name__ == '__main__':
    unittest.main()
