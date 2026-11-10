#!/usr/bin/env python3
"""Import the current Firefox gemini.google.com login into the running proxy BY HAND.

Why this exists: the scheduled guard deliberately pauses cookie re-import while the account is
`degraded` (a rate-limited account answers 429 and the candidate is deleted again — churn that
feeds the throttle). But a human who just logged in again in the browser wants that session in
the pool NOW, not when the cooldown expires. This is that button. It is the guard's own flow:

    add candidate -> POST /admin/api/cookies/<id>/check -> keep or drop

A working cookie is never dropped before the candidate verifies, and nothing secret is printed —
only cookie counts, ids and the pass/fail of the check.

Usage (on m1max, where the container and the Firefox profile live):

    python3 ~/homelab/gemini-web2api-guard/manual_import.py            # import, retire older entries
    python3 ~/homelab/gemini-web2api-guard/manual_import.py --keep-old # import, keep the others
    python3 ~/homelab/gemini-web2api-guard/manual_import.py --list     # just show the pool

Exit codes: 0 imported and validated, 2 candidate failed /check (dropped, pool untouched),
1 setup problem (no cookie, no candidate).
"""
import json
import os
import sys
import urllib.error
import urllib.request

GUARD_DIR = os.environ.get("GUARD_DIR") or os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, GUARD_DIR)
import guard  # noqa: E402  - reuse harvest_firefox() and the env reader: one source of truth

TOK = guard.env().get("ADMIN_TOKEN", "")


def api(path, method="GET", body=None, timeout=90):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(guard.PROXY + path, data=data, method=method,
                                 headers={"Authorization": "Bearer " + TOK,
                                          "Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:
        return 0, repr(e)


def pool():
    code, body = api("/admin/api/cookies")
    try:
        d = json.loads(body)
    except Exception:
        return code, [], {}
    return code, d.get("items", []), d


def show(items, tag):
    print("%s: %d entry/ies" % (tag, len(items)))
    for i in items:
        print("   id=%s label=%r enabled=%s health=%s fail_count=%s"
              % (i.get("id"), i.get("label"), i.get("enabled"), i.get("health"),
                 i.get("fail_count")))


def main(argv):
    code, before, meta = pool()
    print("pool GET ->", code)
    show(before, "BEFORE")
    if code != 200:
        print("FATAL: admin API unreachable (is the container up? see README)")
        return 1
    if "--list" in argv:
        return 0

    ck = guard.harvest_firefox()
    if not ck:
        print("FATAL: no usable cookie in the Firefox profile - nothing imported.")
        print("       Open Firefox on this Mac, log in to gemini.google.com, then run again.")
        return 1
    print("harvest: ok, %d chars, %d key cookies" % (len(ck), ck.count("=")))

    ccode, cbody = api("/admin/api/cookies", "POST",
                       {"label": "wojtek-ai-pro", "cookie": ck,
                        "note": "manual import by hand (see gemini-web2api/README.md)"})
    try:
        new_id = json.loads(cbody).get("id")
    except Exception:
        new_id = None
    print("add candidate ->", ccode, "id =", new_id)
    if not new_id:
        print("FATAL: candidate not added (HTTP %s): %s" % (ccode, cbody[:200]))
        return 1

    kcode, kbody = api("/admin/api/cookies/%s/check" % new_id, "POST")
    try:
        ok = bool(json.loads(kbody).get("ok"))
    except Exception:
        ok = False
    print("/check candidate ->", kcode, "ok =", ok)

    if not ok:
        api("/admin/api/cookies/%s" % new_id, "DELETE")
        print("DROP: candidate is not a live login; removed it, previous pool untouched.")
        show(pool()[1], "AFTER")
        return 2

    if "--keep-old" not in argv:
        retired = 0
        for i in before:
            if i.get("id") != new_id:
                api("/admin/api/cookies/%s" % i["id"], "DELETE")
                retired += 1
        print("KEEP: candidate validated; retired %d older entry/ies" % retired)

    code, after, meta = pool()
    show(after, "AFTER")
    print("enabled count:", meta.get("enabled"))
    print("RESULT: imported id=%s, check ok=%s" % (new_id, ok))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
