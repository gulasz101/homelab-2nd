"""Unit tests for apps/host-watch/server.py (H2-336, AC3/AC4).

The module under test is extracted from the ConfigMap that ships to the cluster
(see hostwatch-unit-check.sh), so this tests the code that actually runs, not a
copy of it:

    HOSTWATCH_MODULE=/tmp/hostwatch/server.py python3 -m unittest test_hostwatch -v
"""
import importlib.util
import json
import os
import sys
import tempfile
import unittest

MODULE_PATH = os.environ.get("HOSTWATCH_MODULE")
if not MODULE_PATH:
    raise SystemExit("HOSTWATCH_MODULE is not set: run through hostwatch-unit-check.sh")

_spec = importlib.util.spec_from_file_location("hostwatch", MODULE_PATH)
hw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hw)  # raises if the shipped script is not importable


class ClassifyTests(unittest.TestCase):
    """The whole probe is one judgement call: what counts as 'up'."""

    def test_200_is_up(self):
        self.assertTrue(hw.classify(200))

    def test_204_is_up(self):
        self.assertTrue(hw.classify(204))

    def test_302_is_up(self):
        # A login redirect means the app is alive and guarding its UI.
        self.assertTrue(hw.classify(302))

    def test_401_is_up(self):
        self.assertTrue(hw.classify(401))

    def test_403_is_up(self):
        self.assertTrue(hw.classify(403))

    def test_404_is_up(self):
        # Wrong path on a live origin is our bug, not an outage.
        self.assertTrue(hw.classify(404))

    def test_500_is_down(self):
        self.assertFalse(hw.classify(500))

    def test_502_is_down(self):
        # THE 2026-10-29 signature: tunnel up, origin dead.
        self.assertFalse(hw.classify(502))

    def test_503_is_down(self):
        self.assertFalse(hw.classify(503))

    def test_network_error_is_down(self):
        self.assertFalse(hw.classify(0))

    def test_negative_is_down(self):
        self.assertFalse(hw.classify(-1))


class TargetStateTests(unittest.TestCase):
    def test_starts_unprobed(self):
        t = hw.TargetState("paperclip", "https://paperclip.voitech.dev")
        self.assertIsNone(t.success)
        self.assertEqual(t.consecutive_failures, 0)
        self.assertFalse(t.failing(3))

    def test_three_failures_reach_the_threshold(self):
        t = hw.TargetState("paperclip", "https://paperclip.voitech.dev")
        t.record(502, 0.2, now=1000.0)
        self.assertEqual(t.consecutive_failures, 1)
        self.assertFalse(t.failing(3))
        t.record(502, 0.2, now=1060.0)
        t.record(503, 0.2, now=1120.0)
        self.assertEqual(t.consecutive_failures, 3)
        self.assertTrue(t.failing(3), "3 consecutive failures must trip a >=3 threshold")

    def test_success_resets_the_counter(self):
        t = hw.TargetState("paperclip", "https://paperclip.voitech.dev")
        t.record(0, 0.2, now=1000.0)
        t.record(0, 0.2, now=1060.0)
        t.record(200, 0.2, now=1120.0)
        self.assertEqual(t.consecutive_failures, 0)
        self.assertEqual(t.success, 1)
        self.assertEqual(t.status, 200)

    def test_two_failures_alone_do_not_trip(self):
        t = hw.TargetState("paperclip", "https://paperclip.voitech.dev")
        t.record(502, 0.2, now=1000.0)
        t.record(502, 0.2, now=1060.0)
        self.assertFalse(t.failing(3), "one 60s blip must not page anyone")


class HeartbeatTests(unittest.TestCase):
    def _store(self, token):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as fh:
            fh.write(token)
        self.addCleanup(os.unlink, path)
        return hw.HeartbeatStore(token_file=path, grace=420), path

    def test_configured_when_token_present(self):
        store, _ = self._store("s3cret-token\n")
        self.assertTrue(store.configured())

    def test_fail_closed_without_token_file(self):
        store = hw.HeartbeatStore(token_file="/nonexistent/host-watch/token", grace=420)
        self.assertFalse(store.configured())
        self.assertFalse(store.accept("anything"), "an unseeded receiver must reject every beat")

    def test_accepts_the_exact_token_only(self):
        store, _ = self._store("s3cret-token\n")
        self.assertTrue(store.accept("s3cret-token"))
        self.assertFalse(store.accept("s3cret-toke"))
        self.assertFalse(store.accept(""))
        self.assertFalse(store.accept(None))

    def test_age_is_none_before_the_first_beat(self):
        store, _ = self._store("t")
        self.assertIsNone(store.age(now=1000.0))
        self.assertEqual(store.last_seen_timestamp(), 0.0)

    def test_age_after_a_beat(self):
        store, _ = self._store("t")
        store.record(json.dumps({
            "host": "paperclip-air", "ts": 1000, "console_user": "paperclip",
            "components": {"paperclip": True, "hermes-gateway": False},
        }), now=1000.0)
        self.assertEqual(store.age(now=1300.0), 300.0)
        self.assertEqual(store.host, "paperclip-air")
        self.assertEqual(store.console_user, "paperclip")
        self.assertEqual(store.components, {"paperclip": True, "hermes-gateway": False})

    def test_missing_beat_crosses_the_grace_window(self):
        store, _ = self._store("t")
        store.record(json.dumps({"host": "paperclip-air", "components": {}}), now=1000.0)
        self.assertFalse(store.stale(now=1419.0, ))
        self.assertTrue(store.stale(now=1421.0), "grace is 420s: 421s of silence is an outage")

    def test_bad_payload_is_rejected_not_fatal(self):
        store, _ = self._store("t")
        self.assertFalse(store.record("not json", now=1000.0))
        self.assertIsNone(store.age(now=1001.0))


