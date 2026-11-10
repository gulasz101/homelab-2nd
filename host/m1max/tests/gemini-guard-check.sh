#!/bin/bash
# ---------------------------------------------------------------------------
# gemini-guard-check.sh — static guard for host/m1max/gemini-web2api/guard.py.
#
# GUL-1279: the watchdog ran from ~/.hermes on the Max, which ADR-128 turned into
# a read-only tombstone FILE. Every run failed with "[Errno 20] Not a directory"
# for 30 ticks and nothing noticed, because the failure was a path, not a bug.
# So the path is now a checked property, not a convention.
#
# Why static: the guard needs the container, the admin token and a Firefox
# profile — none of which CI has. What CAN be proven anywhere is the shape:
#   - it parses (the Max runs it with whatever python3 Apple ships)
#   - no code path (only comments) reaches under ~/.hermes, and the default
#     state/env directory is the non-Hermes one
#   - the cookie list it harvests still matches the proxy's required names
#   - the canary is attributed by request-log id and asks for the paid model
#
# Exit 0 = all good. Exit 1 = at least one guard failed.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET="$HERE/gemini-web2api/guard.py"
RC=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }

[ -f "$TARGET" ] || { printf 'FAIL: %s is missing\n' "$TARGET"; exit 1; }

# 1. parses. `compile()` and not py_compile: py_compile writes __pycache__ into the tree
#    even with PYTHONDONTWRITEBYTECODE, which then shows up as a CI diff.
if python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$TARGET" 2>/dev/null; then
  pass "python3 parses guard.py"
else
  fail "python3 rejected guard.py"
fi

# 2. nothing but a comment may point at ~/.hermes (ADR-128: it is a tombstone file)
HERMES=$(awk '{ line=$0; sub(/^[[:space:]]+/, "", line); if (substr(line,1,1) != "#" && $0 ~ /\.hermes/) print FNR": "$0 }' "$TARGET")
if [ -n "$HERMES" ]; then
  fail "guard.py still reaches under ~/.hermes (ADR-128: that path is a FILE on the Max):"
  printf '      %s\n' "$(printf '%s' "$HERMES" | head -3)"
else
  pass "no non-comment ~/.hermes path"
fi

# 3. the state/env home is the non-Hermes directory, and it is overridable for tests
grep -q 'GUARD_DIR' "$TARGET" && grep -q 'homelab/gemini-web2api-guard' "$TARGET" \
  && pass "GUARD_DIR default = ~/homelab/gemini-web2api-guard" \
  || fail "GUARD_DIR default is not ~/homelab/gemini-web2api-guard"

# 4. all nine cookies the proxy needs are still harvested
MISSING=""
for c in SID HSID SSID APISID SAPISID __Secure-1PSID __Secure-1PSIDTS __Secure-1PAPISID __Secure-1PSIDCC; do
  grep -q -- "$c" "$TARGET" || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then fail "cookie list lost:$MISSING"; else pass "all 9 required cookies named"; fi

# 5. the canary asks for a paid model and is keyed on the monotonic log id
grep -q 'CANARY_MODEL = "gemini-4-argon"' "$TARGET" \
  && pass "CANARY_MODEL = gemini-4-argon" \
  || fail "CANARY_MODEL changed (the paid-tier check would stop meaning anything)"
grep -q 'upstream_model' "$TARGET" \
  && pass "canary judged on upstream_model" \
  || fail "canary no longer reads upstream_model - cannot tell paid from free tier"

# 6. GUL-1280: the import decision must fingerprint SESSION cookies only.
#    __Secure-1PSIDTS and __Secure-1PSIDCC are refreshed by Firefox on every google.com
#    visit, so hashing the whole harvested string turned "the browser was used" into
#    "the user logged in again": one wasted Google /check round-trip and one pool churn
#    per tick, measured as three imports in 35 min on 2026-11-10.
#    Check the FINGERPRINT's own allowed list (STABLE), never a file-wide grep — the
#    harvest list has to keep all nine names, so a whole-file grep can never catch this.
FP_OUT=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$TARGET" <<'PY'
import sys
path = sys.argv[1]
ns = {"__name__": "guard_under_test"}
exec(compile(open(path).read(), path, "exec"), ns)   # exec, not import: no __pycache__
SESSION = ["SID", "HSID", "SSID", "APISID", "SAPISID", "__Secure-1PSID", "__Secure-1PAPISID"]
ROTATING = ["__Secure-1PSIDTS", "__Secure-1PSIDCC"]
stable, fp, errs = ns.get("STABLE"), ns.get("fingerprint"), []
if not isinstance(stable, list):
    errs.append("no STABLE list in guard.py")
if not callable(fp):
    errs.append("no fingerprint() helper in guard.py")
if stable is not None and fp is not None:
    if sorted(stable) != sorted(SESSION):
        errs.append("STABLE is %r, expected the session cookies %r" % (stable, SESSION))
    grew = [c for c in ROTATING if c in stable]
    if grew:
        errs.append("fingerprint hashes rotating cookie(s): %s" % ", ".join(grew))

    def cookie(psidts, psidcc, sid="s"):
        vals = dict(zip(SESSION, ["v%s" % c for c in SESSION]))
        vals.update({"SID": sid, "__Secure-1PSIDTS": psidts, "__Secure-1PSIDCC": psidcc})
        return "; ".join("%s=%s" % (k, vals[k])
                         for k in SESSION + ROTATING)
    rotated = cookie("newer-ts", "newer-cc")
    same = cookie("older-ts", "older-cc")
    relogin = cookie("older-ts", "older-cc", sid="other-session")
    if fp(rotated) != fp(same):
        errs.append("a rotated __Secure-1PSIDTS/1PSIDCC still changes the fingerprint")
    if fp(rotated) == fp(relogin):
        errs.append("a changed SID does not change the fingerprint - a real re-login is missed")
print("; ".join(errs) if errs else "fingerprint = session cookies only")
PY
)
if [ "$FP_OUT" = "fingerprint = session cookies only" ]; then
  pass "$FP_OUT (rotating cookies ignored, re-login detected)"
else
  fail "cookie fingerprint: ${FP_OUT:-python check produced no verdict}"
fi
# the hash that decides an import must be the fingerprint, not the whole harvested string
grep -q 'hashlib.sha256(fingerprint(ck)' "$TARGET" \
  && pass "import decision hashes fingerprint(ck)" \
  || fail "import decision no longer hashes fingerprint(ck) - rotating cookies re-import every tick"

# 7. the hand-import helper ships next to it and reuses the same harvest
HELPER="$HERE/gemini-web2api/manual-import.py"
if [ -f "$HELPER" ] && python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$HELPER" 2>/dev/null; then
  pass "manual-import.py present and parses"
else
  fail "manual-import.py missing or does not parse"
fi

[ $RC -eq 0 ] && printf '\ngemini guard: all checks passed\n'
exit $RC
