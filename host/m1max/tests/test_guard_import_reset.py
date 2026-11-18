#!/usr/bin/env python3
"""test_guard_import_reset.py — GUL-1386: a fresh cookie restarts the health clock.

A cookie replacement must not inherit the previous pair's health window. Today
`note_entitlement()` does `st.setdefault("healthy_since", now)`, so an old
`healthy_since` survives an import and the state file reports "healthy for 3 h 13 min"
about a cookie that was replaced three minutes earlier (measured 2026-11-11 21:31Z).

Contract under test — `guard.py` grows one place that records "a new cookie took over":

    def note_import(st, cookie_hash, now):
        st["cookie_hash"] = cookie_hash
        st["healthy_since"] = now          # not setdefault
        st["degraded_accum_s"] = 0
        st.pop("degraded_since", None)
        return st

and the successful-import site calls `note_import(st, h, now)` instead of assigning
`st["cookie_hash"]` by hand.

Stdlib only, plain `python3`, no pytest, no Docker, no proxy, no Firefox, no network:
the guard module is loaded and `guard.STATE` is pointed at a temp file, so the live
state on the Max (`~/homelab/gemini-web2api-guard/cookie_guard_state.json`) is never
read as input and never written.

Exit 0 = every case passed, 1 = at least one case failed.
"""
import importlib.util
import os
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
HOSTDIR = os.path.dirname(HERE)                                  # host/m1max
GUARD = os.path.join(HOSTDIR, "gemini-web2api", "guard.py")

CASES = 8
FAILURES = []


def case(name, fn):
    try:
        fn()
    except AssertionError as e:
        FAILURES.append(name)
        print("FAIL %s — %s" % (name, e))
    except Exception:
        FAILURES.append(name)
        print("FAIL %s — unexpected error:\n%s" % (name, traceback.format_exc()))
    else:
        print("ok   %s" % name)


def note_import(guard):
    """The function guard.py must grow. A missing one is a one-line failure, not a traceback."""
    fn = getattr(guard, "note_import", None)
    assert fn is not None, (
        "guard.py has no note_import — the import path has no place to reset the health clock")
    assert callable(fn), "guard.note_import is not callable"
    return fn


def load_guard():
    """Import guard.py as a module (its main() is behind __main__, so importing is inert)."""
    spec = importlib.util.spec_from_file_location("guard_under_test", GUARD)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load %s" % GUARD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    guard = load_guard()

    # The live state file must not be touched. Remember what it was before we repoint STATE.
    live_state_path = guard.STATE
    live_before = None
    if os.path.exists(live_state_path):
        with open(live_state_path, "rb") as f:
            live_before = f.read()

    tmpdir = tempfile.mkdtemp(prefix="gul1386-guard-")
    tmp_state = os.path.join(tmpdir, "cookie_guard_state.json")
    guard.STATE = tmp_state          # never the real one (GUL-1386 asks for a temp state file)

    now = int(time.time())
    old_since = now - (3 * 3600 + 13 * 60)     # the 18:21:28Z value from the incident
    stale = {
        "cookie_hash": "old-cookie-hash",
        "healthy_since": old_since,
        "entitlement": "ok",
        "degraded_accum_s": 6 * 3600,
        "degraded_since": now - 2 * 3600,
        "degraded_long": "long",
        "checked_at": now - 1800,
    }

    case("guard.py defines note_import(st, cookie_hash, now)",
         lambda: _defines_note_import(guard))
    case("note_import resets an old healthy_since to now (not setdefault)",
         lambda: _resets_healthy_since(guard, stale, now, old_since))
    case("note_import clears the degraded window and records the new cookie hash",
         lambda: _clears_degraded(guard, stale, now))
    case("note_import returns the state dict it mutated",
         lambda: _returns_state(guard, stale, now))
    case("a second import moves healthy_since forward again",
         lambda: _second_import_moves_forward(guard, stale, now))
    case("the reset survives the state file round-trip",
         lambda: _survives_round_trip(guard, tmp_state, now))
    case("the successful-import path calls note_import, not a hand-set cookie_hash",
         lambda: _import_path_calls_it())
    case("the live state file was not written",
         lambda: _live_state_untouched(live_state_path, live_before))

    if FAILURES:
        print("\n%d of %d case(s) failed: %s" % (len(FAILURES), CASES, ", ".join(FAILURES)))
        return 1
    print("\nall %d cases passed" % CASES)
    return 0


