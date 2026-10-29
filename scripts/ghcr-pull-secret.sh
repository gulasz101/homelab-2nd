#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Encrypt a GHCR pull credential straight into a SOPS Secret (dockerconfigjson).
#
# The token is READ SILENTLY from the terminal (no echo, no shell history, no
# clipboard) and never touches disk in plaintext: it goes into a 0600 temp file in
# the repo root, sops encrypts it to the target path using this repo's .sops.yaml
# creation rule, and the temp file is shredded before the script exits.
#
# Usage:
#   scripts/ghcr-pull-secret.sh <namespace> <secret-name> [github-user] [out-file] [extra-namespace]
#
# Example (Riff Radar demo, GUL-550) - the image is pulled by the kubelet in
# `riffradar` AND scanned by image-reflector-controller in `flux-system`, so the
# same dockerconfigjson is written as two documents in one encrypted file:
#   scripts/ghcr-pull-secret.sh riffradar riffradar-ghcr-pull gulasz101 \
#     apps/riffradar/riffradar-ghcr-pull-secret.sops.yaml flux-system
#
# The token needs `read:packages` ONLY (classic PAT) or Packages: Read
# (fine-grained). Nothing else: it is a pull credential, not a deploy key.
# ---------------------------------------------------------------------------
set -euo pipefail

ns=${1:-}
name=${2:-}
user=${3:-gulasz101}
out=${4:-}
extra_ns=${5:-}

if [ -z "$ns" ] || [ -z "$name" ] || [ -z "$out" ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

command -v sops >/dev/null || { echo "sops is not installed"; exit 1; }

printf 'GHCR token for %s (input hidden): ' "$user" >&2
IFS= read -rs token
printf '\n' >&2
[ -n "${token:-}" ] || { echo "empty token, nothing written" >&2; exit 1; }

tmp=$(mktemp "$root/.ghcr-pull.XXXXXX.yaml")
chmod 600 "$tmp"
trap 'rm -f "$tmp"' EXIT

GHCR_USER="$user" GHCR_TOKEN="$token" GHCR_NS="$ns" GHCR_NAME="$name" GHCR_EXTRA_NS="$extra_ns" python3 - "$tmp" <<'PY'
import base64, json, os, sys

user = os.environ['GHCR_USER']
tok = os.environ['GHCR_TOKEN']
name = os.environ['GHCR_NAME']
doc = {'auths': {'ghcr.io': {
    'username': user,
    'password': tok,
    'auth': base64.b64encode(f'{user}:{tok}'.encode()).decode(),
}}}
# json.dumps output is a valid YAML double-quoted scalar once JSON-escaped again,
# so the script needs no PyYAML to write the manifest.
payload = json.dumps(json.dumps(doc))

spaces = [os.environ['GHCR_NS']]
extra = os.environ.get('GHCR_EXTRA_NS', '').strip()
if extra:
    spaces.append(extra)

out = []
for ns in spaces:
    out.append(
        'apiVersion: v1\n'
        'kind: Secret\n'
        'metadata:\n'
        f'  name: {name}\n'
        f'  namespace: {ns}\n'
        'type: kubernetes.io/dockerconfigjson\n'
        'stringData:\n'
        f'  .dockerconfigjson: {payload}\n'
    )

with open(sys.argv[1], 'w') as f:
    f.write('---\n'.join(out))
PY

unset token

sops -e --config "$root/.sops.yaml" --input-type yaml --output-type yaml "$tmp" > "$out"
echo "wrote $out"
grep -c 'ENC\[' "$out" | sed 's/^/encrypted values: /'
echo
echo "Now list it in the consuming kustomization.yaml and commit the ciphertext."
echo "The plaintext never existed outside this shell."
