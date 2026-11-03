#!/bin/bash
# ---------------------------------------------------------------------------
# repin-fleet-model.sh — move the whole agent fleet between the two
# `deepseek-v4.1-flash-1017` routes on llm.voitech.dev (GUL-769).
#
#   -ollama  Ollama Pro subscription, weekly allowance, 128k context, free
#            at the margin once the subscription is paid.
#   -ds      DeepSeek's own platform API, pay-per-token, 1M context, no
#            allowance to exhaust. ADR-106 put the fleet here on 2026-10-29
#            because both subscription families were walled.
#
# ADR-106's "when to revisit" is exactly this script's reason to exist: when
# the Ollama allowance resets, the fleet should go back to the subscription it
# already pays for. That happens roughly weekly, so this is a knob, not a
# one-off migration — hence a reviewed script in the repo (ADR-108) instead of
# fifteen hand edits at 01:00.
#
# It touches four surfaces, and *all* of them have to move together or the
# fleet ends up split across two billing models:
#
#   1. Hermes root config          ~/.hermes/config.yaml           (model.default)
#   2. Hermes profile configs      ~/.hermes/profiles/*/config.yaml (model.default)
#   3. Paperclip runner agents     adapterConfig.model, via the local API
#   4. The standalone OpenCode CLI ~/.config/opencode/opencode.json
#                                  (model + small_model)
#
# Not touched, deliberately:
#   - Claude Code (claude_local): spends the Anthropic subscription, a
#     different pocket entirely. ADR-106 exclusion, still correct.
#   - Hermes fallback_providers: the chain's job is to survive the primary
#     being walled, so it stays pointed at its own routes.
#   - ~/.pi/agent/models.json: both ids are already in the llmhub catalog with
#     `reasoning: false`, so there is nothing to add. Verified, not assumed —
#     see preflight.
#
# Written for bash 3.2 (the Air's /bin/bash) and read by CI on Linux: no
# associative arrays, no mapfile, no ${var,,}.
# ---------------------------------------------------------------------------
set -uo pipefail

MODEL_BASE="deepseek-v4.1-flash-1017"
RELAY_URL="https://llm.voitech.dev/v1"
HERMES_HOME="${HERMES_HOME:-/Users/paperclip/.hermes}"
OPENCODE_JSON="${OPENCODE_JSON:-/Users/paperclip/.config/opencode/opencode.json}"
PI_CATALOG="${PI_CATALOG:-/Users/paperclip/.pi/agent/models.json}"
PC_API="${PC_API:-/Users/paperclip/paperclip-agents/claude-code/tools/pc-api.py}"
PC_COMPANY="${PC_COMPANY:-0e2eb054-4cb6-4ea1-a2e7-2b1894285d8c}"
LOG_DIR="${LOG_DIR:-/Users/paperclip/Library/Logs/homelab}"
LOG_FILE="$LOG_DIR/repin-fleet-model.log"
STATUS_FILE="$LOG_DIR/repin-fleet-model.status.json"

# Probe/wait defaults. The caller that runs overnight does not know the exact
# minute the allowance rolls over, so the script waits for the route to answer
# rather than trusting the clock.
WAIT_UNTIL=""         # HH:MM UTC; empty means "probe once, then decide"
PROBE_EVERY=1200      # 20 min between probes
DIRECTION="ollama"
DRY_RUN=0
SKIP_PROBE=0

