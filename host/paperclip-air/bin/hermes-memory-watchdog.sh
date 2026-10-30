#!/bin/bash
# hermes-memory-watchdog.sh — hourly health check of Hermes memory config + state.db backups.
# H2-308. Alerts via `hermes send` to the andrzej Mattermost home channel, at most once per
# condition per 24 h. Never prints secret values.
set -euo pipefail

# Scripts historically lived in <hermes-home>/scripts; since GUL-618 this one is
# installed at /usr/local/libexec/homelab and run from a system LaunchDaemon, so an
# explicit HERMES_HOME (set by the daemon's EnvironmentVariables) wins. Without it,
# fall back to <script>/.. which is the old ~/.hermes/scripts layout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${HERMES_HOME:-}" ] && [ -d "${HERMES_HOME}" ]; then
    HERMES_HOME="$(cd "${HERMES_HOME}" && pwd)"
else
    HERMES_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
export HERMES_HOME

# Test hook: check a throwaway tree instead of the real ~/.hermes.
BASE_DIR="${HERMES_HOME_OVERRIDE:-$HERMES_HOME}"

STATE_DIR="${BASE_DIR}/state"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/hermes-memory-watchdog.log"
ENV_FILE="${ENV_FILE:-$HERMES_HOME/.env}"
ALERT_STATE="${STATE_DIR}/watchdog-alerts.state"
PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
HERMES_BIN="${HERMES_BIN:-$HERMES_HOME/hermes-agent/.hermes/bin/hermes}"
HINDSIGHT_API_URL="${HINDSIGHT_API_URL:-http://192.168.1.179:30239}"
HINDSIGHT_BANK="${HINDSIGHT_BANK:-hermes-andrzej}"
BACKUP_LOG="${BASE_DIR}/logs/hermes-state-backup.log"

# GUL-89: the label of the backup job, and how to interrogate launchd.
# Both are overridable so the self-test can inject a fake launchctl.
# GUL-618: the job is a system LaunchDaemon now, so the domain to ask is
# system/ first. gui/<uid> is still probed second, because a Mac where the
# conversion was rolled back would otherwise report "not scheduled at all"
# while the agent happily fires at 03:30.
BACKUP_LABEL="${BACKUP_LABEL:-com.gulasz101.hermes-state-backup}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
# 26 h = the 24 h schedule plus 2 h of slack for a Mac that was asleep at
# 03:30 and woke up later. The watchdog cannot wake a sleeping laptop
# (ADR-071), so it may only report what it can see.
BACKUP_STALE_SECONDS="${BACKUP_STALE_SECONDS:-93600}"
# How long a started-but-unfinished backup run may still be in flight before
# it counts as failed. The mc readiness probe alone can burn 20 x 30 s.
BACKUP_RUN_INFLIGHT_GRACE_SECONDS="${BACKUP_RUN_INFLIGHT_GRACE_SECONDS:-3600}"

# GUL-641. On 2026-10-30 the Claude Code PM agent's OAuth refresh was rejected
# at 05:30; the agent sat in `error`, its ticket stayed parked, and nobody was
# told for nine hours. This daemon is the hourly thing that runs on this Mac,
# so the Claude auth check lives here. The detector itself is in homelab-lib.sh
# because the legacy watchdog (and a human) must be able to call the same one.
HERE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -r "${HERE_BIN}/homelab-lib.sh" ]; then
    # shellcheck source=homelab-lib.sh
    . "${HERE_BIN}/homelab-lib.sh"
    CLAUDE_AUTH_CHECK=1
else
    CLAUDE_AUTH_CHECK=0
fi

# PyYAML is NOT in the Apple-signed system python, and the system python is
# the only one macOS lets a LaunchAgent take to the LAN (Local Network
# privacy - ADR-079). So config parsing gets its own interpreter: it never
# touches the network, only the profile files. If no yaml-capable python is
# found the checks below say so once instead of pretending every profile is
# broken.
YAML_PYTHON="${YAML_PYTHON:-}"
if [[ -z "${YAML_PYTHON}" ]]; then
    for cand in "${HERMES_HOME}/hermes-agent/.venv/bin/python3" /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [[ -x "${cand}" ]] && "${cand}" -c 'import yaml' >/dev/null 2>&1; then
            YAML_PYTHON="${cand}"
            break
        fi
    done
