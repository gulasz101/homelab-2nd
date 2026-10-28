#!/usr/bin/env bash
# factory-run.sh self-test (GUL-502, ADR-096). Throwaway repos in mktemp — never
# the real checkout. bash 3.2-safe (runs on the Air and in CI).
#
# What it proves, in the order the factory hits it:
#   1. the wrapper runs factory.py from the TOOLING checkout, not from the work
#      order's branch checkout that also holds a copy of it;
#   2. a commit pushed to origin/main is picked up by the very next call — no
#      pull, no restart (the GUL-502 failure: today's fixes never arrived);
#   3. the work order checkout is left alone, on its branch, with its diff;
#   4. a tooling copy with local edits, or a missing tooling copy, is exit 2
#      with a message — never a silent run of an old copy.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$ROOT/agents/factory/factory-run.sh"
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/factory-runner-XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PASS_N=0
FAIL_N=0
ok()  { printf '  ok  %s\n' "$1"; PASS_N=$((PASS_N + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL_N=$((FAIL_N + 1)); }

GITC="git -c user.email=t@example.com -c user.name=T"

seed_factory() { # seed-repo marker
  mkdir -p "$1/agents/factory"
  {
    printf '#!/usr/bin/env python3\n'
    printf 'import os, sys\n'
    printf 'print("factory-%s " + os.path.dirname(os.path.abspath(__file__)))\n' "$2"
    printf 'sys.exit(0)\n'
  } > "$1/agents/factory/factory.py"
  chmod +x "$1/agents/factory/factory.py"
}

ORIGIN="$TMP/origin.git"
git init -q --bare "$ORIGIN" >/dev/null 2>&1

# --- seed: origin/main holds factory marker v1 -----------------------------
SEED="$TMP/seed"
mkdir -p "$SEED"
git -C "$SEED" init -q -b main >/dev/null 2>&1
seed_factory "$SEED" v1
$GITC -C "$SEED" add -A >/dev/null 2>&1
$GITC -C "$SEED" commit -qm "factory v1" >/dev/null 2>&1
git -C "$SEED" remote add origin "$ORIGIN" >/dev/null 2>&1
git -C "$SEED" push -q origin main >/dev/null 2>&1

# --- work order checkout: same repo, on a branch, with its own copy ---------
WORK="$TMP/work"
git clone -q "$ORIGIN" "$WORK" >/dev/null 2>&1
git -C "$WORK" switch -q -c gul-900-fixture >/dev/null 2>&1
seed_factory "$WORK" workorder-branch
$GITC -C "$WORK" add -A >/dev/null 2>&1
$GITC -C "$WORK" commit -qm "work order diff" >/dev/null 2>&1

# --- tooling checkout: plain clone, the wrapper keeps it on origin/main -----
TOOLING="$TMP/tooling"
git clone -q "$ORIGIN" "$TOOLING" >/dev/null 2>&1

run_factory() { # tooling-dir -> writes $OUT/$ERR, sets $RC
  OUT="$TMP/out"; ERR="$TMP/err"
  FACTORY_TOOLING="$1" sh "$RUNNER" ping > "$OUT" 2> "$ERR"
  RC=$?
}

# 1. the tooling copy runs, not the branch copy
run_factory "$TOOLING"
if [ "$RC" = "0" ] && grep -q '^factory-v1 ' "$OUT"; then
  ok "first call runs factory.py from the tooling checkout"
else
  bad "first call: want factory-v1 (rc 0), got rc=$RC: $(cat "$OUT" "$ERR" | head -3)"
fi
if grep -q "$TOOLING/agents/factory" "$OUT"; then
  ok "first call: the executed file is the tooling copy"
else
  bad "first call: executed $(cat "$OUT") — not under $TOOLING"
fi
if [ "$(wc -l < "$OUT" | tr -d ' ')" = "1" ]; then
  ok "wrapper keeps stdout to factory.py's one line"
else
  bad "stdout has $(wc -l < "$OUT") lines; the wrapper must print only on stderr"
fi

# 2. a commit merged to main arrives on the next call, with no pull
seed_factory "$SEED" v2
$GITC -C "$SEED" add -A >/dev/null 2>&1
$GITC -C "$SEED" commit -qm "factory v2" >/dev/null 2>&1
git -C "$SEED" push -q origin main >/dev/null 2>&1
run_factory "$TOOLING"
if [ "$RC" = "0" ] && grep -q '^factory-v2 ' "$OUT"; then
  ok "a commit pushed to main is used by the very next call"
else
  bad "second call: want factory-v2, got rc=$RC: $(cat "$OUT" "$ERR" | head -3)"
fi

# 3. the work order checkout is untouched and still on its branch
if [ "$(git -C "$WORK" rev-parse --abbrev-ref HEAD)" = "gul-900-fixture" ]; then
  ok "work order checkout still on its branch"
else
  bad "work order checkout moved to $(git -C "$WORK" rev-parse --abbrev-ref HEAD)"
fi
if grep -q 'workorder-branch' "$WORK/agents/factory/factory.py" 2>/dev/null; then
  ok "work order checkout kept its own copy and its diff"
else
  bad "work order checkout's file was rewritten by the wrapper"
fi

# 4a. a locally edited tooling copy is refused, loudly
printf '\n# local edit\n' >> "$TOOLING/agents/factory/factory.py"
run_factory "$TOOLING"
if [ "$RC" = "2" ] && grep -q 'local changes' "$ERR" && [ ! -s "$OUT" ]; then
  ok "dirty tooling checkout: exit 2, nothing on stdout"
else
  bad "dirty tooling: want rc=2 + 'local changes', got rc=$RC: $(cat "$OUT" "$ERR" | head -3)"
fi
git -C "$TOOLING" checkout -q -- agents/factory/factory.py >/dev/null 2>&1

# 4b. a missing tooling copy is refused with the clone command
run_factory "$TMP/does-not-exist"
if [ "$RC" = "2" ] && grep -q 'git clone' "$ERR" && [ ! -s "$OUT" ]; then
  ok "missing tooling checkout: exit 2 naming the clone command"
else
  bad "missing tooling: want rc=2 + clone hint, got rc=$RC: $(cat "$OUT" "$ERR" | head -3)"
fi

printf '\n%d passed, %d failed\n' "$PASS_N" "$FAIL_N"
[ "$FAIL_N" = "0" ] || exit 1
exit 0