usage() {
  cat <<'EOF'
Usage: repin-fleet-model.sh [--to-ollama|--to-ds] [options]

  --to-ollama        Pin the fleet to deepseek-v4.1-flash-1017-ollama (default).
                     Probes the route first and refuses to move if it is walled.
  --to-ds            Roll back to deepseek-v4.1-flash-1017-ds (the paid API).
                     This is the "undo" and never waits: it is the escape hatch.
  --wait-until HH:MM UTC deadline for the probe to succeed. Retries every
                     --probe-every seconds until then. Without it, one probe.
  --probe-every N    Seconds between probes (default 1200).
  --skip-probe       Pin without probing. For when a human already checked.
  --dry-run          Print the plan, change nothing.
  -h, --help         This text.

Exit codes: 0 repinned (or already correct) · 2 route walled, fleet left alone
            1 a surface failed to move — read the log, the fleet may be split.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --to-ollama)  DIRECTION="ollama" ;;
    --to-ds)      DIRECTION="ds" ;;
    --wait-until) WAIT_UNTIL="${2:-}"; shift ;;
    --probe-every) PROBE_EVERY="${2:-1200}"; shift ;;
    --skip-probe) SKIP_PROBE=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

if [ "$DIRECTION" = "ollama" ]; then
  TO_MODEL="$MODEL_BASE-ollama";  FROM_MODEL="$MODEL_BASE-ds"
else
  TO_MODEL="$MODEL_BASE-ds";      FROM_MODEL="$MODEL_BASE-ollama"
fi
# Paperclip and OpenCode address the relay through the `llmhub/` provider
# prefix; Hermes uses the bare id against its own custom_provider.
TO_PREFIXED="llmhub/$TO_MODEL"
FROM_PREFIXED="llmhub/$FROM_MODEL"

mkdir -p "$LOG_DIR"
TS() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s %s\n' "$(TS)" "$*" | tee -a "$LOG_FILE"; }

FAILED=0
CHANGED=0
note_fail() { FAILED=$((FAILED + 1)); log "FAIL  $*"; }

log "=== repin-fleet-model.sh start: $FROM_MODEL -> $TO_MODEL (dry_run=$DRY_RUN) ==="

# --- the relay key -------------------------------------------------------
# Lives in ~/.hermes/.env with every other live credential. Sourced, never
# echoed: this script runs unattended into a log file that is not a secret.
if [ -z "${LM_API_KEY:-}" ]; then
  if [ -r "$HERMES_HOME/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$HERMES_HOME/.env"; set +a
  fi
fi
if [ -z "${LM_API_KEY:-}" ]; then
  log "FATAL no LM_API_KEY (looked in the environment and $HERMES_HOME/.env)"
  exit 1
fi

# --- preflight: the target id must exist, and pi must already know it ----
# ADR-106 learned both of these the hard way: an id the relay does not publish
# fails as an opaque UnknownError from the OpenCode server, and a pi catalog
# entry with `reasoning: true` against a route that does not declare
# reasoning_effort is a hard 400, not a retry.
preflight() {
  local models
  models=$(curl -sS -m 30 -H "Authorization: Bearer $LM_API_KEY" "$RELAY_URL/models" 2>>"$LOG_FILE") || {
    log "FATAL cannot list models on $RELAY_URL"; return 1; }
  if ! printf '%s' "$models" | grep -q "\"$TO_MODEL\""; then
    log "FATAL the relay does not publish $TO_MODEL"; return 1
  fi
  log "ok    relay publishes $TO_MODEL"

  if [ -r "$PI_CATALOG" ]; then
    python3 - "$PI_CATALOG" "$TO_MODEL" <<'PY' >>"$LOG_FILE" 2>&1 || return 1
import json, sys
path, want = sys.argv[1], sys.argv[2]
cat = json.load(open(path))
for pname, prov in cat.get("providers", {}).items():
    for m in prov.get("models", []):
        if m.get("id") == want:
            if m.get("reasoning") is True:
                print("FATAL pi catalog has %s with reasoning:true (hard 400 on this route)" % want)
                sys.exit(1)
            sys.exit(0)
print("FATAL pi catalog (%s) has no entry for %s" % (path, want))
sys.exit(1)
PY
    log "ok    pi catalog has $TO_MODEL with reasoning disabled"
  else
    log "warn  pi catalog $PI_CATALOG unreadable; skipping that check"
  fi
  return 0
}

# --- probe: is the route actually serving? -------------------------------
# Two things have to hold. The call must not 429 (the Ollama Pro allowance),
# and the response must come back as the model we asked for — the -go family
# was caught silently substituting deepseek for qwen (ADR-106), and a route
# that lies about its identity is worse than one that refuses.
probe_route() {
  local body http served
  body=$(curl -sS -m 90 -w $'\n%{http_code}' -X POST "$RELAY_URL/chat/completions" \
    -H "Authorization: Bearer $LM_API_KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$TO_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ready\"}],\"max_tokens\":24}" \
    2>>"$LOG_FILE")
  http=$(printf '%s' "$body" | tail -n1)
  body=$(printf '%s' "$body" | sed '$d')
  if [ "$http" != "200" ]; then
    log "probe http=$http  $(printf '%s' "$body" | head -c 240)"
    return 1
  fi
  served=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("model",""))' 2>/dev/null)
  if [ "$served" != "$TO_MODEL" ]; then
    log "probe http=200 but served model was '$served', not '$TO_MODEL' (substitution)"
    return 1
  fi
  log "probe ok: $TO_MODEL answered 200 and identified as itself"
  return 0
}

