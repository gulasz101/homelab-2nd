#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1199 - Retire OpenViking from GitOps: the acceptance gate.
#
# HAND-RUN ONLY. This file lives in apps/tests/, which is not referenced from
# apps/kustomization.yaml, so Flux never reconciles it (same ruling as
# apps/hindsight/tests/ and apps/zigbee/tests/).
#
# It answers the five acceptance criteria of the work order in one pass, one
# line per AC, in the factory protocol (agents/factory/CONTRACT.md point 2):
#
#   AC-1  apps/openviking/ holds only namespace.yaml and the four *.sops.yaml
#         files; every other OpenViking manifest is gone.
#   AC-2  apps/kustomization.yaml carries no `openviking/` resource entry
#         (read out of `.resources` with yq), a comment naming GUL-355 sits
#         where that block used to be, and the Honcho comment no longer
#         mentions H2-295 (the "drip-deletion gate" was superseded by the
#         GUL-355 decision, so an H2-295 reference there is stale text).
#   AC-3  the OpenViking / Honcho credential names are gone from apps/:
#         OPENVIKING_KEY, MEMORY_HONCHO_KEY, OPENVIKING_API_KEY,
#         openviking-key, memory-honcho-key. The *.sops.yaml files keep their
#         keys (they are the encrypted secrets, not references to them) and
#         apps/tests/ is excluded because this file has to spell the names out.
#         Case-insensitive: `openviking_key` in a shell script is the same
#         credential as `OPENVIKING_KEY` in a Deployment.
#   AC-4  the whole tree still renders (`kubectl kustomize apps`) and the
#         render contains no `namespace: openviking` and no `openviking.svc` -
#         that second one is the OpenChamber MCP entry, the last live consumer.
#   AC-5  scripts/render_namespace_dashboard.py no longer ships the honcho
#         usage example (`--namespace honcho`): a copy-paste recipe for a
#         namespace that no longer exists.
#
# Exit: 0 = every AC passes, 1 = at least one AC fails, 2 = this check could
#       not run (a missing binary - the ACs would then be unproven, not green).
#
# Usage: bash apps/tests/openviking-retired-check.sh
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || exit 2
cd "$ROOT" || exit 2

OV_DIR='apps/openviking'
KUST='apps/kustomization.yaml'
DASHBOARD='scripts/render_namespace_dashboard.py'
SOPS_KEEP='openviking-mattermost-webhook-url.sops.yaml
openviking-minio-backup-creds.sops.yaml
openviking-root-api-key.sops.yaml
openviking-vlm-api-key.sops.yaml'
# The credential names this work order retires (AC-3).
TOKENS='OPENVIKING_KEY|MEMORY_HONCHO_KEY|OPENVIKING_API_KEY|openviking-key|memory-honcho-key'

rc=0
note() { printf '  %s\n' "$*" >&2; }

# One AC line, and remember the verdict for the exit code.
verdict() {
  local id=$1 reason=$2
  if [ -z "$reason" ]; then
    printf '%s: PASS\n' "$id"
  else
    printf '%s: FAIL %s\n' "$id" "$reason"
    rc=1
  fi
}

# --- 0. the binaries this gate reads with --------------------------------
# yq is the read AC-2 is defined on, kubectl supplies AC-4's render, git
# supplies AC-3's grep. Without them the ACs are unproven, and reporting FAIL
# would blame the manifests for a broken runner.
for bin in git yq kubectl; do
  command -v "$bin" > /dev/null 2>&1 || {
    printf 'setup error: %s is not on PATH - this check cannot read the ACs it covers\n' "$bin" >&2
    exit 2
  }
done

# =========================================================================
# AC-1: apps/openviking/ holds only namespace.yaml + the four *.sops.yaml
# =========================================================================
ac1=''
if [ ! -d "$OV_DIR" ]; then
  ac1="$OV_DIR/ is gone entirely - the namespace and its four encrypted secrets must stay"
else
  [ -f "$OV_DIR/namespace.yaml" ] || ac1="$OV_DIR/namespace.yaml is missing; "
  for path in "$OV_DIR"/*; do
    [ -e "$path" ] || continue
    base=${path##*/}
    case "$base" in
      namespace.yaml) ;;
      *.sops.yaml) ;;
      *) ac1="${ac1}${base} is still there; " ;;
    esac
  done
  # The four secrets are named, not merely counted: a stray fifth *.sops.yaml
  # is a manifest that survived the retirement under a name nobody reads.
  while IFS= read -r want; do
    [ -f "$OV_DIR/$want" ] || ac1="${ac1}${want} is missing; "
  done <<< "$SOPS_KEEP"
  for path in "$OV_DIR"/*.sops.yaml; do
    [ -e "$path" ] || continue
    base=${path##*/}
    printf '%s\n' "$SOPS_KEEP" | grep -qxF "$base" || ac1="${ac1}${base} is not one of the four secrets this ticket keeps; "
  done
fi
verdict AC-1 "$(printf '%s' "$ac1" | sed 's/; *$//')"

# =========================================================================
# AC-2: apps/kustomization.yaml
# =========================================================================
ac2=''