fi
# Fall back to the system python on purpose: its missing PyYAML is then
# reported as one honest condition instead of five false "unreadable" ones.
YAML_PY="${YAML_PYTHON:-${PYTHON_BIN}}"

mkdir -p "${LOG_DIR}" "${STATE_DIR}"
touch "${ALERT_STATE}"

log() {
    echo "$(date -Iseconds) $*" >> "${LOG_FILE}"
}

alert_count=0

# Send at most one alert per condition per 24 h.
maybe_alert() {
    local condition="$1"
    local message="$2"
    local now_ts last_ts
    now_ts="$(date +%s)"
    last_ts="$(grep "^${condition}:" "${ALERT_STATE}" 2>/dev/null | tail -1 | cut -d: -f2 || true)"
    last_ts="${last_ts:-0}"
    if [[ "${last_ts}" -ge $((now_ts - 86400)) ]]; then
        log "SUPPRESSED condition=${condition} last_alert_epoch=${last_ts}"
        return 0
    fi
    log "ALERT condition=${condition}: ${message}"
    echo "${condition}:${now_ts}" >> "${ALERT_STATE}"
    alert_count=$((alert_count + 1))
    if [[ -x "${HERMES_BIN}" ]]; then
        "${HERMES_BIN}" -p andrzej send -t mattermost -s "[hermes memory watchdog]" "${message}" >> "${LOG_FILE}" 2>&1 \
            || log "WARN hermes send failed for condition=${condition}"
    else
        log "WARN hermes binary not executable at ${HERMES_BIN}"
    fi
}

# Human-runnable diagnostic for GUL-641, and the switch a drill uses to prove
# the check without waiting for the hour to come round. Prints the verdict and,
# when it is dead, the exact alert sentence. Never sends anything.
if [ "${1:-}" = "--claude-auth-only" ]; then
    if [ "${CLAUDE_AUTH_CHECK}" -ne 1 ]; then
        echo "claude-auth: unknown:homelab-lib-not-found"
        exit 0
    fi
    verdict="$(claude_auth_state)"
    echo "claude-auth: ${verdict}"
    case "${verdict}" in
        dead:*) echo "$(claude_auth_alert_message "${verdict}")" ;;
    esac
    exit 0
fi

# ---- 1 + 2. provider must be hindsight; hindsight must not be disabled -------
CONFIG_PATHS=()
for profile in default andrzej florian szarik zdzislaw; do
    if [[ "${profile}" == "default" ]]; then
        CONFIG_PATHS+=("${BASE_DIR}/config.yaml")
    else
        CONFIG_PATHS+=("${BASE_DIR}/profiles/${profile}/config.yaml")
    fi
done

while IFS=$'\t' read -r profile status; do
    case "${status}" in
        ok) : ;;
        no-yaml) maybe_alert "watchdog-yaml-unavailable" "Hermes memory watchdog: no PyYAML-capable python found (tried: ${YAML_PY}) - the memory-provider and gemma checks cannot run" ;;
        missing) maybe_alert "missing-config-${profile}" "Hermes memory watchdog: config file missing for profile ${profile}" ;;
        disabled) maybe_alert "hindsight-disabled-${profile}" "Hermes memory watchdog: profile ${profile} lists hindsight under plugins.disabled" ;;
        *) maybe_alert "bad-memory-provider-${profile}" "Hermes memory watchdog: profile ${profile} memory.provider is '${status}', expected 'hindsight'" ;;
    esac