# Retry until the UTC deadline. The failure mode this protects against is
# flipping onto a still-walled route and waking up to a fleet of 429s; staying
# on the paid route costs money, which is the cheaper mistake.
wait_for_route() {
  [ "$SKIP_PROBE" = "1" ] && { log "probe skipped (--skip-probe)"; return 0; }
  local deadline_epoch now
  while :; do
    probe_route && return 0
    [ -z "$WAIT_UNTIL" ] && return 1
    deadline_epoch=$(python3 - "$WAIT_UNTIL" <<'PY'
import datetime as dt, sys
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = dt.datetime.now(dt.timezone.utc)
target = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if target <= now:                      # a deadline already past today is tomorrow's
    target += dt.timedelta(days=1)
print(int(target.timestamp()))
PY
)
    now=$(date -u '+%s')
    if [ "$now" -ge "$deadline_epoch" ]; then
      log "deadline $WAIT_UNTIL UTC reached and the route is still not serving"
      return 1
    fi
    log "retrying in ${PROBE_EVERY}s (deadline $WAIT_UNTIL UTC)"
    sleep "$PROBE_EVERY"
  done
}

# --- edit guards ---------------------------------------------------------
# Exactly one line may differ between the file and its backup, the line count
# must be unchanged, and the changed line must contain both the key we aimed
# at and the value we meant to write. Catches a greedy regex, a mangled
# heredoc and a replacement on the wrong key, none of which a parser would.
check_single_line_edit() {
  local file="$1" backup="$2" key="$3" value="$4" changed_lines new_line
  if [ "$(wc -l <"$file" | tr -d ' ')" != "$(wc -l <"$backup" | tr -d ' ')" ]; then
    log "      line count changed"
    return 1
  fi
  changed_lines=$(diff "$backup" "$file" | grep -c '^>')
  if [ "$changed_lines" != "1" ]; then
    log "      expected 1 changed line, got $changed_lines"
    return 1
  fi
  new_line=$(diff "$backup" "$file" | grep '^>' | head -1)
  case "$new_line" in
    *"$key"*"$value"*) return 0 ;;
    *) log "      changed line is not '$key … $value': $new_line"; return 1 ;;
  esac
}

# PyYAML is not installed on the Air and macOS ruby ships psych, so try both.
# A missing parser is reported as a missing parser — never as a bad file. The
# old version of this check conflated the two, which at 01:00 unattended means
# the repin silently never happens.
yaml_parses() {
  local file="$1"
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$file" 2>>"$LOG_FILE" && return 0
    return 1
  fi
  if [ -x /usr/bin/ruby ]; then
    /usr/bin/ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$file" 2>>"$LOG_FILE" && return 0
    return 1
  fi
  log "      no YAML parser available (no PyYAML, no ruby); relying on the structural check"
  return 0
}

