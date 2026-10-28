#!/usr/bin/env bash
# factory.py self-test (GUL-436). Throwaway git repos in mktemp dirs — never
# the real checkout. bash 3.2-safe (runs on the Air and in CI).
# Exit 0 only if every case passes.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
FACTORY="$ROOT/agents/factory/factory.py"
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
  "pr create") echo "https://github.example/gulasz101/homelab-2nd/pull/999" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$GHSTUB/gh"
export FACTORY_GH="$GHSTUB/gh"
spec_file "$TMP/gate-spec.md" '["src/**"]' 100 '"true"'
b64() { $PY -c 'import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode())'; }
write_view() { # files-json additions deletions
  cat > "$GHSTUB/data/pr-view.json" <<EOF
{"headRefOid":"aaaa","baseRefOid":"bbbb","additions":$2,"deletions":$3,"files":$1}
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

write_view '[{"path":"src/app.yaml","changeType":"MODIFIED","additions":60,"deletions":60}]' 60 60
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: diff over maxDiffLines -> fail" 1 "$LAST_RC"

write_view '[{"path":"src/app.yaml","changeType":"MODIFIED","additions":3,"deletions":1}]' 3 1
rm -f "$GHSTUB/data/contents-app.yaml.json"
run env FACTORY_GH="$GHSTUB/gh" GH_STUB_DIR="$GHSTUB/data" $PY "$FACTORY" check-gate --pr "gulasz101/homelab-2nd#7" --spec "$TMP/gate-spec.md"
expect_rc "gate: gh api error -> rc 2" 2 "$LAST_RC"

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
git -C "$TMP/origin.git" rev-parse --verify gul-436-work >/dev/null 2>&1 \
  && ok "branch actually pushed to origin" || bad "branch not pushed"
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

# ---------- 10. no-network rule ----------
echo "== no-network rule =="
if grep -nE 'urllib|requests|socket' "$FACTORY" > "$TMP/net.out"; then
  bad "factory.py references a network lib"; cat "$TMP/net.out" >&2
else
  ok "factory.py: no urllib/requests/socket"
fi
if grep -nE 'paperclip' "$FACTORY" | grep -vE 'noreply@paperclip\.ing|paperclip\.voitech\.dev|factory@paperclip\.ing' > "$TMP/pclip.out"; then
  bad "factory.py touches Paperclip"; cat "$TMP/pclip.out" >&2
else
  ok "factory.py: no Paperclip calls (only the PR trailer/link constants)"
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