done < <("${YAML_PY}" - "${CONFIG_PATHS[@]}" <<'PY'
import sys
try:
    import yaml
except Exception:
    # No PyYAML: this is ONE broken tool, not five broken profiles. Say so
    # once (condition watchdog-yaml-unavailable) instead of blaming every
    # profile config for it.
    print("__NO_YAML__\tno-yaml")
    raise SystemExit(0)
names = ["default", "andrzej", "florian", "szarik", "zdzislaw"]
for name, path in zip(names, sys.argv[1:]):
    try:
        with open(path) as f:
            cfg = yaml.safe_load(f) or {}
    except FileNotFoundError:
        print(f"{name}\tmissing")
        continue
    except Exception:
        print(f"{name}\tunreadable")
        continue
    plugins = cfg.get("plugins") or {}
    disabled = plugins.get("disabled") or []
    if isinstance(disabled, str):
        disabled = [disabled]
    if "hindsight" in [str(x) for x in disabled]:
        print(f"{name}\tdisabled")
        continue
    mem = cfg.get("memory") or {}
    provider = mem.get("provider")
    if provider == "hindsight":
        print(f"{name}\tok")
    else:
        print(f"{name}\t{provider if provider not in (None, '') else 'EMPTY'}")
PY
)

# ---- 3. zdzislaw hindsight bank_id must be hermes-careerpa -------------------
ZDZ_BANK="${BASE_DIR}/profiles/zdzislaw/hindsight/config.json"
if [[ -f "${ZDZ_BANK}" ]]; then
    if ! "${PYTHON_BIN}" -c '
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
sys.exit(0 if cfg.get("bank_id") == "hermes-careerpa" else 1)
' "${ZDZ_BANK}" 2>/dev/null; then
        maybe_alert "zdzislaw-bank-id" "Hermes memory watchdog: zdzislaw hindsight bank_id is not hermes-careerpa"
    fi
fi

# ---- 4. newest Hindsight document in the bank must be < 24 h old -------------
API_KEY="$(grep -m1 '^HINDSIGHT_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
if [[ -n "${API_KEY}" ]]; then
    newest_ts="$(HINDSIGHT_URL="${HINDSIGHT_API_URL}" HINDSIGHT_BANK_ID="${HINDSIGHT_BANK}" HINDSIGHT_KEY="${API_KEY}" "${PYTHON_BIN}" - <<'PY' 2>/dev/null || true
import datetime, json, os, sys, urllib.request
url = os.environ["HINDSIGHT_URL"].rstrip("/") + "/v1/default/banks/" + os.environ["HINDSIGHT_BANK_ID"] + "/documents?limit=1&time_field=created_at"
req = urllib.request.Request(url, headers={"Authorization": "Bearer " + os.environ["HINDSIGHT_KEY"]})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.load(r)
except Exception:
    print(0)
    sys.exit(0)
items = data.get("items") or []
if not items:
    print(0)
    sys.exit(0)
try:
    dt = datetime.datetime.fromisoformat((items[0].get("created_at") or "").replace("Z", "+00:00"))
    print(int(dt.timestamp()))
except Exception:
    print(0)
PY
)"
    newest_ts="${newest_ts:-0}"
    now_ts="$(date +%s)"
    if [[ "${newest_ts}" -eq 0 ]]; then
        maybe_alert "hindsight-stale" "Hermes memory watchdog: could not read the newest Hindsight document in ${HINDSIGHT_BANK}"
    elif [[ $((now_ts - newest_ts)) -gt 86400 ]]; then
        maybe_alert "hindsight-stale" "Hermes memory watchdog: newest Hindsight document in ${HINDSIGHT_BANK} is older than 24h"
    fi
else
    maybe_alert "hindsight-key-missing" "Hermes memory watchdog: HINDSIGHT_API_KEY not found in ${ENV_FILE}"
fi

# ---- 5. the backup log must show success for all 5 profiles ------------------
missing_backup=0
if [[ ! -f "${BACKUP_LOG}" ]]; then
    missing_backup=1
else
    last_success="$(grep 'SUCCESS profiles=' "${BACKUP_LOG}" 2>/dev/null | tail -1 || true)"
    if [[ -z "${last_success}" ]]; then
        missing_backup=1
    else
        for p in default andrzej florian szarik zdzislaw; do
            grep -q "${p}" <<<"${last_success}" || missing_backup=1
        done
    fi
