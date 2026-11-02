#!/usr/bin/env python3
"""Unit tests for loki-rule-guard (GUL-805).

The guard is loaded from the ConfigMap the CronJob actually mounts
(GUARD_MODULE, set by tests/guard-check.sh), so this suite tests the shipped
script and not a second copy of it.
"""

from __future__ import annotations

import importlib.util
import os
import unittest

MODULE_PATH = os.environ.get("GUARD_MODULE")
if not MODULE_PATH:
    raise SystemExit("GUARD_MODULE must point at the loki_rule_guard.py to test")
spec = importlib.util.spec_from_file_location("loki_rule_guard", MODULE_PATH)
assert spec is not None and spec.loader is not None, f"cannot load {MODULE_PATH}"
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class CanaryRuleTest(unittest.TestCase):
    def test_carries_the_stamp_the_guard_will_look_for(self):
        text = guard.canary_rule(1793618400)
        self.assertIn(f'canary_stamp: "{1793618400}"', text)
        self.assertIn(f"- name: {guard.CANARY_GROUP}", text)

    def test_can_never_fire(self):
        # `vector(0) > 1` has no series. A canary that can fire is an outage the
        # detector inflicts on itself.
        text = guard.canary_rule(1)
        self.assertIn("expr: vector(0) > 1", text)
        self.assertNotIn("vector(1)", text)

    def test_is_parseable_looking_yaml_without_external_dependencies(self):
        text = guard.canary_rule(1)
        self.assertTrue(text.startswith("groups:\n"))
        self.assertEqual(text.count("groups:"), 1)
        self.assertEqual(text.count("- alert: LokiRuleDeliveryCanary"), 1)


class MessageTest(unittest.TestCase):
    def test_ok_message_is_a_recovery_notice(self):
        text = guard.format_message("ok", {}, 17, 20, 42, "")
        self.assertIn("live again", text)
        self.assertIn("20 rule groups from 17 rule files", text)
        self.assertIn("canary stamp 42s old", text)

    def test_drift_names_the_file_and_the_configmap(self):
        text = guard.format_message(
            "drift", {"llm-hub-errors.yaml": "llm-hub-error-rules"}, 16, 19, 900, ""
        )
        self.assertIn("broken", text)
        self.assertIn("`llm-hub-errors.yaml`", text)
        self.assertIn("`llm-hub-error-rules`", text)
        self.assertIn("rollout restart statefulset/loki", text)

    def test_stale_message_names_the_sidecar_and_the_threshold(self):
        text = guard.format_message("stale", {}, 16, 19, 1500, "")
        self.assertIn("25 min old", text)
        self.assertIn("threshold 15 min", text)
        self.assertIn("loki-0", text)

    def test_unverified_does_not_prescribe_a_loki_restart(self):
        # Restarting loki because the guard cannot read the API would be treating
        # the detector's fault as the workload's.
        text = guard.format_message("unverified", {}, 0, 0, None, "boom")
        self.assertIn("cannot be verified", text)
        self.assertIn("boom", text)
        self.assertNotIn("rollout restart statefulset/loki", text)


class ImportSafetyTest(unittest.TestCase):
    def test_module_import_does_not_touch_the_cluster(self):
        # Importing with no service-account files present must succeed: everything
        # cluster-shaped lives inside functions, which is what makes this suite
        # runnable outside a pod.
        self.assertTrue(callable(guard.main))
        self.assertFalse(os.path.exists(f"{guard.SA_DIR}/token"))


if __name__ == "__main__":
    unittest.main()
