#!/usr/bin/env bash
# factory-guard self-test. Exit 0 only if the unit tests AND the live role tests pass.
#
# Usage: tests/guard-check.sh [--role executor|tester|builder|readonly]...
#   --role <name>  run the live matrix for that role only (repeatable)
#   no --role      run ALL FOUR roles — this is what CI and the daily self-test run
#
# Each role gets its own scripted-provider pi run in a fresh temp git repo
# (zero tokens): one allowed step that MUST apply and its forbidden steps that
# MUST be refused at the tool_call gate. Refusal is proven by the block log —
# the diff guard may clean up after a broken gate, so a restore entry alone
# proves nothing; we assert the gate line ("tool":"write" etc.), not the
# backstop. Where pi is not installed (CI), the live parts print
# "SKIP live: pi not installed" and the unit tests still run.
set -u
cd "$(cd "$(dirname "$0")/.."; pwd)"

VALID_ROLES="executor tester builder readonly"
ROLES_REQUESTED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role)
      if [ $# -lt 2 ]; then echo "guard-check: --role needs a value ($VALID_ROLES)" >&2; exit 2; fi
      ROLES_REQUESTED="$ROLES_REQUESTED $2"; shift 2 ;;
    --role=*)
      ROLES_REQUESTED="$ROLES_REQUESTED ${1#*=}"; shift ;;
    -h|--help)
      echo "usage: guard-check.sh [--role executor|tester|builder|readonly]..."; exit 0 ;;
    *)
      echo "guard-check: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$ROLES_REQUESTED" ]; then
  ROLES="$VALID_ROLES"
else
  for r in $ROLES_REQUESTED; do
    if ! echo " $VALID_ROLES " | grep -q " $r "; then
      echo "guard-check: invalid role '$r' (want: $VALID_ROLES)" >&2; exit 2
    fi
  done
  ROLES="$ROLES_REQUESTED"
fi

FAIL=0

echo "== [1/3] unit tests (node --test) =="
if node --test tests/policy.test.ts; then
  echo "unit: PASS"
else
  echo "unit: FAIL"
  exit 1
fi

echo
echo "== [2/3] live role matrix (real pi, print mode, scripted provider, zero tokens) =="
if ! command -v pi >/dev/null 2>&1; then
  echo "SKIP live: pi not installed"
  exit 0
fi

EXT_DIR="$PWD"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/factory-guard-live-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# fresh git repo with the fixtures the matrix needs (all content is fake)
make_fixture() {
  local repo="$1"
  mkdir -p "$repo/src" "$repo/tests"
  (
    cd "$repo"
    printf 'creation_rules:\n  - path: ^secrets/\n    age: AGEX1PLACEHOLDERNOTAREALKEY\n' > .sops.yaml
    printf '# Agents\nkeep calm and build\n' > AGENTS.md
    printf '# Readme\nfixture\n' > README.md
    printf 'export const a = 1;\n' > src/a.ts
    printf 'test original\n' > tests/a.test.ts
    git init -q .
    git add -A
    git -c user.email=test@example.invalid -c user.name="factory-guard test" commit -qm base
  )
}

# $1=role $2=repo $3=script.json $4=blocklog $5=run-tmp-dir
run_pi() {
  (
    cd "$2"
    PI_CODING_AGENT_DIR="$5/agentdir" \
    FACTORY_GUARD_BLOCK_LOG="$4" \
    PAPERCLIP_RUN_SCRATCH_DIR="$5/scratch" \
    FACTORY_GUARD_SCRIPT="$3" \
    pi --offline --no-session --no-extensions --no-mcp -nc --approve \
      --extension "$EXT_DIR/index.ts" --extension "$EXT_DIR/tests/scripted-provider.ts" \
      --factory-role "$1" --provider fgtest --model scripted \
      --tools read,bash,edit,write \
      --print "run the scripted plan" > "$5/pi.out" 2> "$5/pi.err"
    exit $?
  )
}

log_has() { # $1=role $2=log $3=pattern
  grep -q "$3" "$2" 2>/dev/null && echo "  ok  [$1] log has $3" \
    || { echo "  FAIL [$1] log missing $3"; FAIL=1; }
}
log_lacks() { # $1=role $2=log $3=pattern
  if grep -q "$3" "$2" 2>/dev/null; then
    echo "  FAIL [$1] log must not have $3 (that call had to be allowed)"; FAIL=1
  else
    echo "  ok  [$1] log free of $3"
  fi
}
assert_dirty() { # $1=role $2=repo $3=expected-changed-paths (newline list, may be empty)
  local got
  got=$(git -C "$2" status --porcelain --untracked-files=all | sed 's/^...//')
  if [ "$got" = "$3" ]; then
    echo "  ok  [$1] worktree carries exactly the allowed changes"
  else
    echo "  FAIL [$1] worktree state: got '$got' want '$3'"; FAIL=1
  fi
}
assert_one_commit() { # $1=role $2=repo
  [ "$(git -C "$2" rev-list --count HEAD)" = "1" ] \
    && echo "  ok  [$1] no commit was made by the run" \
    || { echo "  FAIL [$1] the run created a commit"; FAIL=1; }
}