# --- surface 1+2: the Hermes configs ------------------------------------
# Edited line-by-line rather than through a YAML round-trip on purpose: these
# files carry the comment trail of every past model decision (which ADR, which
# issue, which quota wall), and yaml.safe_dump would throw all of it away.
# Only a `default:` line holding the exact from-id is rewritten, so nothing
# else in a 24k-line config can be caught by accident.
repin_yaml() {
  local file="$1" label="$2" backup
  [ -f "$file" ] || { log "skip  $label: $file does not exist"; return 0; }
  if ! grep -qE "^[[:space:]]*default:[[:space:]]*$FROM_MODEL[[:space:]]*$" "$file"; then
    if grep -qE "^[[:space:]]*default:[[:space:]]*$TO_MODEL[[:space:]]*$" "$file"; then
      log "ok    $label already on $TO_MODEL"
    else
      log "warn  $label has no 'default: $FROM_MODEL' line — left untouched, check it by hand"
    fi
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then log "PLAN  $label: default: $FROM_MODEL -> $TO_MODEL"; return 0; fi

  backup="$file.bak-gul769-$(date -u '+%Y%m%d-%H%M%S')"
  cp -p "$file" "$backup" || { note_fail "$label: backup failed"; return 1; }

  python3 - "$file" "$FROM_MODEL" "$TO_MODEL" <<'PY' || { note_fail "$label: rewrite failed"; cp -p "$backup" "$file"; return 1; }
import re, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
pat = re.compile(r'^([ \t]*default:[ \t]*)%s([ \t]*)$' % re.escape(old), re.M)
out, n = pat.subn(lambda m: m.group(1) + new + m.group(2), src)
if n != 1:
    sys.exit("expected exactly one 'default: %s' line, replaced %d" % (old, n))
open(path, "w").write(out)
PY

  # A config that does not parse takes the gateway down on its next request,
  # so anything unexpected puts the backup straight back.
  #
  # The structural check is the real guarantee and needs nothing installed:
  # the edit must have changed exactly one line, kept the line count, and that
  # line must be the `default:` we aimed at. That is stricter than a YAML
  # parse, which would happily accept the right syntax on the wrong key.
  if ! check_single_line_edit "$file" "$backup" "default:" "$TO_MODEL"; then
    cp -p "$backup" "$file"
    note_fail "$label: unexpected diff after rewrite, restored $(basename "$backup")"
    return 1
  fi
  if ! yaml_parses "$file"; then
    cp -p "$backup" "$file"
    note_fail "$label: result is not valid YAML, restored $(basename "$backup")"
    return 1
  fi
  CHANGED=$((CHANGED + 1))
  log "ok    $label -> $TO_MODEL (backup $(basename "$backup"))"
}

