#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-1242: the Karakeep summary prompt lives in git as a ConfigMap, and a
# one-shot Job converges the live Karakeep account onto it.
#
# Why: Wojtek picked option (a) on GUL-1183 - Karakeep keeps a stock custom
# summary prompt, `brew.py` stays the Morning Brew writer. That prompt was
# created over tRPC on 2026-11-09 and lives only in Karakeep's `customPrompts`
# table, on a `local-path` PVC on a node that is not durable. A node loss
# silently drops it. Chart `karakeep` 0.34.1 has no values for custom prompts
# (`prompts.ts` reads the DB and nothing else), so this is a raw manifest pair:
# a ConfigMap that holds the text, and a Job that makes Karakeep match it.
#
# These six checks are one script because the work order's spec points every AC
# at the same command; the factory runs it once and reads six `AC-n:` lines.
#
# AC-1: a `kind: ConfigMap` with `metadata.namespace: karakeep` under
#       apps/karakeep (test paths skipped) has a `data` key whose value - with
#       one trailing newline stripped, so `|` and `|-` both work - is exactly
#       480 characters and sha256
#       15d5c297e90c10ed62a8a7eb9a6fd2cfd3d7df9b64e83053d249d60689c70ca2.
#       A scan that finds no such ConfigMap fails loudly instead of passing
#       over an empty set.
#
# AC-2: a `kind: Job` in namespace karakeep is named `karakeep-prompt-v<N>`
#       (N = one or more digits - jobs are immutable, so a text bump means a
#       new name and Flux prunes the old one) and its `checksum/prompt`
#       annotation equals the sha256 the check RECOMPUTES from the ConfigMap
#       above. A stale annotation - text edited, Job name not bumped - fails.
#
# AC-3: that Job has at least one initContainer whose command actually waits on
#       the `karakeep` Service (a probe tool - curl/wget/nc/ncat/nslookup/
#       getent - against a `karakeep` host, inside a repeat - until/while/
#       retry/sleep), and `spec.backoffLimit >= 3` written explicitly so a cold
#       start retries instead of failing the Flux reconcile.
#
# AC-4: every `KARAKEEP_API_KEY` env entry in the Job comes from
#       secretKeyRef name `karakeep-app-secrets`, key `KARAKEEP_API_KEY`, and
#       never from a literal `value:`; and that key name exists in
#       apps/karakeep/karakeep-app-secrets.sops.yaml. Key NAMES only: SOPS
#       keeps them in plaintext, so yq answers "does this key exist" without
#       decrypting. `sops -d` is forbidden here (CI has no age key) and the
#       value is never printed.
#
# AC-5: the Job's script (its container command/args plus any ConfigMap it
#       mounts as a volume) calls `prompts.list`, `prompts.delete` and
#       `prompts.create`, and no mutation line carries `?batch=1` - the batched
#       tRPC form answers "Invalid input: expected object, received undefined".
#       `prompts.list` is the one call the batched form is correct for. Whole
#       comment lines are ignored, so a comment may explain that rule.
#
# AC-6: both discovered manifest files are listed in the karakeep block of
#       apps/kustomization.yaml (there is no kustomization inside
#       apps/karakeep/) and `kubectl kustomize apps` exits 0.
#
# Deliberately yq + coreutils + `kubectl kustomize` only, bash 3.2 (macOS) and
# ubuntu-latest: no network, no cluster, no sops, no python. yq v4.54.1 is the
# version pinned in .github/workflows/check.yaml.
#
# Discovered and run by scripts/check.sh (it globs */tests/*-check.sh); listed
# in no Kustomization, so Flux never sees it.
#
# Usage: bash apps/karakeep/tests/prompt-job-check.sh
# Exit:  0 = every AC passes, 1 = at least one AC fails, 2 = the check could
#        not run (yq/kubectl/sha256 missing)
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$ROOT" || exit 2

die_setup() { printf 'prompt-job-check: %s\n' "$1" >&2; exit 2; }

command -v yq >/dev/null 2>&1 || die_setup "yq is not on PATH - the check cannot run"
command -v kubectl >/dev/null 2>&1 || die_setup "kubectl is not on PATH - AC-6 needs kubectl kustomize"