fi
if [[ "${missing_backup}" -eq 1 ]]; then
    last_line="$(grep 'SUCCESS profiles=' "${BACKUP_LOG}" 2>/dev/null | tail -1 || echo none)"
    maybe_alert "backup-missing" "Hermes memory watchdog: the state.db backup log does not show all 5 profiles succeeding (last SUCCESS line: ${last_line})"
fi

# ---- 5b. the backup JOB, not just the backup LOG ---------------------------
# GUL-89: check 5 above reads the log's *contents* - it asks "does the log show
# all five profiles succeeding". It never asked whether the JOB ran, or how it
# exited. A run that dies before its first UPLOADED line leaves the previous
# night's SUCCESS line sitting in the log, so check 5 stayed green while two
# nights of backup failed (GUL-87). launchctl was the only place the truth was
# visible. Two independent questions here, because either alone has a blind
# spot:
#
#   * launchctl: what was the exit code of the last launchd-spawned run?
#     Ground truth for the SCHEDULE, and sticky - only a later successful
#     scheduled run clears it, so a manual rescue does not hide a broken
#     schedule. This is also the only signal that survives a log that was
#     truncated, rotated or never written.
#   * the log's own timeline: did the last run start and never finish?
#     Catches a manual run that died too, and a run that died so early it
#     wrote no error line at all.
#
# The "did not run at all" case is separate: a 26 h grace, because a Mac that
# is asleep at 03:30 runs nothing until it wakes. The watchdog cannot wake a
# sleeping laptop (ADR-071) - it can only report what it can see.
launchd_print=""
launchd_domain=""
for candidate in "system" "gui/$(id -u)"; do
    if out="$("${LAUNCHCTL_BIN}" print "${candidate}/${BACKUP_LABEL}" 2>/dev/null)" && [[ -n "${out}" ]]; then
        launchd_print="${out}"
        launchd_domain="${candidate}"
        break
    fi
done
log "check5b backup_job_domain=${launchd_domain:-none}"
if [[ -z "${launchd_print}" ]]; then
    maybe_alert "backup-job-not-loaded" "Hermes memory watchdog: launchd has no job '${BACKUP_LABEL}' in system/ or gui/$(id -u) - the nightly state.db backup is not scheduled at all"
else
    backup_exit_code="$(printf '%s\n' "${launchd_print}" | awk -F'= ' '/^[[:space:]]*last exit code = /{gsub(/[^0-9-]/,"",$2); print $2; exit}')"
    backup_runs="$(printf '%s\n' "${launchd_print}" | awk -F'= ' '/^[[:space:]]*runs = /{gsub(/[^0-9]/,"",$2); print $2; exit}')"
    [[ -n "${backup_exit_code}" ]] || backup_exit_code="unknown"
    [[ -n "${backup_runs}" ]] || backup_runs="unknown"

    # Timeline of the backup log: when did a run last start, and when did one
    # last succeed. Local file read only - no yaml needed, no network.
    backup_timeline="$("${PYTHON_BIN}" - "${BACKUP_LOG}" <<'PY' 2>/dev/null || true
import datetime, sys
path = sys.argv[1]
start_ts = 0
success_ts = 0
try:
    with open(path, errors="replace") as f:
        for line in f:
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            raw = parts[0]
            try:
                if raw.endswith("Z"):
                    dt = datetime.datetime.fromisoformat(raw[:-1] + "+00:00")
                else:
                    dt = datetime.datetime.fromisoformat(raw)
            except ValueError:
                continue
            ts = int(dt.timestamp())
            if "Starting Hermes state.db backup" in line:
                if ts > start_ts:
                    start_ts = ts
            elif "SUCCESS profiles=" in line:
                if ts > success_ts:
                    success_ts = ts
except OSError:
    pass