MATRIX_SUMMARY=""
for ROLE in $ROLES; do
  ROLE_FAIL_BEFORE=$FAIL
  echo
  echo "-- role: $ROLE"
  RT="$TMP/$ROLE"; REPO="$RT/repo"; LOG="$RT/blocks.jsonl"
  mkdir -p "$RT/agentdir" "$RT/scratch"
  if ! make_fixture "$REPO"; then
    echo "  FAIL [$ROLE] fixture repo"; FAIL=1; MATRIX_SUMMARY="$MATRIX_SUMMARY $ROLE=FAIL"; continue
  fi

  case "$ROLE" in
    executor)
      # allowed: write src/a.ts. forbidden: edit .sops.yaml, printenv.
      cat > "$RT/script.json" <<'EOF'
[
 {"tools":[
   {"name":"edit","arguments":{"path":".sops.yaml","edits":[{"oldText":"creation_rules","newText":"hacked"}]}},
   {"name":"bash","arguments":{"command":"printenv | grep KEY"}}
 ]},
 {"tools":[
   {"name":"write","arguments":{"path":"src/a.ts","content":"export const a = 2; // guard-test\n"}}
 ]},
 {"text":"turn done"},
 {"text":"reporting guard results"}
]
EOF
      ;;
    tester)
      # allowed: write tests/a.test.ts. forbidden: write src/a.ts.
      cat > "$RT/script.json" <<'EOF'
[
 {"tools":[
   {"name":"write","arguments":{"path":"src/a.ts","content":"export const a = 2; // tester-touched-source\n"}}
 ]},
 {"tools":[
   {"name":"write","arguments":{"path":"tests/a.test.ts","content":"test guard-selftest applied\n"}}
 ]},
 {"text":"turn done"},
 {"text":"reporting guard results"}
]
EOF
      ;;
    builder)
      # allowed: write src/a.ts. forbidden: write tests/a.test.ts, git commit.
      # Extra coverage kept from the original builder run: the python3 AGENTS.md
      # write deliberately SLIPS past the gate and must be restored by the diff
      # guard. Each call that needs ordering gets its own turn — pi runs the
      # tools of one assistant message in parallel.
      cat > "$RT/script.json" <<'EOF'
[
 {"tools":[
   {"name":"write","arguments":{"path":"tests/a.test.ts","content":"hacked\n"}},
   {"name":"bash","arguments":{"command":"python3 -c \"open('AGENTS.md','a').write('x')\""}}
 ]},
 {"tools":[
   {"name":"write","arguments":{"path":"src/a.ts","content":"export const a = 2; // guard-test\n"}}
 ]},
 {"tools":[
   {"name":"bash","arguments":{"command":"git commit -qam should-be-blocked"}}
 ]},
 {"text":"turn done"},
 {"text":"reporting guard results"}
]
EOF
      ;;
    readonly)
      # allowed: read README.md, and one stage hand-off PATCH to the Paperclip
      # API (GUL-468). forbidden: any write/edit, git commit, touch, and any
      # curl that is not that PATCH.
      cat > "$RT/script.json" <<'EOF'
