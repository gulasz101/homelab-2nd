#!/usr/bin/env bash
# factory.py self-test (GUL-436). Throwaway git repos in mktemp dirs — never
# the real checkout. bash 3.2-safe (runs on the Air and in CI).
# Exit 0 only if every case passes.
set -u
# GUL-2080: an inherited GIT_DIR (a git hook, a parent tool) made the fixture repos
# below write into the real checkout. Drop every repo-locating git variable first.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_CONFIG GIT_CONFIG_GLOBAL
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FACTORY="$ROOT/agents/factory/factory.py"
PC="$ROOT/agents/factory/pc.py"
PY="python3 -I"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/factory-check-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS_N=0
FAIL_N=0

ok()   { printf '  ok  %s\n' "$1"; PASS_N=$((PASS_N + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL_N=$((FAIL_N + 1)); }

# expect_rc NAME WANT_RC — check the exit code of the last command
expect_rc() {
  local name="$1" want="$2" rc="$3"
  if [ "$rc" = "$want" ]; then ok "$name (rc=$rc)"; else bad "$name (want rc=$want got $rc)"; cat "$LAST_ERR" >&2; fi
}

# expect_json_ok NAME — stdout JSON of the last run must carry ok:true/false
LAST_OUT="$TMP/last.out"; LAST_ERR="$TMP/last.err"
run() { # runs a command, captures rc/out/err
  "$@" > "$LAST_OUT" 2> "$LAST_ERR"
  LAST_RC=$?
}
json_is() { # want true|false
  $PY -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["ok"] is (sys.argv[2]=="true") else 1)' "$LAST_OUT" "$1"
}

expect_json_field() { # path value (dotted; numeric components index lists)
  $PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
sys.exit(0 if str(d)==sys.argv[3] else 1)' "$LAST_OUT" "$2" "$3"
}

# ---------- fixtures ----------
new_repo() { # $1 dir — git repo with a base commit
  local r="$1"
  mkdir -p "$r/src"
  ( cd "$r"
    git init -q -b main .
    git config user.email test@example.invalid
    git config user.name "factory test"
    printf 'print("a")\n' > src/a.py
    printf '#!/bin/sh\necho hello\n' > README.md
    git add -A
    git commit -qm base )
}

spec_file() { # $1 path $2 allowedPaths-json $3 maxdiff $4 check-cmd
  cat > "$1" <<EOF
# Spec for the test

Some markdown for people.

\`\`\`json
{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "code",
 "allowedPaths": $2,
 "acs": [{"id": "AC-1", "text": "a works", "check": $4}],
 "maxDiffLines": $3}
\`\`\`
EOF
}

findings_file() { cat > "$1"; }

# ---------- 1. lint-spec ----------
echo "== lint-spec =="
SPEC="$TMP/spec.json.md"
spec_file "$SPEC" '["src/**", "tests/**"]' 400 '"bash tests/ac.sh"'
run $PY "$FACTORY" lint-spec --spec "$SPEC"; expect_rc "valid spec" 0 "$LAST_RC"
json_is true && ok "lint ok:true" || bad "lint ok:true"

printf 'no fence here\n' > "$TMP/spec-nofence.md"
run $PY "$FACTORY" lint-spec --spec "$TMP/spec-nofence.md"; expect_rc "no json block -> fail" 1 "$LAST_RC"
spec_file "$TMP/spec-2json.md" '["src/**"]' 10 '"x"'; printf '\n```json\n{"a":1}\n```\n' >> "$TMP/spec-2json.md"
run $PY "$FACTORY" lint-spec --spec "$TMP/spec-2json.md"; expect_rc "two json blocks -> fail" 1 "$LAST_RC"
cat > "$TMP/spec-dupid.md" <<'EOF'
```json
{"repo": "o/r", "base": "main", "kind": "code", "allowedPaths": ["src/**"],
 "acs": [{"id": "AC-1", "text": "t", "check": "true"}, {"id": "AC-1", "text": "u", "check": "true"}],
 "maxDiffLines": 5}
```
EOF
run $PY "$FACTORY" lint-spec --spec "$TMP/spec-dupid.md"; expect_rc "duplicate AC id -> fail" 1 "$LAST_RC"
cat > "$TMP/spec-badkind.md" <<'EOF'
```json
{"repo": "o/r", "base": "main", "kind": "vibes", "allowedPaths": ["src/**"],
 "acs": [{"id": "AC-1", "text": "t", "check": "true"}], "maxDiffLines": 5}
```
EOF
run $PY "$FACTORY" lint-spec --spec "$TMP/spec-badkind.md"; expect_rc "bad kind -> fail" 1 "$LAST_RC"
cat > "$TMP/spec-unknownkey.md" <<'EOF'
```json
{"repo": "o/r", "base": "main", "kind": "code", "allowedPaths": ["src/**"],
 "acs": [{"id": "AC-1", "text": "t", "check": "true"}], "maxDiffLines": 5, "yolo": true}
```
EOF
run $PY "$FACTORY" lint-spec --spec "$TMP/spec-unknownkey.md"; expect_rc "unknown key -> fail" 1 "$LAST_RC"

# GUL-853: a check that can never print an AC line must not lint. These two are
# the exact rev-2 checks of GUL-833 that cost three red rounds and an escalation.
cat > "$TMP/spec-silent-validate.md" <<'EOF'
```json
{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "code", "allowedPaths": ["openspec/**"],
 "acs": [{"id": "AC-1", "text": "the change validates", "check": "npx --yes @fission-ai/openspec@1.15.0 validate static-miss-404 --strict && ! grep -q '\\[ \\]' openspec/changes/static-miss-404/tasks.md"}],
 "maxDiffLines": 40}
```
EOF
run $PY "$FACTORY" lint-spec --spec "$TMP/spec-silent-validate.md"
expect_rc "silent validator check -> fail" 1 "$LAST_RC"
grep -q 'can never print an AC line' "$LAST_OUT" \
  && ok "silent validator check: reason names the fix" \
  || bad "silent validator check: reason names the fix"
cat > "$TMP/spec-silent-exists.md" <<'EOF'
```json
{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "code", "allowedPaths": ["apps/**"],
 "acs": [{"id": "AC-6", "text": "static assets ship", "check": "grep -q 'static-serving' apps/api/src/index.ts && for f in icon-192.png icon-512.png; do test -f apps/web/public/$f || exit 1; done"}],
 "maxDiffLines": 40}
```
EOF
run $PY "$FACTORY" lint-spec --spec "$TMP/spec-silent-exists.md"
expect_rc "silent file-exists check -> fail" 1 "$LAST_RC"
cat > "$TMP/spec-reports-inline.md" <<'EOF'
```json
{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "code", "allowedPaths": ["apps/**"],
 "acs": [{"id": "AC-1", "text": "a ships", "check": "sh -c 'if test -f apps/a.txt; then echo \"AC-1: PASS\"; else echo \"AC-1: FAIL apps/a.txt missing\"; exit 1; fi'"}],
 "maxDiffLines": 40}
```
EOF
run $PY "$FACTORY" lint-spec --spec "$TMP/spec-reports-inline.md"
expect_rc "wrapped check that echoes its AC line -> ok" 0 "$LAST_RC"
cat > "$TMP/spec-reports-script.md" <<'EOF'
```json
{"repo": "gulasz101/homelab-2nd", "base": "main", "kind": "code", "allowedPaths": ["apps/**"],
 "acs": [{"id": "AC-1", "text": "a ships", "check": "bash apps/api/tests/a-check.sh"},
         {"id": "AC-2", "text": "b ships", "check": "bash apps/api/tests/a-check.sh"}],
 "maxDiffLines": 40}
```
EOF
run $PY "$FACTORY" lint-spec --spec "$TMP/spec-reports-script.md"
expect_rc "delegated check script covering two ACs -> ok" 0 "$LAST_RC"

# ---------- 2. check-red ----------
echo "== check-red =="
R="$TMP/red"
new_repo "$R"
spec_file "$TMP/red-spec.md" '["src/**", "tests/**"]' 400 '"bash tests/ac.sh"'
mkdir -p "$R/tests"
printf '#!/bin/bash\necho "AC-1: FAIL a is broken"\nexit 1\n' > "$R/tests/ac.sh"
run $PY "$FACTORY" check-red --repo "$R" --base HEAD --spec "$TMP/red-spec.md"
expect_rc "red: tests only, AC fails" 0 "$LAST_RC"
printf 'print("early impl!")\n' > "$R/src/impl.py"
run $PY "$FACTORY" check-red --repo "$R" --base HEAD --spec "$TMP/red-spec.md"
expect_rc "red: non-test path touched -> fail" 1 "$LAST_RC"
rm "$R/src/impl.py"
printf '#!/bin/bash\necho "AC-1: PASS"\nexit 0\n' > "$R/tests/ac.sh"
run $PY "$FACTORY" check-red --repo "$R" --base HEAD --spec "$TMP/red-spec.md"
expect_rc "red: AC already passes -> fail" 1 "$LAST_RC"
printf '#!/bin/bash\necho boom\nexit 3\n' > "$R/tests/ac.sh"
run $PY "$FACTORY" check-red --repo "$R" --base HEAD --spec "$TMP/red-spec.md"
expect_rc "red: setup error (exit 3) -> rc 2, FAILS" 2 "$LAST_RC"
json_is false && ok "red setup: ok:false" || bad "red setup: ok:false"
grep -q "setup error" "$LAST_OUT" && ok "red setup: reason names setup error" || bad "red setup reason"
# GUL-853: a check that prints no AC line is the setup error that cost GUL-833
# three red rounds. lint-spec now refuses it at start; this case keeps the red
# stage's own answer (exit 2, never a verdict) honest as the backstop.
printf '#!/bin/bash\ntest -f src/a.py\n' > "$R/tests/silent.sh"
spec_file "$TMP/red-silent.md" '["src/**", "tests/**"]' 400 '"bash tests/silent.sh"'
run $PY "$FACTORY" check-red --repo "$R" --base HEAD --spec "$TMP/red-silent.md"
expect_rc "red: check prints no AC line -> setup error" 2 "$LAST_RC"
grep -q "no AC line" "$LAST_OUT" && ok "red silent: reason says no AC line" || bad "red silent reason"
rm "$R/tests/silent.sh"
printf '#!/bin/bash\nexit 1\n' > "$R/tests/ac.sh"
run $PY "$FACTORY" check-red --repo "$R" --base HEAD --spec "$TMP/red-spec.md"
expect_rc "red: missing AC line -> rc 2" 2 "$LAST_RC"
mkdir -p "$R/tests"
printf '#!/bin/bash\necho "AC-1: FAIL nope"\nexit 1\n' > "$R/tests/ac.sh"
mkdir -p "$R/other/tests"
printf '#!/bin/bash\necho "AC-1: FAIL nope"\nexit 1\n' > "$R/other/tests/elsewhere.sh"
run $PY "$FACTORY" check-red --repo "$R" --base HEAD --spec "$TMP/red-spec.md"
expect_rc "red: test path outside allowedPaths -> fail" 1 "$LAST_RC"
grep -q "outside allowedPaths" "$LAST_OUT" && ok "red: allowedPaths violation named" || bad "red allowedPaths reason"
rm -rf "$R/other"

# ---------- 3. check-green ----------
echo "== check-green =="
G="$TMP/green"
new_repo "$G"
spec_file "$G/spec.md" '["src/**", "tests/**"]' 400 '"bash tests/ac.sh"'
# the red check DERIVES its verdict from src/a.py, so the same (byte-identical)
# test file is FAIL at red and PASS at green — that is how TDD works.
mkdir -p "$G/tests"
cat > "$G/tests/ac.sh" <<'AC'
#!/bin/bash
if grep -q "fixed" src/a.py; then echo "AC-1: PASS"; exit 0; else echo "AC-1: FAIL broken"; exit 1; fi
AC
( cd "$G" && git add -A && git commit -qm "red: failing test" )
RED_SHA="$(git -C "$G" rev-parse HEAD)"
# Builder: source-only change in the working tree, tests untouched since red
printf 'print("a")\nprint("fixed")\n' > "$G/src/a.py"
run $PY "$FACTORY" check-green --repo "$G" --red "$RED_SHA" --spec "$G/spec.md"
expect_rc "green: tests byte-identical, AC pass" 0 "$LAST_RC"
# special case 2: a test file changed after the red commit must FAIL
printf '# drifted after red\n' >> "$G/tests/ac.sh"
run $PY "$FACTORY" check-green --repo "$G" --red "$RED_SHA" --spec "$G/spec.md"
expect_rc "green: test changed after red commit -> FAILS" 1 "$LAST_RC"
grep -q "tests/ac.sh" "$LAST_OUT" && ok "green drift: names the test path" || bad "green drift reason"
git -C "$G" checkout -q "$RED_SHA" -- tests/ac.sh
# out-of-scope change
mkdir -p "$G/plugins"
printf 'print("out of scope")\n' > "$G/plugins/evil.py"
run $PY "$FACTORY" check-green --repo "$G" --red "$RED_SHA" --spec "$G/spec.md"
expect_rc "green: path outside allowedPaths -> fail" 1 "$LAST_RC"
rm -rf "$G/plugins"
# regression: the fix goes away -> AC reports FAIL again
printf 'print("a")\n' > "$G/src/a.py"
run $PY "$FACTORY" check-green --repo "$G" --red "$RED_SHA" --spec "$G/spec.md"
expect_rc "green: AC FAIL -> fail" 1 "$LAST_RC"
printf 'print("a")\nprint("fixed")\n' > "$G/src/a.py"
# repo scripts/check.sh must exit 0
mkdir -p "$G/scripts"
printf '#!/bin/bash\nexit 1\n' > "$G/scripts/check.sh"
run $PY "$FACTORY" check-green --repo "$G" --red "$RED_SHA" --spec "$G/spec.md"
expect_rc "green: repo scripts/check.sh failing -> fail" 1 "$LAST_RC"
grep -q "scripts/check.sh" "$LAST_OUT" && ok "green: repo check.sh violation named" || bad "green check.sh reason"
rm -rf "$G/scripts"
run $PY "$FACTORY" check-green --repo "$G" --red "$RED_SHA" --spec "$G/spec.md"
expect_rc "green: clean source-only diff" 0 "$LAST_RC"

# ---- GUL-1801: main's own work after the red commit is not the stage's ----
# main moved after the red commit and touched a test path plus a path outside
# allowedPaths; the work-order branch then took both through an update-branch
# merge. That is PR #252 in miniature: check-green counted main's commits as stage
# changes and reported six reasons nobody in the stage had caused. Both must be
# dropped before the test-path comparison and before the allowedPaths check.
git -C "$G" checkout -q -b main-side "$RED_SHA"
printf '# main: tightened the check\n' >> "$G/tests/ac.sh"
mkdir -p "$G/plugins" && printf 'print("main")\n' > "$G/plugins/from-main.py"
git -C "$G" add "$G/plugins/from-main.py"
git -C "$G" commit -q -m "main: tighten the check" -- tests/ac.sh plugins/from-main.py
MAIN_SHA="$(git -C "$G" rev-parse HEAD)"
git -C "$G" update-ref refs/remotes/origin/main "$MAIN_SHA"
git -C "$G" checkout -q "$RED_SHA"
git -C "$G" checkout -q "$MAIN_SHA" -- tests/ac.sh plugins/from-main.py
run $PY "$FACTORY" check-green --repo "$G" --red "$RED_SHA" --spec "$G/spec.md"
expect_rc "green (GUL-1801): main's own changes are not stage work -> PASS" 0 "$LAST_RC"
grep -q 'tests/ac.sh' "$LAST_OUT" && ok "green (GUL-1801): the dropped test path is listed in fromMain" \
  || bad "green (GUL-1801): fromMain does not name tests/ac.sh"
# ...but a test path the stage changed on top of main's still fails.
printf '# stage: changed the check too\n' >> "$G/tests/ac.sh"
run $PY "$FACTORY" check-green --repo "$G" --red "$RED_SHA" --spec "$G/spec.md"
expect_rc "green (GUL-1801): the stage changing a test path main also touched -> FAILS" 1 "$LAST_RC"
grep -q "test path differs from the red commit" "$LAST_OUT" && ok "green (GUL-1801): names the test path it refused" \
  || bad "green (GUL-1801): no test-path reason"
git -C "$G" checkout -q "$MAIN_SHA" -- tests/ac.sh
run $PY "$FACTORY" check-green --repo "$G" --red "$RED_SHA" --spec "$G/spec.md"
expect_rc "green (GUL-1801): main's version restored -> PASS again" 0 "$LAST_RC"

# ---------- 4. check-findings ----------
echo "== check-findings =="
FR="$TMP/find"
new_repo "$FR"
( cd "$FR" && printf 'print("changed")\n' > src/a.py )
cat > "$FR/findings-ok.md" <<'EOF'
review notes for humans
```json
[{"id": "F-1", "file": "src/a.py", "line": 1, "severity": "blocking", "claim": "print is silly"}]
```
EOF
run $PY "$FACTORY" check-findings --repo "$FR" --base HEAD --findings "$FR/findings-ok.md"
expect_rc "findings: in diff, line exists" 0 "$LAST_RC"
sed 's/"line": 1,/"line": 99,/' "$FR/findings-ok.md" > "$FR/findings-line.md"
run $PY "$FACTORY" check-findings --repo "$FR" --base HEAD --findings "$FR/findings-line.md"
expect_rc "findings: line beyond EOF -> fail" 1 "$LAST_RC"
sed 's#src/a.py#src/untouched.py#' "$FR/findings-ok.md" > "$FR/findings-file.md"
run $PY "$FACTORY" check-findings --repo "$FR" --base HEAD --findings "$FR/findings-file.md"
expect_rc "findings: file not in diff -> fail" 1 "$LAST_RC"
sed 's/blocking/curious/' "$FR/findings-ok.md" > "$FR/findings-sev.md"
run $PY "$FACTORY" check-findings --repo "$FR" --base HEAD --findings "$FR/findings-sev.md"
expect_rc "findings: bad severity -> fail" 1 "$LAST_RC"
printf '```json\n[]\n```\n' > "$FR/findings-empty.md"
run $PY "$FACTORY" check-findings --repo "$FR" --base HEAD --findings "$FR/findings-empty.md"
expect_rc "findings: empty list -> pass" 0 "$LAST_RC"

# ---------- 5. check-verdicts ----------
echo "== check-verdicts =="
cat > "$TMP/f2.md" <<'EOF'
```json
[{"id": "F-1", "file": "src/a.py", "line": 1, "severity": "blocking", "claim": "one"},
 {"id": "F-2", "file": "src/a.py", "line": 1, "severity": "minor", "claim": "two"}]
```
EOF
cat > "$TMP/v2.md" <<'EOF'
```json
[{"id": "F-1", "verdict": "confirmed", "evidence": "ran bash -c grep, src/a.py:1"},
 {"id": "F-2", "verdict": "rejected", "evidence": "src/a.py:1 shows otherwise"}]
```
EOF
run $PY "$FACTORY" check-verdicts --findings "$TMP/f2.md" --verdicts "$TMP/v2.md"
expect_rc "verdicts: complete and valid" 0 "$LAST_RC"
expect_json_field x "blockingConfirmed.0" "F-1" && ok "verdicts: blockingConfirmed=[F-1]" || bad "verdicts: blockingConfirmed"
# GUL-1929: the fix-round brief needs the finding's text, not just its id, and a
# minor finding has no business in the blocking list.
expect_json_field x "blockingFindings.0.id" "F-1" && ok "verdicts: blockingFindings carries the id" || bad "verdicts: blockingFindings id"
expect_json_field x "blockingFindings.0.file" "src/a.py" && ok "verdicts: blockingFindings carries file" || bad "verdicts: blockingFindings file"
expect_json_field x "blockingFindings.0.line" "1" && ok "verdicts: blockingFindings carries line" || bad "verdicts: blockingFindings line"
expect_json_field x "blockingFindings.0.claim" "one" && ok "verdicts: blockingFindings carries the claim" || bad "verdicts: blockingFindings claim"
expect_json_field x "blockingFindings.0.evidence" "ran bash -c grep, src/a.py:1" && ok "verdicts: blockingFindings carries the verifier's evidence" || bad "verdicts: blockingFindings evidence"
$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d["blockingFindings"])==1 else 1)' "$LAST_OUT" && ok "verdicts: only the confirmed blocking finding carries detail" || bad "verdicts: blockingFindings count"
cat > "$TMP/v-miss.md" <<'EOF'
```json
[{"id": "F-1", "verdict": "confirmed", "evidence": "x"}]
```
EOF
run $PY "$FACTORY" check-verdicts --findings "$TMP/f2.md" --verdicts "$TMP/v-miss.md"
expect_rc "verdicts: missing F-2 -> fail" 1 "$LAST_RC"
cat > "$TMP/v-extra.md" <<'EOF'
```json
[{"id": "F-1", "verdict": "confirmed", "evidence": "x"},
 {"id": "F-2", "verdict": "confirmed", "evidence": "y"},
 {"id": "F-3", "verdict": "unproven", "evidence": "z"}]
```
EOF
run $PY "$FACTORY" check-verdicts --findings "$TMP/f2.md" --verdicts "$TMP/v-extra.md"
expect_rc "verdicts: extra id -> fail" 1 "$LAST_RC"
cat > "$TMP/v-dup.md" <<'EOF'
```json
[{"id": "F-1", "verdict": "confirmed", "evidence": "x"},
 {"id": "F-1", "verdict": "rejected", "evidence": "y"},
 {"id": "F-2", "verdict": "unproven", "evidence": "z"}]
```
EOF
run $PY "$FACTORY" check-verdicts --findings "$TMP/f2.md" --verdicts "$TMP/v-dup.md"
expect_rc "verdicts: duplicate verdict -> fail" 1 "$LAST_RC"

# ---------- 6. check-gate (gh stub via FACTORY_GH) ----------
echo "== check-gate =="
GHSTUB="$TMP/gh-stub"
mkdir -p "$GHSTUB/data"
cat > "$GHSTUB/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub for factory-check. Serves canned JSON from $GH_STUB_DIR.
[ "${#}" -ge 2 ] || exit 1
if [ "$1" = "api" ]; then
  p="$2"; p="${p%%\?*}"; name="$(basename "$p")"
  f="$GH_STUB_DIR/contents-$name.json"
  [ -f "$f" ] && cat "$f" && exit 0
  echo '{"message":"Not Found"}'; exit 1
fi
case "$1 $2" in
  "pr view")   cat "$GH_STUB_DIR/pr-view.json" ;;
  "pr checks") cat "$GH_STUB_DIR/pr-checks.json" ;;
  "pr create") printf '%s\n' "$*" >> "$(dirname "$0")/pr-create.log"
               echo "https://github.example/gulasz101/homelab-2nd/pull/999" ;;
  "pr ready")  printf '%s\n' "$*" >> "$(dirname "$0")/pr-ready.log"
               echo "ready" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$GHSTUB/gh"
export FACTORY_GH="$GHSTUB/gh"
spec_file "$TMP/gate-spec.md" '["src/**"]' 100 '"true"'
b64() { $PY -c 'import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode())'; }
write_view() { # files-json additions deletions [draft]
  cat > "$GHSTUB/data/pr-view.json" <<EOF
{"headRefOid":"aaaa","baseRefOid":"bbbb","additions":$2,"deletions":$3,"files":$1,"isDraft":${4:-false}}
EOF
}
export GH_STUB_DIR="$GHSTUB/data"

# pass case: one clean yaml file, check SUCCESS, small diff
write_view '[{"path":"src/app.yaml","changeType":"MODIFIED","additions":3,"deletions":1}]' 3 1
# the gh stub's api branch serves contents-<basename-without-query>.json
printf '{"content":%s}' "\"$(printf 'kind: ConfigMap\nmetadata:\n  name: x\n' | b64)\"" > "$GHSTUB/data/contents-app.yaml.json"
cat > "$GHSTUB/data/pr-checks.json" <<'EOF'
[{"name":"check","state":"SUCCESS"}]
EOF
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: green check + clean paths" 0 "$LAST_RC"
# GUL-1801: only a draft gets marked ready; a normal PR is left alone.
[ -f "$GHSTUB/pr-ready.log" ] && bad "gate (GUL-1801): marked a non-draft PR ready" \
  || ok "gate (GUL-1801): a non-draft PR is not touched"

cat > "$GHSTUB/data/pr-checks.json" <<'EOF'
[{"name":"check","state":"FAILURE"}]
EOF
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: check FAILURE -> fail" 1 "$LAST_RC"
cat > "$GHSTUB/data/pr-checks.json" <<'EOF'
[{"name":"other","state":"SUCCESS"}]
EOF
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: no check named check -> fail" 1 "$LAST_RC"

cat > "$GHSTUB/data/pr-checks.json" <<'EOF'
[{"name":"check","state":"SUCCESS"}]
EOF
write_view '[{"path":"clusters/production/apps.yaml","changeType":"MODIFIED","additions":1,"deletions":1}]' 1 1
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: never path changed -> FAILS" 1 "$LAST_RC"
grep -q "never path" "$LAST_OUT" && ok "gate: never-path reason named" || bad "gate never reason"

write_view '[{"path":"docs/adr/adr-099-new-thing.md","changeType":"ADDED","additions":1,"deletions":0}]' 1 0
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: new ADR file -> fail" 1 "$LAST_RC"

printf '{"content":%s}' "\"$(printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: s\n' | b64)\"" > "$GHSTUB/data/contents-secret.yaml.json"
write_view '[{"path":"apps/foo/secret.yaml","changeType":"MODIFIED","additions":2,"deletions":0}]' 2 0
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: kind: Secret content rule -> fail" 1 "$LAST_RC"

printf '{"content":%s}' "\"$(printf 'a: 1\nsops:\n  age:\n    - X\n' | b64)\"" > "$GHSTUB/data/contents-enc.yaml.json"
write_view '[{"path":"apps/foo/enc.yaml","changeType":"MODIFIED","additions":1,"deletions":0}]' 1 0
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: sops-encrypted content rule -> fail" 1 "$LAST_RC"

# GUL-1730: 1x-3x maxDiffLines warns with one size note, it does not block. A green,
# reviewed, verified PR lost over 59 lines (GUL-1597: 559 against 500) and the PM
# raised the spec by hand; the merge decision sees the number instead.
write_view '[{"path":"src/app.yaml","changeType":"MODIFIED","additions":75,"deletions":75}]' 75 75
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: 1.5x maxDiffLines -> pass" 0 "$LAST_RC"
grep -q 'size note: 150 lines > maxDiffLines 100' "$LAST_OUT" && ok "gate: 1.5x carries the size note" || bad "gate 1.5x size note"

# 3x is the hard stop: nobody reviews that in one sitting.
write_view '[{"path":"src/app.yaml","changeType":"MODIFIED","additions":175,"deletions":175}]' 175 175
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: diff over 3x maxDiffLines -> fail" 1 "$LAST_RC"
grep -q '3 \* maxDiffLines' "$LAST_OUT" && ok "gate: the hard stop names 3x" || bad "gate 3x reason"

# GUL-1801: open-pr opens the PR as a draft while the round is unfinished, and the
# passing gate is what takes the draft off. Wojtek's flow does not change: the merge
# card is raised after the gate anyway.
rm -f "$GHSTUB/pr-ready.log"
write_view '[{"path":"src/app.yaml","changeType":"MODIFIED","additions":3,"deletions":1}]' 3 1 true
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate (GUL-1801): a passing gate on a draft PR -> pass" 0 "$LAST_RC"
grep -q "pr ready 7" "$GHSTUB/pr-ready.log" 2>/dev/null && ok "gate (GUL-1801): marks the draft PR ready" \
  || bad "gate (GUL-1801): pr ready was not called"

write_view '[{"path":"src/app.yaml","changeType":"MODIFIED","additions":3,"deletions":1}]' 3 1
rm -f "$GHSTUB/data/contents-app.yaml.json"
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: gh api error -> rc 2" 2 "$LAST_RC"

# ---------- 6b. check-gate: chart pin vs cluster (GUL-552, ADR-097) ----------
# A PR that touches a HelmRelease has to pass scripts/helmrelease-pin-vs-cluster.sh.
# The fixture is a real git repo (the script diffs refs), a kubectl stub on PATH
# and the same gh stub: the PR head ref is pre-created as refs/factory/pr-9, so
# the gate's fetch has nothing to do and the check runs offline.
echo "== check-gate: pin vs cluster =="
GATE_REPO="$TMP/gate-repo"
mkdir -p "$GATE_REPO/scripts" "$GATE_REPO/apps/llm-hub"
cp "$ROOT/scripts/helmrelease-pin-vs-cluster.sh" "$GATE_REPO/scripts/"
( cd "$GATE_REPO"
  git init -q -b main .
  git config user.email test@example.invalid
  git config user.name "gate test"
  printf 'apiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n  name: open-webui\n  namespace: llm-hub\nspec:\n  chart:\n    spec:\n      chart: open-webui\n      version: "17.3.0"\n' \
    > apps/llm-hub/openwebui-helm-release.yaml
  git add -A && git commit -qm base
  printf 'apiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n  name: open-webui\n  namespace: llm-hub\nspec:\n  chart:\n    spec:\n      chart: open-webui\n      version: "17.0.0"\n' \
    > apps/llm-hub/openwebui-helm-release.yaml
  git add -A && git commit -qm "pin open-webui to 17.0.0"
  git update-ref refs/factory/pr-9 HEAD )
GATE_HEAD="$(git -C "$GATE_REPO" rev-parse HEAD)"
GATE_BASE="$(git -C "$GATE_REPO" rev-parse HEAD^)"
printf '{"headRefOid":"%s","baseRefOid":"%s","additions":1,"deletions":1,"files":[{"path":"apps/llm-hub/openwebui-helm-release.yaml","changeType":"MODIFIED","additions":1,"deletions":1}]}' \
  "$GATE_HEAD" "$GATE_BASE" > "$GHSTUB/data/pr-view.json"
printf '{"content":%s}' "\"$(git -C "$GATE_REPO" show HEAD:apps/llm-hub/openwebui-helm-release.yaml | b64)\"" \
  > "$GHSTUB/data/contents-openwebui-helm-release.yaml.json"
cat > "$GHSTUB/data/pr-checks.json" <<'EOF'
[{"name":"check","state":"SUCCESS"}]
EOF
KUBEBIN="$TMP/kube-bin"
mkdir -p "$KUBEBIN" "$TMP/kube-data"
cat > "$KUBEBIN/kubectl" <<'KUBESTUB'
#!/usr/bin/env bash
# kubectl stub for factory-check: $KUBE_DATA/version holds the deployed version,
# $KUBE_DATA/down makes the cluster unreachable.
[ -f "$KUBE_DATA/down" ] && { echo 'connection refused' >&2; exit 1; }
case "$*" in
  *" -A "*|*" -A") printf 'llm-hub|open-webui\n'; exit 0 ;;
esac
v=$(cat "$KUBE_DATA/version" 2>/dev/null)
[ -n "$v" ] || { echo 'Error from server (NotFound): helmreleases not found' >&2; exit 1; }
printf '%s' "$v"
KUBESTUB
chmod +x "$KUBEBIN/kubectl"
export KUBE_DATA="$TMP/kube-data"

gate_pin_run() { # runs check-gate against the HelmRelease PR with the stub tools
  env PATH="$KUBEBIN:$PATH" KUBE_DATA="$TMP/kube-data" FACTORY_GATE_REPO="$GATE_REPO" \
      GH_STUB_DIR="$GHSTUB/data" FACTORY_GH="$GHSTUB/gh" \
      $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#9" --spec "$TMP/gate-spec.md"
}

printf '17.3.0' > "$TMP/kube-data/version"
run gate_pin_run
expect_rc "gate: pin 17.0.0 below deployed 17.3.0 -> FAILS" 1 "$LAST_RC"
grep -q 'pins 17.0.0' "$LAST_OUT" && ok "gate: downgrade reason names both versions" \
  || bad "gate: downgrade reason missing"

printf '17.0.0' > "$TMP/kube-data/version"
run gate_pin_run
expect_rc "gate: pin equal deployed -> PASS" 0 "$LAST_RC"

printf '' > "$TMP/kube-data/version"
: > "$TMP/kube-data/down"
run gate_pin_run
expect_rc "gate: kubectl unreachable -> rc 2 (never a pass)" 2 "$LAST_RC"
rm -f "$TMP/kube-data/down"

# back to a clean view for the sections after this one
write_view '[{"path":"src/app.yaml","changeType":"MODIFIED","additions":3,"deletions":1}]' 3 1

# ---------- 7. commit ----------
echo "== commit =="
C="$TMP/commit"
new_repo "$C"
mkdir -p "$C/tests"
printf '#!/bin/bash\nexit 1\n' > "$C/tests/ac.sh"
run $PY "$FACTORY" commit --repo "$C" --stage red --issue GUL-436
expect_rc "commit red: tests only" 0 "$LAST_RC"
[ -n "$(grep '"sha"' "$LAST_OUT")" ] && ok "commit prints sha" || bad "commit sha field"
MSG="$(git -C "$C" log -1 --format=%B)"
echo "$MSG" | grep -q "^factory(GUL-436): red$" && ok "commit subject format" || bad "commit subject: $MSG"
echo "$MSG" | grep -q "Co-Authored-By: Paperclip <noreply@paperclip.ing>" && ok "commit trailer" || bad "commit trailer"
printf 'print("sneaky impl")\n' > "$C/src/impl.py"
BEFORE="$(git -C "$C" rev-parse HEAD)"
run $PY "$FACTORY" commit --repo "$C" --stage red --issue GUL-436
expect_rc "commit red: non-test path -> refuse" 1 "$LAST_RC"
[ "$(git -C "$C" rev-parse HEAD)" = "$BEFORE" ] && ok "refused commit did not commit" || bad "refused commit created a commit"
git -C "$C" reset -q
rm "$C/src/impl.py"
printf 'print("feature")\n' > "$C/src/b.py"
run $PY "$FACTORY" commit --repo "$C" --stage green --issue GUL-436
expect_rc "commit green: no tests touched" 0 "$LAST_RC"
printf 'print("drift")\n' > "$C/src/c.py"
printf '#!/bin/bash\necho x\n' > "$C/tests/new.test.sh"
run $PY "$FACTORY" commit --repo "$C" --stage green --issue GUL-436
expect_rc "commit green: test path -> refuse" 1 "$LAST_RC"

# ---------- 8. open-pr ----------
echo "== open-pr =="
O="$TMP/openpr"
git init -q --bare "$TMP/origin.git"
new_repo "$O"
git -C "$O" remote add origin "$TMP/origin.git"
git -C "$O" checkout -qb gul-436-work
printf 'print("pr me")\n' > "$O/src/pr.py"
( cd "$O" && git add -A && git commit -qm "work" )
run env FACTORY_GH="$GHSTUB/gh" $PY "$FACTORY" open-pr --repo "$O" --issue GUL-436 --title "Factory test PR"
expect_rc "open-pr: pushes branch and prints url" 0 "$LAST_RC"
expect_json_field x "url" "https://github.example/gulasz101/homelab-2nd/pull/999" && ok "open-pr url field" || bad "open-pr url"
# GUL-1801: open-pr runs inside the green stage, so the round it belongs to is
# never finished here — review, verify and the gate are still ahead and a fix round
# can rewrite the head. The PR is opened as a draft (GitHub refuses to merge it) and
# check-gate marks it ready when it passes.
grep -q -- '--draft' "$GHSTUB/pr-create.log" 2>/dev/null && ok "open-pr (GUL-1801): opened as a draft" \
  || bad "open-pr (GUL-1801): not opened as a draft"
git -C "$TMP/origin.git" rev-parse --verify gul-436-work >/dev/null 2>&1 \
  && ok "branch actually pushed to origin" || bad "branch not pushed"
# a caller that knows the round is over can open a normal PR
git -C "$O" checkout -q gul-436-work
run env FACTORY_GH="$GHSTUB/gh" $PY "$FACTORY" open-pr --repo "$O" --issue GUL-436 --title "Factory test PR" --ready
expect_rc "open-pr --ready: still opens" 0 "$LAST_RC"
tail -1 "$GHSTUB/pr-create.log" | grep -q -- '--draft' \
  && bad "open-pr --ready (GUL-1801): still a draft" || ok "open-pr --ready (GUL-1801): no --draft"
git -C "$O" checkout -q main
run env FACTORY_GH="$GHSTUB/gh" $PY "$FACTORY" open-pr --repo "$O" --issue GUL-436 --title "nope"
expect_rc "open-pr: refuses on main" 1 "$LAST_RC"

# ---------- 9. test-path parity with policy.ts ----------
echo "== test-path parity (python vs policy.ts) =="
PATHS="$TMP/paths.json"
cat > "$PATHS" <<'EOF'
["src/tests/a.test.ts", "tests/x.py", "test/y.ts", "app/test", "a/tests",
 "docs/README.md", "src/main.py", "src/main.test.ts", "src/main_test.go",
 "tests", "TESTS/z.java", "a\\tests\\b", "test_helpers.py", "test_helper.rb",
 "x.test.ts", "x.TEST.TS", ".test.ts", "_test.py", "apps/zigbee/tests/render-check.sh",
 "docs/adr/tests/adr-check.sh", "scripts/check.sh", "", "a/b/tests/c/d.sh",
 "foo/test.ts", "src/test_/x.ts", "deep/test/dir/file.md"]
EOF
if command -v node >/dev/null 2>&1; then
  node "$ROOT/agents/factory/tests/path-parity.ts" "$PATHS" > "$TMP/parity-ts.json" 2> "$TMP/parity-ts.err" \
    && TS_RC=0 || TS_RC=$?
  if [ "$TS_RC" = "0" ]; then
    python3 "$ROOT/agents/factory/tests/path-parity.py" "$PATHS" "$TMP/parity-ts.json" > "$TMP/parity.out" 2>&1 \
      && ok "parity: python == policy.ts on $( $PY -c "import json;print(len(json.load(open('$PATHS'))))" ) paths" \
      || { bad "parity: python and policy.ts disagree"; cat "$TMP/parity.out" >&2; }
  else
    bad "parity: node could not run path-parity.ts"; cat "$TMP/parity-ts.err" >&2
  fi
else
  bad "parity: node not installed (required — CI has it)"
fi

# ---------- 10. network + Paperclip containment ----------
echo "== network and Paperclip containment =="
# GUL-439: the stage checks never call Paperclip. The three factory subcommands
# do, and only through pc.py. So: no network imports in factory.py, and pc.py is
# the single file allowed to build a URL.
if grep -nE '^[[:space:]]*(import|from)[[:space:]]+(urllib|http|socket|requests)' "$FACTORY" > "$TMP/net.out"; then
  bad "factory.py imports a network lib directly"; cat "$TMP/net.out" >&2
else
  ok "factory.py: no direct network import (pc.py owns the client)"
fi
if grep -nE 'socket|requests|https?://' "$PC" | grep -vE 'DEFAULT_BASE|^[0-9]+: *#|URL: PAPERCLIP_API_URL' > "$TMP/pcnet.out"; then
  bad "pc.py carries a URL or an extra network lib"; cat "$TMP/pcnet.out" >&2
else
  ok "pc.py: urllib only, one base URL constant"
fi
if grep -nE 'auth\.json' "$FACTORY" "$PC" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' > "$TMP/auth.out"; then
  bad "factory code reads the board token file"; cat "$TMP/auth.out" >&2
else
  ok "factory code: never reads ~/.paperclip/auth.json (GUL-297)"
fi

# ---------- 11. start/decide/tick against a stub Paperclip ----------
echo "== factory drives Paperclip (stub API, GUL-439) =="
if python3 "$ROOT/agents/factory/tests/test_factory_paperclip.py" > "$TMP/pc-tests.out" 2>&1; then
  ok "start/decide/tick: $(grep -c '^ok ' "$TMP/pc-tests.out") assertions against the stub API"
else
  bad "start/decide/tick: stub API suite failed"
  tail -40 "$TMP/pc-tests.out" >&2
fi

# ---------- summary ----------
echo
if [ "$FAIL_N" -eq 0 ]; then
  echo "factory-check: ALL PASS ($PASS_N assertions)"
  exit 0
else
  echo "factory-check: FAIL ($FAIL_N failed, $PASS_N passed)"
  exit 1
fi