print(f"{start_ts} {success_ts}")
PY
)"
    backup_start_ts=0
    backup_success_ts=0
    if [[ -n "${backup_timeline}" ]]; then
        read -r backup_start_ts backup_success_ts <<<"${backup_timeline}"
    fi
    [[ "${backup_start_ts}" =~ ^[0-9]+$ ]] || backup_start_ts=0
    [[ "${backup_success_ts}" =~ ^[0-9]+$ ]] || backup_success_ts=0
    backup_now_ts="$(date +%s)"
    log "check5b backup_exit_code=${backup_exit_code} backup_runs=${backup_runs} last_run_ts=${backup_start_ts} last_success_ts=${backup_success_ts} now=${backup_now_ts}"

    fmt_age() {
        local ts="$1"
        [[ "${ts}" -gt 0 ]] || { printf 'never'; return 0; }
        printf '%sh ago (%s)' "$(( (backup_now_ts - ts) / 3600 ))" "$(date -r "${ts}" '+%Y-%m-%d %H:%M')"
    }

    exit_is_bad=0
    if [[ "${backup_exit_code}" != "0" && "${backup_exit_code}" != "unknown" ]]; then
        exit_is_bad=1
    fi
    run_incomplete=0
    # A run in flight is not a failed run. The mc readiness probe alone can
    # burn 20 x 30 s, so a healthy run legitimately takes ~15 min; an hour is
    # well past that and still inside the hourly watchdog cadence.
    if [[ "${backup_start_ts}" -gt "${backup_success_ts}" && $(( backup_now_ts - backup_start_ts )) -gt "${BACKUP_RUN_INFLIGHT_GRACE_SECONDS}" ]]; then
        run_incomplete=1
    fi

    if [[ "${exit_is_bad}" -eq 1 || "${run_incomplete}" -eq 1 ]]; then
        why=""
        if [[ "${exit_is_bad}" -eq 1 ]]; then
            why="the last scheduled run exited ${backup_exit_code} (launchd runs=${backup_runs})"
        fi
        if [[ "${run_incomplete}" -eq 1 ]]; then
            if [[ -n "${why}" ]]; then
                why="${why}; "
            fi
            why="${why}the last run started $(fmt_age "${backup_start_ts}") and never wrote a SUCCESS line"
        fi
        maybe_alert "backup-job-failed" "Hermes memory watchdog: the nightly state.db backup FAILED - ${why}. Last successful backup: $(fmt_age "${backup_success_ts}"). state.db is the source of record for every agent conversation (ADR-071). Check ${BACKUP_LOG}"
    elif [[ ! -f "${BACKUP_LOG}" ]]; then
        : # check 5 already alerts "backup-missing" for a missing log
    elif [[ "${backup_start_ts}" -eq 0 || $(( backup_now_ts - backup_start_ts )) -gt "${BACKUP_STALE_SECONDS}" ]]; then
        maybe_alert "backup-job-not-run" "Hermes memory watchdog: the nightly state.db backup has not run in over $(( BACKUP_STALE_SECONDS / 3600 ))h (last run: $(fmt_age "${backup_start_ts}")). A Mac that is asleep at 03:30 runs nothing until it wakes, and the watchdog cannot wake a sleeping laptop (ADR-071) - check the machine was awake and that ${BACKUP_LABEL} is still loaded."
    fi
fi

# ---- 6. no Hindsight operation stuck in 'processing' for more than 3 h --------
# Until 2026-10-19 every API restart orphaned in-flight consolidations and left them
# 'processing' forever, blocking whole banks for days. Fixed upstream with a stable worker
# id + Recreate strategy; this is the tripwire if it regresses. Read-only over SSH.
STUCK_HOURS="${STUCK_HOURS:-3}"
HINDSIGHT_DB_HOST="${HINDSIGHT_DB_HOST:-homelab-2nd}"
# No `timeout` binary guaranteed on macOS (that one is homebrew coreutils); ssh keepalives
# bound a hung session instead. One retry first: an mDNS/wifi blip must not page anyone.
read_stuck_ops() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 "${HINDSIGHT_DB_HOST}" \
        'sudo k3s kubectl -n hindsight exec -i hindsight-db-1 -c postgres -- psql -U postgres -d hindsight -tA' \
        <<SQL 2>/dev/null || true