[
 {"tools":[
   {"name":"read","arguments":{"path":"README.md"}}
 ]},
 {"tools":[
   {"name":"bash","arguments":{"command":"curl -s -X PATCH http://127.0.0.1:3900/api/issues/abc -H 'Content-Type: application/json' -d '{\"status\":\"in_review\"}'"}}
 ]},
 {"tools":[
   {"name":"bash","arguments":{"command":"curl -s -X PUT http://127.0.0.1:3900/api/issues/abc/documents/findings -H 'Content-Type: application/json' -d '{\"body\":\"# Findings\\n```json\\n[]\\n```\\n\"}'"}}
 ]},
 {"tools":[
   {"name":"bash","arguments":{"command":"curl -s -X POST http://127.0.0.1:3900/api/issues/abc -d '{\"status\":\"done\"}'"}}
 ]},
 {"tools":[
   {"name":"write","arguments":{"path":"x.txt","content":"nope\n"}},
   {"name":"edit","arguments":{"path":"README.md","edits":[{"oldText":"fixture","newText":"hacked"}]}}
 ]},
 {"tools":[
   {"name":"bash","arguments":{"command":"git commit -qam should-be-blocked"}}
 ]},
 {"tools":[
   {"name":"bash","arguments":{"command":"touch x"}}
 ]},
 {"text":"turn done"},
 {"text":"reporting guard results"}
]
EOF
      ;;
  esac

  run_pi "$ROLE" "$REPO" "$RT/script.json" "$LOG" "$RT"
  if [ $? -ne 0 ]; then
    echo "  FAIL [$ROLE] live run (pi exit non-zero)"
    sed -n '1,20p' "$RT/pi.err"
    FAIL=1; MATRIX_SUMMARY="$MATRIX_SUMMARY $ROLE=FAIL"; continue
  fi

  case "$ROLE" in
    executor)
      grep -q "guard-test" "$REPO/src/a.ts" \
        && echo "  ok  [executor] allowed write src/a.ts applied" \
        || { echo "  FAIL [executor] allowed write not applied"; FAIL=1; }
      assert_dirty executor "$REPO" "src/a.ts"
      log_has executor "$LOG" '"role":"executor"'
      log_has executor "$LOG" '"tool":"edit","rule":"protected-file"'
      log_has executor "$LOG" '"tool":"bash","rule":"env-dump"'
      ;;
    tester)
      grep -q "guard-selftest" "$REPO/tests/a.test.ts" \
        && echo "  ok  [tester] allowed write tests/a.test.ts applied" \
        || { echo "  FAIL [tester] allowed write not applied"; FAIL=1; }
      assert_dirty tester "$REPO" "tests/a.test.ts"
      log_has tester "$LOG" '"role":"tester"'
      log_has tester "$LOG" '"tool":"write","rule":"role-write-scope"'
      ;;
    builder)
      grep -q "guard-test" "$REPO/src/a.ts" \
        && echo "  ok  [builder] allowed write src/a.ts applied" \
        || { echo "  FAIL [builder] allowed write not applied"; FAIL=1; }
      cmp -s "$REPO/tests/a.test.ts" <(printf 'test original\n') \
        && echo "  ok  [builder] tests/a.test.ts untouched" \
        || { echo "  FAIL [builder] test file was written"; FAIL=1; }
      cmp -s "$REPO/AGENTS.md" <(printf '# Agents\nkeep calm and build\n') \
        && echo "  ok  [builder] AGENTS.md restored by diff guard" \
        || { echo "  FAIL [builder] AGENTS.md not restored"; FAIL=1; }
      assert_dirty builder "$REPO" "src/a.ts"
      assert_one_commit builder "$REPO"
      log_has builder "$LOG" '"role":"builder"'
      log_has builder "$LOG" '"tool":"write","rule":"role-write-scope"'
      log_has builder "$LOG" '"tool":"bash","rule":"role-no-commit"'
      log_has builder "$LOG" '"rule":"restore-protected-file"'
      ;;
    readonly)
      # allowed read: proven by the gate never having blocked a read call
      log_lacks readonly "$LOG" '"tool":"read"'
      assert_dirty readonly "$REPO" ""
      assert_one_commit readonly "$REPO"
      log_has readonly "$LOG" '"role":"readonly"'
      log_has readonly "$LOG" '"tool":"write","rule":"role-write-forbidden"'
      log_has readonly "$LOG" '"tool":"edit","rule":"role-write-forbidden"'
      log_has readonly "$LOG" '"tool":"bash","rule":"role-no-commit"'
      log_has readonly "$LOG" '"tool":"bash","rule":"readonly-allowlist"'
      # GUL-468: two curls in the plan — the hand-off PATCH (allowed) and a POST
      # (refused). Every block is logged, the log carries no command text, so the
      # allowlist count is the proof: 2 = touch + the POST curl, 3 = the PATCH was
      # refused as well.
      ALLOW_N="$(grep -c '"rule":"readonly-allowlist"' "$LOG" || true)"
      if [ "$ALLOW_N" = "2" ]; then
        echo "  ok  [readonly] hand-off PATCH allowed, non-PATCH curl refused (2 allowlist blocks)"
      else
        echo "  FAIL [readonly] expected 2 readonly-allowlist blocks (touch + POST curl), got $ALLOW_N"
        FAIL=1
      fi
      ;;
  esac

  # no log line may carry command text (a command can hide a secret)
  if grep -qE '"command"|printenv \| grep' "$LOG"; then
    echo "  FAIL [$ROLE] command text in log"; FAIL=1
  else
    echo "  ok  [$ROLE] log free of command text"
  fi

  if [ "$FAIL" = "$ROLE_FAIL_BEFORE" ]; then
    MATRIX_SUMMARY="$MATRIX_SUMMARY $ROLE=PASS"
  else
    MATRIX_SUMMARY="$MATRIX_SUMMARY $ROLE=FAIL"
  fi