def _defines_note_import(guard):
    fn = note_import(guard)
    try:
        fn({}, "h", 1)
    except TypeError as e:
        raise AssertionError("note_import does not take (st, cookie_hash, now): %s" % e)


def _resets_healthy_since(guard, stale, now, old_since):
    st = dict(stale)
    note_import(guard)(st, "new-cookie-hash", now)
    got = st.get("healthy_since")
    assert got is not None, "note_import dropped healthy_since instead of resetting it"
    assert int(got) != int(old_since), (
        "healthy_since is still the pre-import value %r: the health window straddles a dead "
        "cookie" % (got,))
    assert int(got) == now, "healthy_since is %r, expected the import time %r" % (got, now)


def _clears_degraded(guard, stale, now):
    st = dict(stale)
    note_import(guard)(st, "new-cookie-hash", now)
    assert st.get("cookie_hash") == "new-cookie-hash", (
        "cookie_hash is %r, expected the newly imported hash" % (st.get("cookie_hash"),))
    assert int(st.get("degraded_accum_s") or 0) == 0, (
        "degraded_accum_s is %r after an import, expected 0 — the old cookie's degraded time "
        "must not carry over" % (st.get("degraded_accum_s"),))
    assert "degraded_since" not in st, (
        "degraded_since survived an import (%r) — the degraded window did not restart"
        % (st.get("degraded_since"),))


def _returns_state(guard, stale, now):
    st = dict(stale)
    out = note_import(guard)(st, "new-cookie-hash", now)
    assert out is st, "note_import returned %r, expected the same state dict" % (out,)


def _second_import_moves_forward(guard, stale, now):
    fn = note_import(guard)
    st = dict(stale)
    fn(st, "hash-b", now)
    first = int(st["healthy_since"])
    fn(st, "hash-c", now + 600)
    second = int(st["healthy_since"])
    assert second == now + 600, "second import left healthy_since at %r, expected %r" % (
        second, now + 600)
    assert second > first, "healthy_since did not move forward on a second import"
    assert st["cookie_hash"] == "hash-c", "cookie_hash is %r after the second import" % (
        st.get("cookie_hash"),)


def _survives_round_trip(guard, tmp_state, now):
    st = {"cookie_hash": "old", "healthy_since": now - 90000, "degraded_accum_s": 7200,
          "degraded_since": now - 3600}
    note_import(guard)(st, "new-cookie-hash", now)
    guard.STATE = tmp_state
    guard.write_state(st)
    assert os.path.exists(tmp_state), "write_state() did not write %s" % tmp_state
    back = guard.read_state()
    assert int(back.get("healthy_since") or 0) == now, (
        "state file has healthy_since %r, expected %r" % (back.get("healthy_since"), now))
    assert back.get("cookie_hash") == "new-cookie-hash", (
        "state file has cookie_hash %r" % (back.get("cookie_hash"),))
    assert int(back.get("degraded_accum_s") or 0) == 0, "state file kept degraded_accum_s"
    assert "degraded_since" not in back, "state file kept degraded_since"


def _import_path_calls_it():
    with open(GUARD) as f:
        src = f.read()
    assert "def note_import(" in src, "guard.py has no note_import definition"
    main_src = src[src.index("def main("):]
    assert "note_import(st" in main_src, (
        "main() never calls note_import(st, ...) — the successful-import path still has no "
        "reset")
    assert 'st["cookie_hash"] = h' not in main_src, (
        'main() still assigns st["cookie_hash"] = h in the import path instead of calling '
        "note_import")


def _live_state_untouched(live_state_path, live_before):
    if live_before is None:
        return                       # no live state on this box; nothing to protect
    assert os.path.exists(live_state_path), "the live state file disappeared during the test"
    with open(live_state_path, "rb") as f:
        after = f.read()
    assert after == live_before, "the test wrote the live state file %s" % live_state_path


if __name__ == "__main__":
    sys.exit(main())
