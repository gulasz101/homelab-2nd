#!/usr/bin/env bash
# claude-hook self-test (GUL-2037 phase 4). The Claude Code PreToolUse hook must block what
# policy.ts blocks for a role, and allow plain reads. Zero tokens: it feeds hook JSON on stdin.
# Exit 0 only if every case gives the expected exit code (0 = allowed, 2 = blocked).
set -u
cd "$(cd "$(dirname "$0")/.."; pwd)"
if ! command -v node >/dev/null 2>&1; then echo "SKIP claude-hook: node not installed"; exit 0; fi
case "$(node -p 'process.versions.node.split(".")[0]')" in
  1[0-9]|2[0-2]) echo "SKIP claude-hook: node < 23 cannot run .ts"; exit 0 ;;
esac
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
# Same rule as the factory self-tests (GUL-2091): unset TMPDIR (GitHub's runner) -> /tmp;
# a TMPDIR that is set but dead stops the test before any git command.
WS="$(mktemp -d "${TMPDIR:-/tmp}/claude-hook-check-XXXXXX")" \
  || { echo "ENV: mktemp -d failed (TMPDIR=${TMPDIR:-unset})" >&2; exit 2; }
[ -d "$WS" ] || { echo "ENV: mktemp -d gave no directory (TMPDIR=${TMPDIR:-unset})" >&2; exit 2; }
trap 'rm -rf "$WS"' EXIT
git -C "$WS" init -q
printf 'x\n' > "$WS/README.md"

HOOK="$PWD/claude-hook.ts"
fail=0
run() {  # want role tool input-json
  local want=$1 role=$2 tool=$3 input=$4 got
  printf '{"tool_name":"%s","tool_input":%s,"cwd":"%s"}' "$tool" "$input" "$WS" \
    | node "$HOOK" "$role" >/dev/null 2>"$WS.err"
  got=$?
  if [ "$got" = "$want" ]; then echo "ok   $role $tool $input -> $got"
  else echo "FAIL $role $tool $input -> $got, want $want: $(cat "$WS.err")"; fail=1; fi
}

run 0 readonly Read      "{\"file_path\":\"$WS/README.md\"}"
run 0 readonly Bash      '{"command":"git diff HEAD"}'
run 0 readonly Grep      "{\"pattern\":\"x\",\"path\":\"$WS\"}"
run 2 readonly Edit      "{\"file_path\":\"$WS/README.md\",\"old_string\":\"x\",\"new_string\":\"y\"}"
run 2 readonly Write     "{\"file_path\":\"$WS/new.txt\",\"content\":\"y\"}"
run 2 readonly NotebookEdit "{\"notebook_path\":\"$WS/n.ipynb\"}"
run 2 readonly Bash      '{"command":"echo y > README.md"}'
run 2 readonly Bash      '{"command":"git commit -am x"}'
run 2 readonly Bash      '{"command":"gh pr merge 1"}'
run 2 readonly Bash      '{"command":"cat ~/.paperclip/auth.json"}'
run 2 readonly Read      '{"file_path":"~/.ssh/id_ed25519"}'
run 2 readonly Grep      '{"pattern":"x","path":"/"}'
# fail-closed: no role, unknown role, bad input
run 2 ""       Bash      '{"command":"ls"}'
run 2 nosuch   Write     "{\"file_path\":\"$WS/new.txt\"}"
printf 'not json' | node "$HOOK" readonly >/dev/null 2>&1
if [ $? = 2 ]; then echo "ok   bad json -> 2"; else echo "FAIL bad json not blocked"; fail=1; fi
rm -f "$WS.err"
if [ "$fail" = 0 ]; then echo "claude-hook: PASS"; else echo "claude-hook: FAIL"; fi
exit $fail