# 2a. no resource entry starts with openviking/ (read out of .resources).
ov_entries=$(yq '.resources[]' "$KUST" | grep -E '^"?openviking/' || true)
ov_count=$(printf '%s\n' "$ov_entries" | grep -c . || true)
if [ "${ov_count:-0}" -ne 0 ]; then
  ac2="${ac2}.resources still lists ${ov_count} openviking/ entr$( [ "$ov_count" -eq 1 ] && echo y || echo ies ); "
fi

# 2b. a comment naming GUL-355 sits where the block used to be - between the
# last shlink/ entry and the arr-stack/ entry that followed it. A note parked
# somewhere else in the file does not tell the next reader what happened here.
last_shlink=$(grep -n 'shlink/' "$KUST" | tail -1 | cut -d: -f1)
arr_stack=$(grep -n '^[[:space:]]*- arr-stack/' "$KUST" | head -1 | cut -d: -f1)
if [ -n "$last_shlink" ] && [ -n "$arr_stack" ]; then
  gul355_here=$(awk -v lo="$last_shlink" -v hi="$arr_stack" '
    NR > lo && NR < hi && /^[[:space:]]*#/ && /GUL-355/ { print NR; exit }' "$KUST")
else
  gul355_here=$(grep -nE '^[[:space:]]*#.*GUL-355' "$KUST" | head -1 | cut -d: -f1)
fi
if [ -z "${gul355_here:-}" ]; then
  if grep -qE '^[[:space:]]*#.*GUL-355' "$KUST"; then
    ac2="${ac2}the GUL-355 comment exists but not where the openviking/ block was (lines ${last_shlink:-?}-${arr_stack:-?} of ${KUST}); "
  else
    ac2="${ac2}no comment names GUL-355 in ${KUST} where the openviking/ block was; "
  fi
fi

# 2c. the Honcho comment no longer mentions H2-295. Scoped to that comment
# block: the block is the run of comment lines that opens with the
# decommission note, and H2-295 inside it is the stale gate reference.
honcho_block=$(awk '
  !f && /^[[:space:]]*#/ && /Honcho decommissioned/ { f = 1 }
  f && /^[[:space:]]*#/ { print NR": "$0; next }
  f { exit }
' "$KUST")
if [ -z "$honcho_block" ]; then
  ac2="${ac2}the Honcho decommission comment block is gone - AC-2 only asks it to drop the H2-295 reference, and losing the note loses the reason apps/honcho went; "
elif printf '%s\n' "$honcho_block" | grep -q 'H2-295'; then
  ac2="${ac2}the Honcho comment still mentions H2-295 (superseded by GUL-355): $(printf '%s\n' "$honcho_block" | grep -o 'H2-295' | head -1); "
fi

verdict AC-2 "$(printf '%s' "$ac2" | sed 's/; *$//')"

# =========================================================================
# AC-3: no OpenViking / Honcho credential name left in apps/
# =========================================================================
ac3=''
# git grep, not a filesystem walk: this must see what the repo tracks, and
# the two explicit excludes are part of the AC (the *.sops.yaml files keep
# their keys, and this script has to spell the names out).
token_hits=$(git grep -I -i -n -E "$TOKENS" -- 'apps/' \
  ':(exclude)*.sops.yaml' ':(exclude)apps/tests/' )
token_n=$(printf '%s\n' "$token_hits" | grep -c . || true)
if [ "${token_n:-0}" -ne 0 ]; then
  files=$(printf '%s\n' "$token_hits" | cut -d: -f1 | sort -u | tr '\n' ' ')
  ac3="${token_n} reference(s) to a retired credential name survive in apps/ (${files% })"
fi
verdict AC-3 "$ac3"

# =========================================================================
# AC-4: the tree renders, and the render knows nothing of openviking
# =========================================================================
ac4=''
if render=$(kubectl kustomize apps); then
  ns_hits=$(printf '%s\n' "$render" | grep -c 'namespace: openviking' || true)
  svc_hits=$(printf '%s\n' "$render" | grep -c 'openviking\.svc' || true)
  render_objs=$(printf '%s\n' "$render" | grep -c '^kind:' || true)
  note "kubectl kustomize apps -> ${render_objs} object(s)"
  if [ "${ns_hits:-0}" -ne 0 ]; then
    ac4="${ns_hits} object(s) still render into the openviking namespace; "
  fi
  if [ "${svc_hits:-0}" -ne 0 ]; then
    ac4="${ac4}${svc_hits} line(s) still point at openviking.svc (an OpenChamber MCP entry left behind); "
  fi
else
  ac4="kubectl kustomize apps does not render - the retirement broke the tree"
fi
verdict AC-4 "$(printf '%s' "$ac4" | sed 's/; *$//')"

# =========================================================================
# AC-5: no honcho usage example in the dashboard renderer
# =========================================================================
ac5=''
if [ ! -f "$DASHBOARD" ]; then
  ac5="$DASHBOARD is missing"
else
  dash_hits=$(grep -nF -e '--namespace honcho' "$DASHBOARD" || true)
  if [ -n "$dash_hits" ]; then
    ac5="$DASHBOARD still documents the honcho example at line(s) $(printf '%s\n' "$dash_hits" | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')"
  fi
fi
verdict AC-5 "$ac5"

note "-------------------------------------------------------------"
if [ "$rc" -eq 0 ]; then
  note "result: all five acceptance criteria hold - OpenViking is retired"
else
  note "result: at least one acceptance criterion still fails"
fi
exit "$rc"