done

echo
echo "-- matrix:$MATRIX_SUMMARY"

if echo " $ROLES " | grep -q " executor "; then
  echo
  echo "== [3/3] live: committed violations blame the RUN, not the branch (GUL-424) =="
  REPO2="$TMP/repo2"
  mkdir -p "$REPO2/.github/workflows" "$REPO2/src" "$TMP/agentdir2" "$TMP/scratch2"
  (
    cd "$REPO2"
    git init -q -b main .
    git config user.email test@example.invalid
    git config user.name "factory-guard test"
    printf '# Agents\nkeep calm and build\n' > AGENTS.md
    printf 'name: check\n' > .github/workflows/check.yaml
    printf 'export const a = 1;\n' > src/a.ts
    git add -A
    git commit -qm base
    git checkout -qb shared
    # FOREIGN work on the branch, committed BEFORE this run exists: AGENTS.md is
    # violated only here, check.yaml here and again in the run's own commit.
    printf '# Agents\nkeep calm and build\nforeign\n' > AGENTS.md
    printf 'name: check\n# foreign\n' > .github/workflows/check.yaml
    git commit -qam "foreign violation committed by an earlier run"
  ) || { echo "  FAIL (fixture repo2)"; FAIL=1; }

  cat > "$TMP/script2.json" <<'EOF'
[
 {"tools":[
   {"name":"bash","arguments":{"command":"python3 -c \"open('.github/workflows/check.yaml','a').write('run-violation')\""}}
 ]},
 {"tools":[
   {"name":"bash","arguments":{"command":"git add -A && git commit -qm run-violation"}}
 ]},
 {"text":"committed and done"},
 {"text":"reporting guard results"}
]
EOF

  (
    cd "$REPO2"
    PI_CODING_AGENT_DIR="$TMP/agentdir2" \
    FACTORY_GUARD_BLOCK_LOG="$TMP/blocks2.jsonl" \
    PAPERCLIP_RUN_SCRATCH_DIR="$TMP/scratch2" \
    FACTORY_GUARD_SCRIPT="$TMP/script2.json" \
    pi --offline --no-session --no-extensions --no-mcp -nc --approve \
      --extension "$EXT_DIR/index.ts" --extension "$EXT_DIR/tests/scripted-provider.ts" \
      --factory-role executor --provider fgtest --model scripted \
      --tools read,bash,edit,write \
      --print "run the scripted plan" > "$TMP/pi2.out" 2> "$TMP/pi2.err"
    exit $?
  )
  PI2_EXIT=$?
  if [ $PI2_EXIT -ne 0 ]; then
    echo "  FAIL live committed-blame (pi exit $PI2_EXIT)"
    sed -n '1,20p' "$TMP/pi2.err"
    FAIL=1
  else
    [ "$(git -C "$REPO2" log -1 --format=%s)" = "run-violation" ] \
      && echo "  ok  run's own protected-path commit exists" \
      || { echo "  FAIL scripted run did not commit"; FAIL=1; }
    CV2="$TMP/blocks2.jsonl"
    n_all=$(grep -cF '"rule":"committed-violation"' "$CV2" 2>/dev/null || true)
    n_run=$(grep -cF '"rule":"committed-violation","path":".github/workflows/check.yaml"' "$CV2" 2>/dev/null || true)
    n_foreign=$(grep -F '"rule":"committed-violation"' "$CV2" 2>/dev/null | grep -cF 'AGENTS.md' || true)
    # the run committed check.yaml in violation: exactly ONE log line (settle fires
    # twice with the continuation report - dedupe must hold)
    [ "${n_all:-0}" = "1" ] && [ "${n_run:-0}" = "1" ] \
      && echo "  ok  this run's commit logged once as committed-violation" \
      || { echo "  FAIL committed-violation lines: all=${n_all:-?} run=${n_run:-?} (want 1/1)"; FAIL=1; }
    # AGENTS.md was violated by an EARLIER commit on the branch: blame stays off
    [ "${n_foreign:-0}" = "0" ] \
      && echo "  ok  foreign branch commit not blamed on this run" \
      || { echo "  FAIL foreign commit blamed on this run (${n_foreign} lines)"; FAIL=1; }
  fi
else
  echo
  echo "== [3/3] committed-blame: SKIP (runs with the executor role only; pass --role executor or no flag) =="
fi

echo
if [ $FAIL -eq 0 ]; then
  echo "guard-check: ALL PASS (unit + live:$MATRIX_SUMMARY)"
  exit 0
else
  echo "guard-check: FAIL"
  exit 1
fi
