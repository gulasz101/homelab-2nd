#!/usr/bin/env python3
"""path-parity.py — assert looks_like_test_path in factory.py agrees with
looksLikeTestPath in agents/factory-guard/policy.ts (via path-parity.ts JSON).
Usage: python3 path-parity.py paths.json ts-output.json — exit 0 on agreement.
"""
import importlib.util
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "factory", os.path.join(here, "..", "factory.py"))
factory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(factory)

paths = json.load(open(sys.argv[1]))
ts = json.load(open(sys.argv[2]))
bad = 0
for p in paths:
    py = factory.looks_like_test_path(p)
    t = ts.get(p)
    if t is None:
        print("MISSING from TS output: %r" % p)
        bad += 1
    elif py != t:
        print("DISAGREE %r: python=%s ts=%s" % (p, py, t))
        bad += 1
print("parity: %d paths checked, %d disagreements" % (len(paths), bad))
sys.exit(0 if bad == 0 and len(paths) >= 20 else 1)