SHA_CMD=""
if command -v sha256sum >/dev/null 2>&1; then
  SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA_CMD="shasum -a 256"
else
  die_setup "neither sha256sum nor shasum is on PATH"
fi

EXPECTED_SHA=15d5c297e90c10ed62a8a7eb9a6fd2cfd3d7df9b64e83053d249d60689c70ca2
EXPECTED_LEN=480
SCAN_ROOT=apps/karakeep
SECRET_FILE=apps/karakeep/karakeep-app-secrets.sops.yaml
SECRET_NAME=karakeep-app-secrets
SECRET_KEY=KARAKEEP_API_KEY
KUSTOMIZATION=apps/kustomization.yaml
JOB_NAME_RE='^karakeep-prompt-v[0-9]+$'
# Row delimiter. NOT a tab: tab is IFS whitespace, so an EMPTY leading field (a
# secretKeyRef env has no `.value`, so its first field is empty) is collapsed by
# `read` and every later field shifts left - that silently made AC-4 report a
# literal value on a correct manifest. `|` is never whitespace and never appears
# in a name, a namespace or a document index.
SEP='|'

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

sha_of() { printf '%s' "$1" | $SHA_CMD | cut -d' ' -f1; }

# looksLikeTestPath from agents/factory-guard/policy.ts (CONTRACT.md point 6):
# fixtures living next to a check must never be read as production manifests.
is_test_path() {
  local lower base
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  base=${lower##*/}
  case "/$lower" in
    */tests/*|*/test/*) return 0 ;;
  esac
  case "$base" in
    *.test.*|*_test.*|test_*.py) return 0 ;;
  esac
  return 1
}

# ---- discovery: every ConfigMap and Job document under apps/karakeep --------
# Rows are "file|doc-index|name|namespace". The document index lets
# every later query pick that ONE document back out of a multi-doc file, so a
# file that holds both the ConfigMap and the Job is handled, not guessed at.
CM_ROWS=""
JOB_ROWS=""
broken=""

while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_test_path "$f" && continue
  grep -Eq '^kind: *"?(ConfigMap|Job)"? *$' "$f" || continue
  rows=$(yq -r 'select(.kind == "ConfigMap" or .kind == "Job")
                | [(.kind), (di | tostring), (.metadata.name // ""), (.metadata.namespace // "")]
                | join("|")' "$f" 2>&1) || {
    broken="$broken; $f: $(printf '%s' "$rows" | head -1)"
    continue
  }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    kind=${row%%"$SEP"*}
    rest=${row#*"$SEP"}
    di=${rest%%"$SEP"*}
    rest=${rest#*"$SEP"}
    name=${rest%%"$SEP"*}
    ns=${rest#*"$SEP"}
    case "$kind" in
      ConfigMap) CM_ROWS="$CM_ROWS$f$SEP$di$SEP$name$SEP$ns
" ;;
      Job) JOB_ROWS="$JOB_ROWS$f$SEP$di$SEP$name$SEP$ns
" ;;
    esac
  done <<< "$rows"
done < <(find "$SCAN_ROOT" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

# Count of ConfigMap rows, whichever namespace they claim.
cm_seen=$(printf '%s' "$CM_ROWS" | grep -c . || true)
job_seen=$(printf '%s' "$JOB_ROWS" | grep -c . || true)

# ---- AC-1: the ConfigMap holds the prompt text -----------------------------
PROMPT_FILE=""
PROMPT_DI=""
PROMPT_NAME=""
PROMPT_KEY=""
PROMPT_VALUE=""
PROMPT_SHA=""
CM_IN_NS=0
CM_OTHER_NS=""
CM_HINTS=""

if [ -n "$CM_ROWS" ]; then
  while IFS="$SEP" read -r f di name ns; do
    [ -n "$f" ] || continue
    if [ "$ns" != "karakeep" ]; then
      CM_OTHER_NS="$CM_OTHER_NS; $(basename "$f")/$name has namespace '${ns:-<unset>}'"
      continue
    fi
    CM_IN_NS=$((CM_IN_NS + 1))
    keys=$(yq -r "select(di == $di) | ((.data // {}) | keys | .[])" "$f" 2>&1) || {
      broken="$broken; $f: $(printf '%s' "$keys" | head -1)"
      continue
    }
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      v=$(yq -r "select(di == $di) | .data[\"$k\"]" "$f" 2>&1) || {
        broken="$broken; $f: $(printf '%s' "$v" | head -1)"
        continue
      }
      s=$(sha_of "$v")
      n=${#v}
      if [ "$s" = "$EXPECTED_SHA" ] && [ "$n" -eq "$EXPECTED_LEN" ]; then
        PROMPT_FILE=$f
        PROMPT_DI=$di
        PROMPT_NAME=$name
        PROMPT_KEY=$k
        PROMPT_VALUE=$v
        PROMPT_SHA=$s
        continue
      fi
      # Short, value-free diagnostics: a length and a sha prefix, never text.
      CM_HINTS="$CM_HINTS; $(basename "$f")/$name key '$k': ${n} chars, sha256 $(printf '%s' "$s" | cut -c1-12)…"
    done <<< "$keys"
  done <<< "$CM_ROWS"
fi

if [ -n "$broken" ]; then
  ac1="FAIL unreadable YAML${broken}"
elif [ -n "$PROMPT_FILE" ]; then
  ac1="PASS"
elif [ -z "$CM_ROWS" ]; then
  ac1="FAIL found no ConfigMap under $SCAN_ROOT - a scan that matches nothing cannot report PASS"
elif [ "$CM_IN_NS" -eq 0 ]; then
  ac1="FAIL no ConfigMap sets metadata.namespace: karakeep${CM_OTHER_NS}"
elif [ -n "$CM_HINTS" ]; then
  ac1="FAIL no data key holds the prompt (want ${EXPECTED_LEN} chars, sha256 ${EXPECTED_SHA})${CM_HINTS}"
else
  ac1="FAIL ConfigMap has no data keys"
fi

# ---- AC-2: the Job name and its checksum/prompt annotation -----------------
JOB_COUNT=0
JOB_FILE=""
JOB_DI=""
JOB_NAME=""
JOB_NS_BAD=""
JOB_BAD=""

if [ -n "$JOB_ROWS" ]; then
  while IFS="$SEP" read -r f di name ns; do
    [ -n "$f" ] || continue
    printf '%s' "$name" | grep -Eq "$JOB_NAME_RE" || continue
    if [ "$ns" != "karakeep" ]; then
      JOB_NS_BAD="$JOB_NS_BAD; $(basename "$f")/$name is in namespace '${ns:-<unset>}', want karakeep"
      continue
    fi
    JOB_COUNT=$((JOB_COUNT + 1))
    if [ -z "$JOB_FILE" ]; then
      JOB_FILE=$f
      JOB_DI=$di
      JOB_NAME=$name
    fi
    ann=$(yq -r "select(di == $di) | (.metadata.annotations // {})[\"checksum/prompt\"] // \"\"" "$f" 2>&1) || {
      broken="$broken; $f: $(printf '%s' "$ann" | head -1)"
      continue
    }
    if [ -z "$PROMPT_SHA" ]; then
      JOB_BAD="$JOB_BAD; $name: cannot recompute the checksum - no ConfigMap holds the prompt text (AC-1)"
    elif [ -z "$ann" ]; then
      JOB_BAD="$JOB_BAD; $name: no metadata.annotations['checksum/prompt']"
    elif [ "$ann" != "$PROMPT_SHA" ]; then
      JOB_BAD="$JOB_BAD; $name: checksum/prompt is stale ('${ann}'), the ConfigMap text now hashes to $PROMPT_SHA"
    fi
  done <<< "$JOB_ROWS"
fi

if [ -n "$broken" ]; then
  ac2="FAIL unreadable YAML${broken}"
elif [ -z "$JOB_ROWS" ]; then
  ac2="FAIL found no Job under $SCAN_ROOT - a scan that matches nothing cannot report PASS"
elif [ "$JOB_COUNT" -eq 0 ]; then
  ac2="FAIL no Job in namespace karakeep is named karakeep-prompt-v<N>${JOB_NS_BAD}"
elif [ -n "$JOB_BAD" ]; then
  ac2="FAIL ${JOB_BAD#; }"
else
  ac2="PASS"
fi

# ---- AC-3: the initContainer wait and backoffLimit -------------------------
AC3_BAD=""
if [ "$JOB_COUNT" -gt 0 ]; then
  while IFS="$SEP" read -r f di name ns; do
    [ -n "$f" ] || continue
    printf '%s' "$name" | grep -Eq "$JOB_NAME_RE" || continue
    [ "$ns" = "karakeep" ] || continue

    init_n=$(yq -r "select(di == $di) | ((.spec.template.spec.initContainers // []) | length)" "$f" 2>&1) || {
      broken="$broken; $f: $(printf '%s' "$init_n" | head -1)"
      continue
    }
    if [ "${init_n:-0}" -eq 0 ]; then
      AC3_BAD="$AC3_BAD; $name: no initContainers - nothing waits for the karakeep Service"
    else
      i=0
      wait_ok=0
      while [ "$i" -lt "$init_n" ]; do
        iname=$(yq -r "select(di == $di) | .spec.template.spec.initContainers[$i].name // \"\"" "$f" 2>&1) || iname=""
        # Only the command text counts: the container NAME must not be what
        # satisfies the "mentions karakeep" half of this check.
        text=$(yq -r "select(di == $di) | .spec.template.spec.initContainers[$i]
                      | ((.command // []) + (.args // [])) | .[]" "$f" 2>&1) || text=""
        if printf '%s' "$text" | grep -Eq 'karakeep([:.]|/|$|[^a-zA-Z0-9_-])' \
           && printf '%s' "$text" | grep -Eqi '(curl|wget|nc|ncat|nslookup|getent)' \
           && printf '%s' "$text" | grep -Eqi '(until|while|retry|sleep)'; then
          wait_ok=1
        fi
        i=$((i + 1))
      done
      if [ "$wait_ok" -eq 0 ]; then
        AC3_BAD="$AC3_BAD; $name: no initContainer probes the karakeep Service in a retry loop (need a probe tool against a 'karakeep' host inside until/while/retry/sleep)"
      fi
    fi

    bl=$(yq -r "select(di == $di) | (.spec.backoffLimit // \"\") | tostring" "$f" 2>&1) || bl=""
    if [ -z "$bl" ]; then
      AC3_BAD="$AC3_BAD; $name: no explicit spec.backoffLimit - write >= 3 so a cold start retries instead of failing the reconcile"
    elif ! printf '%s' "$bl" | grep -Eq '^[0-9]+$'; then
      AC3_BAD="$AC3_BAD; $name: spec.backoffLimit '$bl' is not a number"
    elif [ "$bl" -lt 3 ]; then
      AC3_BAD="$AC3_BAD; $name: spec.backoffLimit $bl is below 3"
    fi
  done <<< "$JOB_ROWS"
fi

if [ -n "$broken" ]; then
  ac3="FAIL unreadable YAML${broken}"
elif [ "$JOB_COUNT" -eq 0 ]; then
  ac3="FAIL no Job named karakeep-prompt-v<N> in namespace karakeep to inspect"
elif [ -n "$AC3_BAD" ]; then
  ac3="FAIL ${AC3_BAD#; }"
else
  ac3="PASS"
fi

# ---- AC-4: KARAKEEP_API_KEY comes from the Secret, and the key exists ------
AC4_BAD=""
if [ "$JOB_COUNT" -gt 0 ]; then
  while IFS="$SEP" read -r f di name ns; do
    [ -n "$f" ] || continue
    printf '%s' "$name" | grep -Eq "$JOB_NAME_RE" || continue
    [ "$ns" = "karakeep" ] || continue

    envs=$(yq -r "select(di == $di) | .spec.template.spec
                   | ((.containers // []) + (.initContainers // []))
                   | .[] | (.env // []) | .[]
                   | select((.name // \"\") == \"KARAKEEP_API_KEY\")
                   | [(.value // \"\"), (.valueFrom.secretKeyRef.name // \"\"), (.valueFrom.secretKeyRef.key // \"\")]
                   | join(\"|\")" "$f" 2>&1) || {
      broken="$broken; $f: $(printf '%s' "$envs" | head -1)"
      continue
    }
    found=0
    while IFS="$SEP" read -r lit sname skey; do
      [ -n "$lit$sname$skey" ] || continue
      found=$((found + 1))
      if [ -n "$lit" ]; then
        AC4_BAD="$AC4_BAD; $name: KARAKEEP_API_KEY is a literal value - it must come from secretKeyRef"
      fi
      if [ "$sname" != "$SECRET_NAME" ]; then
        AC4_BAD="$AC4_BAD; $name: KARAKEEP_API_KEY secretKeyRef name is '${sname:-<unset>}', want $SECRET_NAME"
      fi
      if [ "$skey" != "$SECRET_KEY" ]; then
        AC4_BAD="$AC4_BAD; $name: KARAKEEP_API_KEY secretKeyRef key is '${skey:-<unset>}', want $SECRET_KEY"
      fi
    done <<< "$envs"
    if [ "$found" -eq 0 ]; then
      AC4_BAD="$AC4_BAD; $name: no env var KARAKEEP_API_KEY in any container"
    fi
  done <<< "$JOB_ROWS"
fi

# Key names only. yq reads the SOPS shape without decrypting, and no value is
# ever selected - the AC only asks whether the key name is there.
secret_keys=""
if [ -f "$SECRET_FILE" ]; then
  secret_keys=$(yq -r 'select(.kind == "Secret")
                       | select((.metadata.name // "") == strenv(SECRET_NAME))
                       | (((.stringData // {}) | keys) + ((.data // {}) | keys))
                       | .[]' "$SECRET_FILE" 2>&1) || {
    secret_keys=""
    broken="$broken; $SECRET_FILE: unreadable (yq)"
  }
else
  AC4_BAD="$AC4_BAD; $SECRET_FILE does not exist"
fi
if [ -n "$secret_keys" ] && ! printf '%s\n' "$secret_keys" | grep -qx "$SECRET_KEY"; then
  AC4_BAD="$AC4_BAD; $SECRET_FILE has no $SECRET_KEY key (keys found: $(printf '%s' "$secret_keys" | tr '\n' ' '))"
fi

if [ -n "$broken" ]; then
  ac4="FAIL unreadable YAML${broken}"
elif [ "$JOB_COUNT" -eq 0 ]; then
  ac4="FAIL no Job named karakeep-prompt-v<N> in namespace karakeep to inspect"
elif [ -n "$AC4_BAD" ]; then
  ac4="FAIL ${AC4_BAD#; }"
else
  ac4="PASS"
fi

# ---- AC-5: the script's tRPC calls, and no ?batch=1 on a mutation ----------
AC5_BAD=""
if [ "$JOB_COUNT" -gt 0 ]; then
  while IFS="$SEP" read -r f di name ns; do
    [ -n "$f" ] || continue
    printf '%s' "$name" | grep -Eq "$JOB_NAME_RE" || continue
    [ "$ns" = "karakeep" ] || continue

    script_file="$TMPD/$name.script"
    : > "$script_file"
    yq -r "select(di == $di) | .spec.template.spec
           | ((.containers // []) + (.initContainers // [])) | .[]
           | ((.command // []) + (.args // [])) | .[]" "$f" >> "$script_file" 2>&1

    # A script may live in a ConfigMap the Job mounts instead of in its
    # command. Follow the volumes by name so both shapes are covered.
    vols=$(yq -r "select(di == $di) | (.spec.template.spec.volumes // []) | .[]
                  | (.configMap.name // \"\")" "$f" 2>&1) || vols=""
    while IFS= read -r vol; do
      [ -n "$vol" ] || continue
      [ -n "$CM_ROWS" ] || continue
      while IFS="$SEP" read -r cf cdi cname cns; do
        [ -n "$cf" ] || continue
        [ "$cname" = "$vol" ] || continue
        yq -r "select(di == $cdi) | ((.data // {}) | .[])" "$cf" >> "$script_file" 2>&1
      done <<< "$CM_ROWS"
    done <<< "$vols"

    # Whole comment lines are dropped: an explanatory comment saying "never
    # batch a mutation" is not a violation, and a call that only appears in a
    # comment is not a call.
    code_file="$TMPD/$name.code"
    awk '{ t=$0; sub(/^[ \t]+/, "", t); if (substr(t,1,1) == "#") next; print }' \
      "$script_file" > "$code_file"

    for want in prompts.list prompts.delete prompts.create; do
      grep -Fq "$want" "$code_file" || AC5_BAD="$AC5_BAD; $name: the script never calls $want"
    done

    # A mutation and ?batch=1 on the same line is the broken batched form. The
    # list call is the one that legitimately carries ?batch=1.
    batch_hits=$(awk '
      { t=$0; sub(/^[ \t]+/, "", t)
        if (substr(t,1,1) == "#") next
        if (t ~ /batch=1/ && t ~ /prompts\.(create|delete)/) print "line " NR ": " t
      }' "$code_file")
    if [ -n "$batch_hits" ]; then
      first=$(printf '%s' "$batch_hits" | head -1)
      AC5_BAD="$AC5_BAD; $name: a mutation carries ?batch=1 ($first) - the batched form answers 'Invalid input: expected object, received undefined'"
    fi
  done <<< "$JOB_ROWS"
fi

if [ -n "$broken" ]; then
  ac5="FAIL unreadable YAML${broken}"
elif [ "$JOB_COUNT" -eq 0 ]; then
  ac5="FAIL no Job named karakeep-prompt-v<N> in namespace karakeep to inspect"
elif [ -n "$AC5_BAD" ]; then
  ac5="FAIL ${AC5_BAD#; }"
else
  ac5="PASS"
fi

# ---- AC-6: both manifests are in the kustomization, and it builds ----------
AC6_BAD=""
if [ ! -f "$KUSTOMIZATION" ]; then
  AC6_BAD="$AC6_BAD; $KUSTOMIZATION does not exist"
else
  entries=$(yq -r '(.resources // []) | .[]' "$KUSTOMIZATION" 2>&1) || {
    entries=""
    AC6_BAD="$AC6_BAD; $KUSTOMIZATION is unreadable (yq)"
  }
  missing_note=""
  for want_file in "$PROMPT_FILE" "$JOB_FILE"; do
    if [ -z "$want_file" ]; then
      if [ -z "$missing_note" ]; then
        AC6_BAD="$AC6_BAD; nothing to look up - no prompt ConfigMap/Job was found (AC-1/AC-2)"
        missing_note=1
      fi
      continue
    fi
    want="karakeep/$(basename "$want_file")"
    if ! printf '%s\n' "$entries" | grep -qxF "$want"; then
      AC6_BAD="$AC6_BAD; $KUSTOMIZATION has no '$want' entry"
    fi
  done
fi

kout="$TMPD/kustomize.out"
if ! kubectl kustomize apps > "$kout" 2> "$TMPD/kustomize.err"; then
  kerr=$(head -1 "$TMPD/kustomize.err")
  AC6_BAD="$AC6_BAD; kubectl kustomize apps fails: ${kerr:-no stderr}"
fi

if [ -n "$AC6_BAD" ]; then
  ac6="FAIL ${AC6_BAD#; }"
else
  ac6="PASS"
fi

# ---- report ---------------------------------------------------------------
printf 'prompt-job-check: %s ConfigMap and %s Job document(s) under %s; prompt ConfigMap %s key %s\n' \
  "${cm_seen:-0}" "${job_seen:-0}" "$SCAN_ROOT" \
  "${PROMPT_NAME:-<none>}" "${PROMPT_KEY:-<none>}" >&2

failed=0
for pair in "1:$ac1" "2:$ac2" "3:$ac3" "4:$ac4" "5:$ac5" "6:$ac6"; do
  n=${pair%%:*}
  r=${pair#*:}
  printf 'AC-%s: %s\n' "$n" "$r"
  case "$r" in
    PASS) : ;;
    *) failed=1 ;;
  esac
done

exit "$failed"
