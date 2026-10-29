#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ghcr-pull-credential.sh — THE pull credential for private images (ADR-103).
#
# One classic GitHub PAT with `read:packages` and nothing else, stored as a
# SOPS-encrypted dockerconfigjson Secret named `ghcr-pull`. The same Secret is
# written once per namespace that runs a private image, plus `flux-system`,
# where image-reflector-controller reads it through ImageRepository.secretRef.
#
#   mint <ns>...   HUMAN, once. Reads the token silently from the terminal and
#                  writes the encrypted file. The token never reaches disk in
#                  plaintext, never appears in argv, never lands in history.
#   add  <ns>...   AGENT, whenever a new namespace needs the credential. The
#                  token is decrypted out of the existing SOPS file with the repo
#                  age key. No human, no new GitHub token, no new click.
#
# Options: --user <github-user>   --out <file>   --config <sops-config>
#          --name <secret-name>
#
# Examples:
#   scripts/ghcr-pull-credential.sh mint riffradar
#   scripts/ghcr-pull-credential.sh add newsvc
#
# Token scope: classic PAT, `read:packages` ONLY. This is a pull credential for
# one account's private packages; it is not a deploy key. A broad `gh` token
# (write:packages, admin:org, repo) must never be used here.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$REPO/infrastructure/ghcr-pull/ghcr-pull.sops.yaml"
CFG="$REPO/.sops.yaml"
SECRET=ghcr-pull
GH_USER=gulasz101

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

mode=${1:-}
case "$mode" in
  mint|add) shift ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "unknown mode '$mode' (want mint or add)" >&2; exit 2 ;;
esac

ns_list=()
while [ $# -gt 0 ]; do
  case "$1" in
    --user)   GH_USER=$2; shift 2 ;;
    --out)    OUT=$2;     shift 2 ;;
    --config) CFG=$2;     shift 2 ;;
    --name)   SECRET=$2;  shift 2 ;;
    --*)      echo "unknown option $1" >&2; exit 2 ;;
    *)        ns_list+=("$1"); shift ;;
  esac
done
[ ${#ns_list[@]} -gt 0 ] || { echo "give at least one namespace" >&2; exit 2; }
command -v sops >/dev/null || { echo "sops is not installed" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is not installed" >&2; exit 1; }

TMP=$(mktemp "${TMPDIR:-/tmp}/ghcr-pull.XXXXXX")
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"

# ---- payload: the dockerconfigjson document, as a JSON *string* -----------
if [ "$mode" = mint ]; then
  printf 'GHCR token for %s (input hidden): ' "$GH_USER" >&2
  IFS= read -rs token || true
  printf '\n' >&2
  [ -n "${token:-}" ] || { echo "empty token, nothing written" >&2; exit 1; }
  PAYLOAD=$(GHCR_USER="$GH_USER" GHCR_TOKEN="$token" python3 -c '
import base64, json, os
u, t = os.environ["GHCR_USER"], os.environ["GHCR_TOKEN"]
print(json.dumps({"auths": {"ghcr.io": {
    "username": u,
    "password": t,
    "auth": base64.b64encode(f"{u}:{t}".encode()).decode(),
}}}))
')
else
  [ -f "$OUT" ] || {
    echo "$OUT does not exist yet: run '$0 mint <ns>...' first." >&2
    echo "The token can only be created by the account owner (ADR-103)." >&2
    exit 1
  }
  DEC=$(sops -d --config "$CFG" "$OUT")
  PAYLOAD=$(printf '%s\n' "$DEC" | python3 -c '
import json, sys
val = None
for line in sys.stdin:
    line = line.strip()
    if line.startswith(".dockerconfigjson:"):
        raw = line.split(":", 1)[1].strip()
        # sops may emit a quoted scalar or a bare JSON object; both are a YAML
        # scalar holding the dockerconfigjson. json.loads unquotes the first
        # form and passes the second straight through.
        try:
            val = json.loads(raw)
        except ValueError:
            val = raw
        break
if val is None:
    sys.exit("no .dockerconfigjson in the decrypted file")
print(val)
')
  # Union of the namespaces already in the file and the ones asked for.
  while IFS= read -r ns; do
    [ -n "$ns" ] && ns_list+=("$ns")
  done < <(printf '%s\n' "$DEC" | awk '/^[[:space:]]+namespace:[[:space:]]*/{sub(/^[[:space:]]+namespace:[[:space:]]*/,""); print}')
fi

NS=$(printf '%s\n' "${ns_list[@]}" | awk 'NF && !seen[$0]++' | sort)
n=$(printf '%s\n' "$NS" | grep -c . || true)
[ "$n" -gt 0 ] || { echo "no namespaces to write" >&2; exit 1; }

# ---- write the SOPS docs ------------------------------------------------
NS="$NS" PAYLOAD="$PAYLOAD" SECRET="$SECRET" python3 - > "$TMP" <<'PY'
import json, os

payload = os.environ["PAYLOAD"]          # the dockerconfigjson as a JSON string
secret = os.environ["SECRET"]
docs = []
for ns in [n for n in os.environ["NS"].split("\n") if n]:
    docs.append(
        "apiVersion: v1\n"
        "kind: Secret\n"
        "metadata:\n"
        f"  name: {secret}\n"
        f"  namespace: {ns}\n"
        "type: kubernetes.io/dockerconfigjson\n"
        "stringData:\n"
        f"  .dockerconfigjson: {json.dumps(payload)}\n"
    )
print("---\n".join(docs), end="")
PY

mkdir -p "$(dirname "$OUT")"
# --filename-override: creation rules must be matched against the FILE WE ARE
# WRITING, not against the 0600 temp path sops was handed. Without it a rule
# like `path_regex: .*\.sops\.yaml$` never matches and sops exits "no matching
# creation rules found".
sops -e --config "$CFG" --filename-override "$OUT" \
  --input-type yaml --output-type yaml "$TMP" > "$OUT"

# ---- prove the ciphertext is shaped right, without printing anything ------
enc=$(grep -c '\.dockerconfigjson: ENC\[' "$OUT" || true)
[ "$enc" = "$n" ] || {
  echo "FAIL: $OUT has $enc encrypted .dockerconfigjson values, expected $n" >&2
  exit 1
}
if [ "$mode" = mint ]; then
  if grep -qF -- "$token" "$OUT"; then
    echo "FAIL: the plaintext token appears in $OUT — delete it and rotate the token" >&2
    exit 1
  fi
  unset token
fi

echo "wrote $OUT"
echo "namespaces ($n): $(printf '%s' "$NS" | tr '\n' ' ')"
echo
echo "Next, if this is the first write:"
echo "  1. list it in infrastructure/kustomization.yaml:"
echo "       - ghcr-pull/ghcr-pull.sops.yaml"
echo "  2. in every consuming namespace, the pod spec needs:"
echo "       imagePullSecrets: [ { name: $SECRET } ]"
echo "     and its ImageRepository needs:"
echo "       secretRef: { name: $SECRET }"
echo "The plaintext never existed outside this shell."