class MetricsTests(unittest.TestCase):
    def _render(self, targets=None, store=None, now=2000.0):
        targets = targets or []
        store = store or hw.HeartbeatStore(token_file="/nonexistent", grace=420)
        return hw.render_metrics(targets, store, now=now)

    def test_required_metric_names(self):
        t = hw.TargetState("paperclip", "https://paperclip.voitech.dev")
        t.record(502, 0.3, now=1990.0)
        text = self._render([t])
        for name in (
            "hostwatch_probe_success",
            "hostwatch_probe_status_code",
            "hostwatch_probe_consecutive_failures",
            "hostwatch_probe_duration_seconds",
            "hostwatch_probe_last_probe_timestamp_seconds",
            "hostwatch_heartbeat_configured",
            "hostwatch_heartbeat_last_seen_timestamp_seconds",
            "hostwatch_heartbeat_rejected_total",
            "hostwatch_up",
        ):
            self.assertIn(name, text, "%s must be exported (the alert rules key on it)" % name)

    def test_counter_reflects_a_failing_target(self):
        t = hw.TargetState("paperclip", "https://paperclip.voitech.dev")
        t.record(0, 5.0, now=1990.0)
        t.record(0, 5.0, now=1995.0)
        t.record(0, 5.0, now=2000.0)
        text = self._render([t])
        line = [l for l in text.splitlines()
                if l.startswith("hostwatch_probe_consecutive_failures")][0]
        self.assertTrue(line.endswith(" 3"), "rule expr is >= 3, exported value must reach 3: %r" % line)

    def test_never_probed_target_does_not_claim_up(self):
        t = hw.TargetState("chat", "https://chat.voitech.dev")
        text = self._render([t])
        self.assertIn('hostwatch_probe_success{target="chat"} 0', text,
                      "an unprobed target must not read as healthy")

    def test_heartbeat_metrics_without_a_beat(self):
        text = self._render()
        self.assertIn("hostwatch_heartbeat_configured 0", text)
        self.assertIn("hostwatch_heartbeat_last_seen_timestamp_seconds 0", text)
        self.assertNotIn("hostwatch_heartbeat_age_seconds", text,
                         "age is only meaningful after a first beat")

    def test_component_metrics(self):
        store = hw.HeartbeatStore(token_file="/nonexistent", grace=420)
        store.record(json.dumps({"host": "paperclip-air",
                                 "components": {"paperclip": True, "syncthing": False}}), now=1990.0)
        text = self._render(store=store)
        self.assertIn('hostwatch_component_up{component="paperclip"} 1', text)
        self.assertIn('hostwatch_component_up{component="syncthing"} 0', text)


class ProbeLoopTests(unittest.TestCase):
    def test_probe_once_records_every_target(self):
        targets = [hw.TargetState("a", "https://a.example"), hw.TargetState("b", "https://b.example")]
        codes = {"https://a.example": 200, "https://b.example": 503}

        def fake_fetch(url, timeout=None):
            return codes[url]

        failures = hw.probe_once(targets, fetch=fake_fetch, now=1000.0)
        self.assertEqual([t.status for t in targets], [200, 503])
        self.assertEqual(failures, 1)
        self.assertEqual(targets[0].consecutive_failures, 0)
        self.assertEqual(targets[1].consecutive_failures, 1)

    def test_parse_targets(self):
        parsed = hw.parse_targets("paperclip=https://paperclip.voitech.dev,"
                                  "chat=https://chat.voitech.dev")
        self.assertEqual([t.name for t in parsed], ["paperclip", "chat"])
        self.assertEqual(parsed[1].url, "https://chat.voitech.dev")

    def test_parse_targets_ignores_blank_entries(self):
        parsed = hw.parse_targets(" paperclip=https://paperclip.voitech.dev , ,")
        self.assertEqual(len(parsed), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