# --- surface 4: the OpenCode CLI ----------------------------------------
# `model` and `small_model` both, and the id must be enumerated under
# provider.llmhub.models or the local server answers UnknownError (ADR-106).
repin_opencode() {
  local file="$OPENCODE_JSON" backup
  [ -f "$file" ] || { log "skip  opencode.json: $file does not exist"; return 0; }

  if ! python3 -c '
import json,sys
cfg=json.load(open(sys.argv[1]))
want=sys.argv[2]
models=cfg.get("provider",{}).get("llmhub",{}).get("models",{})
sys.exit(0 if want in models else 1)' "$file" "$TO_MODEL"; then
    note_fail "opencode.json: $TO_MODEL is not enumerated under provider.llmhub.models"
    return 1
  fi

  if ! grep -qE "\"(small_)?model\"[[:space:]]*:[[:space:]]*\"$FROM_PREFIXED\"" "$file"; then
    log "ok    opencode.json already off $FROM_PREFIXED"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then log "PLAN  opencode.json: model+small_model -> $TO_PREFIXED"; return 0; fi

  backup="$file.bak-gul769-$(date -u '+%Y%m%d-%H%M%S')"
  cp -p "$file" "$backup" || { note_fail "opencode.json: backup failed"; return 1; }

  python3 - "$file" "$FROM_PREFIXED" "$TO_PREFIXED" <<'PY' || { note_fail "opencode.json: rewrite failed"; cp -p "$backup" "$file"; return 1; }
import re, sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
# Only the two top-level keys, never the provider.llmhub.models catalog below,
# which must keep listing every id the CLI is allowed to select.
pat = re.compile(r'^([ \t]*"(?:small_)?model"[ \t]*:[ \t]*")%s(")' % re.escape(old), re.M)
out, n = pat.subn(lambda m: m.group(1) + new + m.group(2), src)
if n == 0:
    sys.exit("no top-level model/small_model line held %s" % old)
open(path, "w").write(out)
print("rewrote %d key(s)" % n)
PY

  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" 2>>"$LOG_FILE"; then
    cp -p "$backup" "$file"
    note_fail "opencode.json: result is not valid JSON, restored $(basename "$backup")"
    return 1
  fi
  # Two lines here, not one: `model` and `small_model`. The catalog under
  # provider.llmhub.models must come out untouched, so the count is exact.
  if [ "$(diff "$backup" "$file" | grep -c '^>')" != "2" ]; then
    cp -p "$backup" "$file"
    note_fail "opencode.json: expected exactly 2 changed lines, restored $(basename "$backup")"
    return 1
  fi
  if ! python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1]))
want = sys.argv[2]
assert cfg.get("model") == want, "model is %r" % cfg.get("model")
assert cfg.get("small_model") == want, "small_model is %r" % cfg.get("small_model")
' "$file" "$TO_PREFIXED" 2>>"$LOG_FILE"; then
    cp -p "$backup" "$file"
    note_fail "opencode.json: read-back does not show $TO_PREFIXED, restored $(basename "$backup")"
    return 1
  fi
  CHANGED=$((CHANGED + 1))
  log "ok    opencode.json -> $TO_PREFIXED (backup $(basename "$backup"))"
}