select count(*) from async_operations where status='processing' and updated_at < now() - interval '${STUCK_HOURS} hours';
SQL
}
stuck_ops="$(read_stuck_ops)"
stuck_ops="${stuck_ops//[^0-9]/}"
if [[ -z "${stuck_ops}" ]]; then
    sleep 10
    stuck_ops="$(read_stuck_ops)"
    stuck_ops="${stuck_ops//[^0-9]/}"
fi
# Always log the reading: a tripwire with no record of its own readings proves nothing.
log "check6 hindsight_processing_over_${STUCK_HOURS}h=${stuck_ops:-unreadable}"
if [[ -z "${stuck_ops}" ]]; then
    # Alert (deduplicated), not just a log line: a tripwire that silently cannot read is no tripwire.
    maybe_alert "hindsight-ops-unreadable" "Hermes memory watchdog: could not read Hindsight async_operations via ${HINDSIGHT_DB_HOST} (ssh/kubectl)"
elif [[ "${stuck_ops}" -gt 0 ]]; then
    maybe_alert "hindsight-stuck-ops" "Hermes memory watchdog: ${stuck_ops} Hindsight operation(s) stuck in 'processing' for over ${STUCK_HOURS}h"
fi

# ---- 7. no Gemma model anywhere in a profile config, nor serving calls --------
# Owner rule since 2026-10-19: Gemma hangs on 524s and damages skills. It sat as the default
# profile's fallback #2 for two weeks before both DeepSeek routes 429'd and it took over.
# Parsed YAML, so config comments mentioning Gemma do not count.
while IFS=$'\t' read -r profile hits; do
    if [[ "${profile}" == "__NO_YAML__" ]]; then
        maybe_alert "watchdog-yaml-unavailable" "Hermes memory watchdog: no PyYAML-capable python found (tried: ${YAML_PY}) - the memory-provider and gemma checks cannot run"
        continue
    fi
    maybe_alert "gemma-config-${profile}" "Hermes memory watchdog: profile ${profile} config names a Gemma model (${hits}); fallback chains stay on DeepSeek routes"
done < <("${YAML_PY}" - "${CONFIG_PATHS[@]}" <<'PY'
import sys
try:
    import yaml
except Exception:
    # Same honest report as check 1 - a dead tool, not a broken profile.
    print("__NO_YAML__\tno-yaml")
    raise SystemExit(0)
names = ["default", "andrzej", "florian", "szarik", "zdzislaw"]
def walk(node, path):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, f"{path}.{k}" if path else str(k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, f"{path}[{i}]")
    elif isinstance(node, str) and "gemma" in node.lower():
        yield f"{path}={node}"
for name, path in zip(names, sys.argv[1:]):
    try:
        with open(path) as f:
            cfg = yaml.safe_load(f) or {}
    except Exception:
        continue  # check 1 already alerts on missing/unreadable configs
    hits = list(walk(cfg, ""))
    if hits:
        print(f"{name}\t{'; '.join(hits)[:300]}")
PY
)

gemma_calls="$("${PYTHON_BIN}" - "${LOG_DIR}/agent.log" <<'PY' 2>/dev/null || true
import datetime, re, sys
cutoff = (datetime.datetime.now() - datetime.timedelta(hours=1)).strftime("%Y-%m-%d %H:%M:%S")
n = 0
try:
    with open(sys.argv[1], errors="replace") as f:
        for line in f:
            # Only timestamped lines: traceback continuations carry old model lists.
            if line[:19] >= cutoff and re.match(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d", line) \
                    and re.search(r"model=\S*gemma", line, re.I):
                n += 1
except FileNotFoundError:
    pass
print(n)
PY
)"
gemma_calls="${gemma_calls//[^0-9]/}"
log "check7 gemma_model_log_lines_last_1h=${gemma_calls:-unreadable}"
if [[ "${gemma_calls:-0}" -gt 0 ]]; then
    maybe_alert "gemma-in-use" "Hermes memory watchdog: ${gemma_calls} agent.log line(s) in the last hour show a Gemma model serving calls"
