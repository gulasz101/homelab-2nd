#!/usr/bin/env bash
# AC-8 — the script is read-only and safe:
#   * no POST/PATCH/PUT/DELETE in sweep.py,
#   * ps is called only as `ps -axo pid=,ppid=,etime=,comm=`,
#   * no import outside the standard library,
#   * a missing PAPERCLIP_API_KEY in live mode exits 2 without printing an
#     environment value.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# MAJSTER_SWEEP lets the checks be rehearsed against a stub; unset it and
# they judge the real script.
SWEEP="${MAJSTER_SWEEP:-$HERE/../sweep.py}"

fail() { printf 'AC-8: FAIL %s\n' "$1"; exit 1; }

[ -f "$SWEEP" ] || fail "agents/majster-sweep/sweep.py does not exist yet, so there is nothing to judge"

TMP="$(mktemp -d)" || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

REASONS=""
add_fail() { REASONS="${REASONS:+$REASONS; }$1"; }

# 1. no HTTP write methods, no third-party imports, the one allowed ps form.
if ! REASON=$(python3 -I - "$SWEEP" <<'PY'
import ast, re, sys
path = sys.argv[1]
try:
    src = open(path).read()
except OSError as exc:
    print("cannot read sweep.py: %s" % exc); sys.exit(1)
try:
    tree = ast.parse(src)
except SyntaxError as exc:
    print("sweep.py does not parse: %s" % exc); sys.exit(1)

# docstrings may talk about POST; code may not do it
doc_lines = set()
for node in ast.walk(tree):
    body = getattr(node, "body", None)
    if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and body:
        first = body[0]
        if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant) and isinstance(first.value.value, str):
            last = getattr(first, "end_lineno", first.lineno) or first.lineno
            doc_lines.update(range(first.lineno, last + 1))
method = re.compile(r"\b(POST|PATCH|PUT|DELETE)\b")
for number, line in enumerate(src.splitlines(), 1):
    if number in doc_lines or line.lstrip().startswith("#"):
        continue
    found = method.search(line)
    if found:
        print("sweep.py:%d uses the HTTP method %s: %s" % (number, found.group(1), line.strip()[:100]))
        sys.exit(1)

stdlib = getattr(sys, "stdlib_module_names", None)
modules = []
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        modules += [alias.name.split(".")[0] for alias in node.names]
    elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
        modules.append(node.module.split(".")[0])
if stdlib is not None:
    outside = sorted(set(m for m in modules if m not in stdlib))
    if outside:
        print("imports outside the standard library: %r" % (outside,)); sys.exit(1)

# either one shell-shaped string or the argv form subprocess takes; the
# behavioural stub below proves what is actually passed.
if not ("-axo" in src and "pid=,ppid=,etime=,comm=" in src):
    print("sweep.py never passes '-axo pid=,ppid=,etime=,comm=', the only ps form allowed (GUL-206)")
    sys.exit(1)
for forbidden in ("-ef", "-aux", "auxww", "--sort", "-eo ", "-ww"):
    if forbidden in src:
        print("sweep.py carries the forbidden ps/environ token %r: other ps flags print server secrets" % forbidden)
        sys.exit(1)
sys.exit(0)
PY
); then add_fail "$REASON"; fi

# 2. behavioural: whatever ps it runs, it runs with exactly those arguments.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ps" <<'PY'
#!/usr/bin/env bash
# stub: record the argv, print nothing
printf '%s\n' "$*" >> "$PS_LOG"
PY
chmod +x "$TMP/bin/ps"
python3 "$HERE/fixtures.py" quiet "$TMP/fx" || fail "fixture generator failed for case 'quiet'"
: > "$TMP/ps.log"
PATH="$TMP/bin:$PATH" PS_LOG="$TMP/ps.log" python3 -I "$SWEEP" --fixtures "$TMP/fx" \
  --now "2026-11-09T18:00:00Z" --stop-file "$TMP/no-such-stop" \
  --tick-cmd "bash $HERE/tick-quiet.sh" >"$TMP/out.json" 2>"$TMP/err.txt"
RC=$?
if [ "$RC" -ne 0 ]; then
  add_fail "fixture run without --ps-file exited $RC, wanted 0 (stderr: $(tr '\n' ' ' <"$TMP/err.txt" | cut -c1-200))"
else
  while IFS= read -r ARGS; do
    [ -n "$ARGS" ] || continue
    if [ "$ARGS" != "-axo pid=,ppid=,etime=,comm=" ]; then
      add_fail "ps was called as 'ps $ARGS', the only allowed form is 'ps -axo pid=,ppid=,etime=,comm='"
    fi
  done < "$TMP/ps.log"
fi

# 3. live mode with no key: exit 2, and nothing from the environment on the
#    wire. The URL carries a canary so a printed value is impossible to miss.
env -u PAPERCLIP_API_KEY -u PAPERCLIP_RUN_ID -u PAPERCLIP_API_FALLBACK_URL \
  PAPERCLIP_API_URL="http://127.0.0.1:9/canary-api-url" \
  PAPERCLIP_COMPANY_ID="canary-company-id" \
  python3 -I "$SWEEP" >"$TMP/live.out" 2>"$TMP/live.err"
LIVE_RC=$?
[ "$LIVE_RC" -eq 2 ] || add_fail "live mode without PAPERCLIP_API_KEY exited $LIVE_RC, wanted 2"
if grep -q "canary" "$TMP/live.out" "$TMP/live.err" 2>&1; then
  add_fail "live mode printed an environment value (canary found in its output)"
fi
if grep -q "127.0.0.1" "$TMP/live.out" "$TMP/live.err" 2>&1; then
  add_fail "live mode printed the API URL from the environment"
fi

if [ -n "$REASONS" ]; then fail "$REASONS"; fi

printf 'AC-8: PASS\n'
exit 0
