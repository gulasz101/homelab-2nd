#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1577: the vault restic backup failed three nights in a row (2026-11-13..15)
# and nothing alerted. Root cause: a `sudo` verify run on 2026-11-12 left
# root-owned files in paperclip's restic cache (sudo keeps HOME on macOS).
#
# What this proves (portable: Linux CI and the Air's bash 3.2):
#   1. vault_backup_state reads ~/.config/vault-backup/last-run, which is written
#      only on success: 1 h old -> ok, 30 h old -> stale, no file -> missing,
#      garbage -> unreadable. The 26 h line is exclusive (26 h = stale);
#   2. watchdog check 5c alerts on anything but "ok", under its own condition;
#   3. vault-backup.sh refuses to run as root (exit 2), before it touches the
#      credentials, the log or the cache.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN="$HERE/bin"
RC=0
fail() { printf 'FAIL: %s\n' "$*"; RC=1; }
ok()   { printf 'ok:   %s\n' "$*"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gul1577.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../bin/homelab-lib.sh
. "$BIN/homelab-lib.sh"

iso() { python3 -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
NOW=$(date +%s)
S="$WORK/last-run"

# ---- 1. freshness ------------------------------------------------------------
printf '%s ok 91c70231@x,5c60ab2d@y\n' "$(iso $((NOW - 3600)))" >"$S"
got=$(vault_backup_state "$S" "$NOW"); [ "$got" = "ok 1" ] && ok "1 h old -> ok" || fail "1 h old gave '$got'"

printf '%s ok 91c70231@x\n' "$(iso $((NOW - 30*3600)))" >"$S"
got=$(vault_backup_state "$S" "$NOW"); case "$got" in "stale 30 "*) ok "30 h old -> stale" ;; *) fail "30 h old gave '$got'" ;; esac

printf '%s ok 91c70231@x\n' "$(iso $((NOW - 26*3600)))" >"$S"
got=$(vault_backup_state "$S" "$NOW"); case "$got" in "stale 26 "*) ok "26 h old -> stale (line is exclusive)" ;; *) fail "26 h old gave '$got'" ;; esac

got=$(vault_backup_state "$WORK/nope" "$NOW"); [ "$got" = "missing" ] && ok "no status file -> missing" || fail "missing file gave '$got'"

printf 'not-a-date failed\n' >"$S"
got=$(vault_backup_state "$S" "$NOW"); case "$got" in unreadable*) ok "garbage -> unreadable" ;; *) fail "garbage gave '$got'" ;; esac

# ---- 2. the watchdog wires it to an alert -------------------------------------
W="$BIN/hermes-memory-watchdog.sh"
grep -q 'vault_backup_state "${VAULT_STATUS}"' "$W" && ok "watchdog check 5c calls vault_backup_state" || fail "check 5c does not call vault_backup_state"
grep -q 'maybe_alert "vault-backup-stale"' "$W" && ok "check 5c alerts as vault-backup-stale" || fail "no vault-backup-stale alert"
grep -q 'ok\\ \*) ;;' "$W" && ok "only an ok state is quiet" || fail "check 5c case does not single out ok"

# ---- 3. never as root -----------------------------------------------------------
STUB="$WORK/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\n[ "$1" = "-u" ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' >"$STUB/id"; chmod +x "$STUB/id"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"
out=$(PATH="$STUB:$PATH" HOME="$FAKEHOME" VAULT_BACKUP_ENV="$WORK/no-such-env" bash "$BIN/vault-backup.sh" 2>&1); rc=$?
[ "$rc" = "2" ] && ok "as root: exit 2" || fail "as root: exit $rc ($out)"
case "$out" in *"do not run vault-backup.sh as root"*) ok "as root: says why" ;; *) fail "as root: message was '$out'" ;; esac
[ ! -e "$FAKEHOME/Library" ] && ok "as root: no log or cache dir created" || fail "as root: it touched $FAKEHOME/Library"

exit $RC
