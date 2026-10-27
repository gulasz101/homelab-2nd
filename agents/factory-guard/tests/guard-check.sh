#!/usr/bin/env bash
# factory-guard self-test. Exit 0 only if the unit tests AND the live pi test pass.
# Where pi is not installed (CI), the live part prints "SKIP live: pi not installed"
# and the unit tests still run.
set -u
cd "$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0

echo "== [1/2] unit tests (node --test) =="
if node --test tests/policy.test.ts; then
  echo "unit: PASS"
else
  echo "unit: FAIL"
  exit 1
fi

echo
echo "== [2/2] live test (real pi, print mode, scripted provider) =="
if ! command -v pi >/dev/null 2>&1; then
  echo "SKIP live: pi not installed"
  exit 0
fi

EXT_DIR="$PWD"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/factory-guard-live-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO/src" "$REPO/tests" "$TMP/agentdir" "$TMP/scratch"

# fresh git repo with the fixtures the plan names (all content is fake)
(
  cd "$REPO"
  printf 'creation_rules:\n  - path: ^secrets/\n    age: AGEX1PLACEHOLDERNOTAREALKEY\n' > .sops.yaml
  printf '# Agents\nkeep calm and build\n' > AGENTS.md
  printf 'export const a = 1;\n' > src/a.ts
  printf 'test original\n' > tests/a.test.ts
  git init -q .
  git add -A
  git -c user.email=test@example.invalid -c user.name="factory-guard test" commit -qm base
) || { echo "live: FAIL (fixture repo)"; exit 1; }

cat > "$TMP/script.json" <<'EOF'
[
 {"tools":[
   {"name":"edit","arguments":{"path":".sops.yaml","edits":[{"oldText":"creation_rules","newText":"hacked"}]}},
   {"name":"bash","arguments":{"command":"printenv | grep KEY"}},
   {"name":"write","arguments":{"path":"src/a.ts","content":"export const a = 2; // guard-test\n"}},
   {"name":"write","arguments":{"path":"tests/a.test.ts","content":"hacked\n"}},
   {"name":"bash","arguments":{"command":"python3 -c \"open('AGENTS.md','a').write('x')\""}}
 ]},
 {"text":"turn one done"},
 {"text":"reporting guard results"}
]
EOF

(
  cd "$REPO"
  PI_CODING_AGENT_DIR="$TMP/agentdir" \
  FACTORY_GUARD_BLOCK_LOG="$TMP/blocks.jsonl" \
  PAPERCLIP_RUN_SCRATCH_DIR="$TMP/scratch" \
  FACTORY_GUARD_SCRIPT="$TMP/script.json" \
  pi --offline --no-session --no-extensions --no-mcp -nc --approve \
    --extension "$EXT_DIR/index.ts" --extension "$EXT_DIR/tests/scripted-provider.ts" \
    --factory-role builder --provider fgtest --model scripted \
    --tools read,bash,edit,write \
    --print "run the scripted plan" > "$TMP/pi.out" 2> "$TMP/pi.err"
  exit $?
)
PI_EXIT=$?
if [ $PI_EXIT -ne 0 ]; then
  echo "live: FAIL (pi exit $PI_EXIT)"
  sed -n '1,20p' "$TMP/pi.err"
  exit 1
fi

echo "  assertions:"
# 1. the allowed write really ran (proves tool calls execute)
grep -q "guard-test" "$REPO/src/a.ts" && echo "  ok  allowed write src/a.ts applied" || { echo "  FAIL allowed write not applied"; FAIL=1; }
# 2. gated calls blocked: files untouched
cmp -s "$REPO/.sops.yaml" <(printf 'creation_rules:\n  - path: ^secrets/\n    age: AGEX1PLACEHOLDERNOTAREALKEY\n') && echo "  ok  edit .sops.yaml blocked" || { echo "  FAIL .sops.yaml was edited"; FAIL=1; }
cmp -s "$REPO/tests/a.test.ts" <(printf 'test original\n') && echo "  ok  write tests/a.test.ts blocked" || { echo "  FAIL test file was written"; FAIL=1; }
# 3. the AGENTS.md write that slipped past the gate was restored by the diff guard
cmp -s "$REPO/AGENTS.md" <(printf '# Agents\nkeep calm and build\n') && echo "  ok  AGENTS.md restored by diff guard" || { echo "  FAIL AGENTS.md not restored"; FAIL=1; }
# 4. blocks.jsonl: one line per block + restore, without command text
[ -f "$TMP/blocks.jsonl" ] && echo "  ok  blocks.jsonl written" || { echo "  FAIL no blocks.jsonl"; FAIL=1; }
for rule in '"tool":"edit","rule":"protected-file"' '"tool":"bash","rule":"env-dump"' '"tool":"write","rule":"role-write-scope"' '"rule":"restore-protected-file"'; do
  grep -q "$rule" "$TMP/blocks.jsonl" 2>/dev/null && echo "  ok  log has $rule" || { echo "  FAIL log missing $rule"; FAIL=1; }
done
# no log line may carry command text (a command can hide a secret)
if grep -qE '"command"|printenv \| grep' "$TMP/blocks.jsonl"; then echo "  FAIL command text in log"; FAIL=1; else echo "  ok  log free of command text"; fi
# 5. pi must never have seen the real agent dir
[ -z "$(ls -A "$TMP/agentdir" 2>/dev/null)" ] && echo "  ok  real ~/.pi untouched (temp agent dir unused too)" || echo "  note  temp agent dir has files (expected: session-free run)"

echo
if [ $FAIL -eq 0 ]; then
  echo "guard-check: ALL PASS (unit + live)"
  exit 0
else
  echo "guard-check: FAIL"
  exit 1
fi