# --- surface 3: the Paperclip runner agents ------------------------------
# Discovered by querying for the from-model rather than hardcoding the seven
# ids: an agent hired tomorrow is caught automatically, and a renamed one does
# not silently stay behind. PATCH /agents/:id shallow-merges adapterConfig when
# replaceAdapterConfig is absent, so sending the single `model` key leaves cwd,
# extraArgs, instructions paths and the rest exactly as they were.
repin_paperclip() {
  [ -f "$PC_API" ] || { log "skip  paperclip: $PC_API not found"; return 0; }
  local listing ids id name rc

  listing=$(HOME=/Users/paperclip python3 "$PC_API" GET "/companies/$PC_COMPANY/agents" 2>>"$LOG_FILE")
  if [ "$(printf '%s' "$listing" | head -n1)" != "200" ]; then
    note_fail "paperclip: listing agents failed ($(printf '%s' "$listing" | head -n1))"
    return 1
  fi

  # `python3 -c` and not `python3 - <<EOF`: a heredoc *is* stdin, so it would
  # shadow the piped agent listing and the filter would read nothing.
  ids=$(printf '%s' "$listing" | tail -n +2 | python3 -c '
import json, sys
want = sys.argv[1]
for a in json.load(sys.stdin):
    cfg = a.get("adapterConfig") or {}
    if cfg.get("model") == want:
        print("%s\t%s" % (a["id"], a["name"]))
' "$FROM_PREFIXED")
  if [ -z "$ids" ]; then
    log "ok    paperclip: no agent left on $FROM_PREFIXED"
    return 0
  fi

  # A `for` over newline-split lines, not `… | while read`: bash 3.2 has no
  # lastpipe, so a piped while loop would count its successes in a subshell
  # and every increment would be thrown away on exit.
  local old_ifs="$IFS"
  IFS='
'
  for line in $ids; do
    IFS="$old_ifs"
    id=${line%%	*}
    name=${line#*	}
    [ -n "$id" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
      log "PLAN  paperclip $name ($id) -> $TO_PREFIXED"
    else
      rc=$(HOME=/Users/paperclip python3 "$PC_API" PATCH "/agents/$id" \
            "{\"adapterConfig\":{\"model\":\"$TO_PREFIXED\"}}" 2>>"$LOG_FILE" | head -n1)
      if [ "$rc" = "200" ]; then
        CHANGED=$((CHANGED + 1))
        log "ok    paperclip $name -> $TO_PREFIXED"
      else
        note_fail "paperclip $name ($id): PATCH returned $rc"
      fi
    fi
    IFS='
'
  done
  IFS="$old_ifs"
}

# --- verification --------------------------------------------------------
# Reports what the fleet looks like *after* the edits, by reading the same
# surfaces back. "Verify before you report done" applies to a 01:00 cron job
# more than to anything else, because nobody is watching it.
verify() {
  log "--- read-back ---"
  local f
  for f in "$HERMES_HOME/config.yaml" "$HERMES_HOME"/profiles/*/config.yaml; do
    [ -f "$f" ] || continue
    log "      $(printf '%-52s' "${f#"$HERMES_HOME"/}") $(grep -m1 -E '^[[:space:]]*default:' "$f" | sed 's/^[[:space:]]*default:[[:space:]]*//')"
  done
  if [ -f "$OPENCODE_JSON" ]; then
    log "      $(printf '%-52s' 'opencode.json model/small_model') $(python3 -c '
import json,sys
c=json.load(open(sys.argv[1])); print(c.get("model"), "/", c.get("small_model"))' "$OPENCODE_JSON" 2>/dev/null)"
  fi
  if [ -f "$PC_API" ]; then
    HOME=/Users/paperclip python3 "$PC_API" GET "/companies/$PC_COMPANY/agents" 2>/dev/null | tail -n +2 | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    m=(a.get("adapterConfig") or {}).get("model")
    if m: print("      %-52s %s" % (a["name"], m))
' | tee -a "$LOG_FILE"
  fi
}

write_status() {
  python3 - "$STATUS_FILE" "$1" "$TO_MODEL" "$FROM_MODEL" "$CHANGED" "$FAILED" <<'PY'
import datetime as dt, json, sys
path, outcome, to_model, from_model, changed, failed = sys.argv[1:7]
json.dump({
    "at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    "outcome": outcome, "from": from_model, "to": to_model,
    "surfaces_changed": int(changed), "failures": int(failed),
}, open(path, "w"), indent=2)
PY
}

# --- run -----------------------------------------------------------------
preflight || { write_status "preflight_failed"; exit 1; }

if [ "$DIRECTION" = "ollama" ]; then
  if ! wait_for_route; then
    log "RESULT route not serving — fleet stays on $FROM_MODEL (still paying, still working)"
    write_status "route_walled"
    exit 2
  fi
fi

repin_yaml "$HERMES_HOME/config.yaml" "hermes root (Bill Cipher)"
for profile_cfg in "$HERMES_HOME"/profiles/*/config.yaml; do
  [ -f "$profile_cfg" ] || continue
  profile_name=$(basename "$(dirname "$profile_cfg")")
  repin_yaml "$profile_cfg" "hermes profile $profile_name"
done
repin_opencode
repin_paperclip

# No gateway restart: the Hermes API server re-reads config.yaml per request,
# so a model.default edit lands on the next run. Restarting ai.hermes.gateway
# would hit every profile at once and is the owner's call, never a cron job's.
log "note  no gateway restart needed — model.default is read per request"

verify

if [ "$DRY_RUN" = "1" ]; then
  log "RESULT dry run — nothing was changed"
  exit 0
fi
if [ "$FAILED" -gt 0 ]; then
  log "RESULT $CHANGED pin(s) moved, $FAILED failed — the fleet may be SPLIT across both routes"
  write_status "partial"
  exit 1
fi
log "RESULT fleet is on $TO_MODEL ($CHANGED pin(s) changed)"
write_status "ok"
exit 0