fi

# ---- 8. OpenRouter balance must stay above the floor ---------------------------
# H2-306: Hindsight retain AND consolidation run on OpenRouter credit. At zero balance
# every agent's live memory writes fail, not just background consolidation. The key is
# read inside the cluster and never leaves homelab-2nd; only the remaining USD comes back.
OPENROUTER_FLOOR_USD="${OPENROUTER_FLOOR_USD:-5}"
or_remaining="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 "${HINDSIGHT_DB_HOST:-homelab-2nd}" 'bash -s' 2>/dev/null <<'OR' || true
KEY=$(sudo k3s kubectl -n llm-hub get secret litellm-provider-keys -o jsonpath='{.data.OPENROUTER_API_KEY}' | base64 -d)
curl -s -m 15 -H "Authorization: Bearer $KEY" https://openrouter.ai/api/v1/credits \
  | python3 -c 'import json,sys; d=json.load(sys.stdin).get("data",{}); print("%.2f" % (float(d["total_credits"]) - float(d["total_usage"])))'
unset KEY
OR
)"
if [[ ! "${or_remaining}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    maybe_alert "openrouter-unreadable" "Hermes memory watchdog: could not read the OpenRouter balance via ${HINDSIGHT_DB_HOST:-homelab-2nd}"
else
    log "check8 openrouter_remaining_usd=${or_remaining}"
    if awk "BEGIN{exit !(${or_remaining} < ${OPENROUTER_FLOOR_USD})}"; then
        maybe_alert "openrouter-low" "Hermes memory watchdog: OpenRouter balance is \$${or_remaining} (floor \$${OPENROUTER_FLOOR_USD}). Top up: at zero, every agent's live Hindsight memory writes fail."
    fi
fi

# ---- 9. Claude Code auth (GUL-641) ----------------------------------------
# Primary signal is the CLI's own verdict: it is local, cheap, needs no API
# key, and it is the same JSON the agent's own runtime reads. A bare
# `claude auth login` prompt attempt does not clear it — only an explicit
# "loggedIn": true does, because the verdict is re-read every hour and nothing
# is cached here.
if [[ "${CLAUDE_AUTH_CHECK}" -eq 1 ]]; then
    CLAUDE_AUTH_STATE_FILE="${STATE_DIR}/claude-auth.state"
    claude_prev=""
    if [[ -r "${CLAUDE_AUTH_STATE_FILE}" ]]; then
        claude_prev="$(cat "${CLAUDE_AUTH_STATE_FILE}")"
    fi
    claude_verdict="$(claude_auth_state)"
    printf '%s' "${claude_verdict}" > "${CLAUDE_AUTH_STATE_FILE}"
    case "${claude_verdict}" in
        alive)
            log "check9 claude_auth=loggedIn:true"
            if [[ -n "${claude_prev}" && "${claude_prev}" != "alive" ]]; then
                log "check9 claude_auth RECOVERED from '${claude_prev}'"
            fi
            ;;
        dead:*)
            # 24 h dedupe lives in maybe_alert, so an unresolved login pages
            # once a day, not 24 times.
            log "check9 claude_auth=dead reason=${claude_verdict#dead:}"
            maybe_alert "claude-auth-dead" "$(claude_auth_alert_message "${claude_verdict}")"
            ;;
        *)
            # Unknown is not green and it is not a page either. Say it in the
            # log so a detector that has gone blind is visible rather than
            # silent.
            log "check9 claude_auth=unreadable reason=${claude_verdict#unknown:} - not alerting"
            ;;
    esac
else
    log "check9 skipped: homelab-lib.sh is not installed next to this script"
fi

if [[ "${alert_count}" -eq 0 ]]; then
    log "all checks ok"
fi
