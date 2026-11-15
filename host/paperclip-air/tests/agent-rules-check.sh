#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1572: the agents' rule files are deployed from git by
# homelab-install-agent-rules.sh, backed up by restic (tag agent-rules) and
# watched hourly (watchdog check 10).
#
# What this proves, on a throwaway git repo + fake $HOME (Linux CI and bash 3.2):
#   1. a live file that is an OLD committed version is a safe update; dry run
#      changes nothing; --apply writes it, keeps a backup, writes the manifest;
#      a second dry run is all "in sync" and exits 0;
#   2. a hand edit is DRIFT: --apply refuses it (exit 1) and leaves it alone;
#      --adopt-live prints it as a diff; --overwrite-drift replaces it;
#   3. a live file equal to the last deploy is a safe update after the repo moves on;
#   4. --apply refuses while a guarded Pi session runs (the guard would undo it),
#      and the script refuses root;
#   5. agent_rules_files/_hashes/_changed see SOUL.md, external and managed
#      bundles (not .bak copies), and report added/changed/removed exactly;
#   6. watchdog check 10 and the restic agent-rules snapshot are wired in.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$HERE/bin"
RC=0
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
ok()   { printf 'ok:   %s\n' "$*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gul1572.XXXXXX")
cleanup() { [ -n "${PI_PID:-}" ] && kill "$PI_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

CO=cafe0000-0000-0000-0000-000000000000
TID=11111111-1111-1111-1111-111111111111
REPO="$WORK/repo"; H="$WORK/home"
mkdir -p "$REPO/agents/instructions"/{claude-code,opencode,pi} "$REPO/agents/factory/briefs"
cat >"$REPO/agents/factory/agents.json" <<EOF
{"stages": {"red": {"agentId": "$TID", "name": "Tester"}, "gate": {"agentId": "x", "name": "Majster"}}}
EOF
v() { for a in claude-code opencode pi; do printf '%s rules %s\n' "$a" "$1" >"$REPO/agents/instructions/$a/AGENTS.md"; done
      printf 'tester brief %s\n' "$1" >"$REPO/agents/factory/briefs/tester.md"; }
g() { git -C "$REPO" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
git -C "$REPO" init -q
v v1; g add -A; g commit -qm v1
v v2; g add -A; g commit -qm v2

LIVE_T="$H/.paperclip/instances/default/companies/$CO/agents/$TID/instructions/AGENTS.md"
LIVE_M="$H/.paperclip/instances/default/companies/$CO/agents/22222222-0000-0000-0000-000000000000/instructions/AGENTS.md"
mkdir -p "$(dirname "$LIVE_T")" "$(dirname "$LIVE_M")" "$H/.hermes/profiles/bill"
for a in claude-code opencode pi; do mkdir -p "$H/paperclip-agents/$a"; printf '%s rules v1\n' "$a" >"$H/paperclip-agents/$a/AGENTS.md"; done
printf 'tester brief v1\n' >"$LIVE_T"; printf 'majster, not in git\n' >"$LIVE_M"
printf 'root soul\n' >"$H/.hermes/SOUL.md"; printf 'bill soul\n' >"$H/.hermes/profiles/bill/SOUL.md"
printf 'old\n' >"$H/paperclip-agents/pi/AGENTS.md.bak-x"

run() { AGENT_RULES_REPO="$REPO" AGENT_RULES_HOME="$H" AGENT_RULES_COMPANY="$CO" bash "$BIN/homelab-install-agent-rules.sh" "$@" >"$WORK/out" 2>&1; }
LIVE_P="$H/paperclip-agents/pi/AGENTS.md"

# ---- 1. old committed version -> safe update -----------------------------------
run; r=$?
[ "$r" = 0 ] && grep -q 'would update .*pi/AGENTS.md.*repo version from' "$WORK/out" && ok "dry run: v1 live is 'would update' (repo version)" || fail "dry run: rc=$r $(cat "$WORK/out")"
grep -q 'v1' "$LIVE_P" && ok "dry run changed nothing" || fail "dry run wrote"
grep -q 'not in git .*22222222' "$WORK/out" && ok "unmanaged bundle listed as 'not in git'" || fail "Majster-like bundle not listed"
run --apply; r=$?
[ "$r" = 0 ] && grep -q 'v2' "$LIVE_P" && grep -q 'v2' "$LIVE_T" && ok "--apply wrote v2 to external and managed bundles" || fail "--apply: rc=$r $(cat "$WORK/out")"
ls "$LIVE_P".bak-agent-rules-* >/dev/null 2>&1 && ok "backup kept" || fail "no .bak-agent-rules-* backup"
[ "$(grep -c . "$H/paperclip-agents/.deployed.sha256")" = 4 ] && ok "manifest has the 4 targets" || fail "manifest: $(cat "$H/paperclip-agents/.deployed.sha256" 2>&1)"
run; r=$?
[ "$r" = 0 ] && [ "$(grep -c '^in sync' "$WORK/out")" = 4 ] && ok "second dry run: 4 in sync, exit 0" || fail "second dry run: rc=$r $(cat "$WORK/out")"

# ---- 2. hand edit -> DRIFT --------------------------------------------------------
printf 'pi rules v2 plus a hand edit\n' >"$LIVE_P"
run --apply; r=$?
[ "$r" = 1 ] && grep -q '^DRIFT .*pi/AGENTS.md' "$WORK/out" && grep -q 'hand edit' "$LIVE_P" && ok "--apply refuses a hand edit and leaves it (exit 1)" || fail "drift: rc=$r $(cat "$WORK/out")"
run --adopt-live
grep -q '^    +pi rules v2 plus a hand edit' "$WORK/out" && ok "--adopt-live prints the edit as a diff" || fail "adopt-live: $(cat "$WORK/out")"
run --apply --overwrite-drift; r=$?
[ "$r" = 0 ] && grep -qx 'pi rules v2' "$LIVE_P" && ok "--overwrite-drift replaces it" || fail "overwrite-drift: rc=$r"

# ---- 3. last deploy -> safe update after the repo moves on ------------------------
v v3; g add -A; g commit -qm v3
run --apply; r=$?
[ "$r" = 0 ] && grep -q 'live is the last deploy' "$WORK/out" && grep -q v3 "$LIVE_P" && ok "manifest match is a safe update" || fail "manifest path: rc=$r $(cat "$WORK/out")"

# ---- 4. guarded Pi session, root ----------------------------------------------------
v v4; g add -A; g commit -qm v4
bash -c 'exec -a "pi --extension /x/factory-guard/index.ts" sleep 30' & PI_PID=$!
sleep 1
run --apply; r=$?
[ "$r" = 2 ] && grep -q 'guarded Pi session is running' "$WORK/out" && grep -q v3 "$LIVE_P" && ok "--apply refuses under a live guarded Pi session" || fail "pi session: rc=$r $(cat "$WORK/out")"
kill "$PI_PID" 2>/dev/null; wait "$PI_PID" 2>/dev/null; PI_PID=""
STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\n[ "$1" = "-u" ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' >"$STUB/id"; chmod +x "$STUB/id"
PATH="$STUB:$PATH" AGENT_RULES_REPO="$REPO" AGENT_RULES_HOME="$H" bash "$BIN/homelab-install-agent-rules.sh" --apply >"$WORK/out" 2>&1; r=$?
[ "$r" = 2 ] && grep -q 'not root' "$WORK/out" && ok "refuses root" || fail "root: rc=$r"

# ---- 5. lib: file list and change detection ------------------------------------------
# shellcheck source=../bin/homelab-lib.sh
. "$BIN/homelab-lib.sh"
n=$(agent_rules_files "$H" | wc -l | tr -d ' ')
[ "$n" = 7 ] && ok "agent_rules_files: 2 SOUL + 3 external + 2 managed = 7" || fail "agent_rules_files found $n: $(agent_rules_files "$H")"
agent_rules_files "$H" | grep -q '\.bak' && fail ".bak copies listed" || ok ".bak copies ignored"
agent_rules_hashes "$H" >"$WORK/a"
printf 'bill soul, rewritten by an agent\n' >"$H/.hermes/profiles/bill/SOUL.md"
rm "$LIVE_M"; mkdir -p "$H/.hermes/profiles/new"; printf 'x\n' >"$H/.hermes/profiles/new/SOUL.md"
agent_rules_hashes "$H" >"$WORK/b"
got=$(agent_rules_changed "$WORK/a" "$WORK/b" | sed "s#$H#~#" | tr '\n' '|')
want="added ~/.hermes/profiles/new/SOUL.md|changed ~/.hermes/profiles/bill/SOUL.md|removed ~/.paperclip/instances/default/companies/$CO/agents/22222222-0000-0000-0000-000000000000/instructions/AGENTS.md|"
[ "$got" = "$want" ] && ok "agent_rules_changed: added/changed/removed exactly" || fail "changed gave '$got'"
[ -z "$(agent_rules_changed "$WORK/b" "$WORK/b")" ] && ok "no change -> empty" || fail "identical lists reported a change"

# ---- 6. wiring ---------------------------------------------------------------------
grep -q 'maybe_alert "agent-rules-changed-${rules_key}"' "$BIN/hermes-memory-watchdog.sh" && ok "watchdog check 10 alerts per distinct change" || fail "check 10 not wired"
grep -q 'restic backup --tag agent-rules' "$BIN/vault-backup.sh" && grep -q 'agent_rules_files "$HOME"' "$BIN/vault-backup.sh" && ok "vault-backup snapshots agent-rules from the shared list" || fail "agent-rules snapshot not wired"

exit $RC
