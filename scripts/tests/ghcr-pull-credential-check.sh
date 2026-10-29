#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/tests/ghcr-pull-credential-check.sh — GUL-579 / ADR-103
#
# Proves the platform pull-credential mechanism end to end WITHOUT a real
# GitHub token and WITHOUT the repo age key: an ephemeral age keypair and a
# throwaway sops config stand in for both. What is asserted:
#
#   1. `mint` reads the token from stdin (no argv, no prompt on a pipe) and
#      writes one encrypted dockerconfigjson per namespace.
#   2. The plaintext token never appears in the output file.
#   3. `add` extends an existing file to a new namespace from the CIPHERTEXT
#      alone - the agent path, no human and no second token.
#   4. All namespaces carry byte-identical credentials: one credential, many
#      namespaces (the whole point of ADR-103).
#   5. `mint` refuses an empty token and `add` refuses when no file exists.
#
# Skips cleanly when sops or age-keygen are absent (CI installs neither, and
# check.sh must never need a key).
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/scripts/ghcr-pull-credential.sh"
TOKEN='fake-token-not-a-credential-0042'
USER=testuser

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

for tool in sops age-keygen python3; do
  command -v "$tool" >/dev/null || { printf 'skip: %s not installed\n' "$tool"; exit 0; }
done

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

if ! age-keygen -o "$W/age.txt" 2>/dev/null; then
  printf 'skip: age-keygen failed\n'; exit 0
fi
PUB=$(grep -E '^# public key:' "$W/age.txt" | awk '{print $NF}')
[ -n "$PUB" ] || { printf 'skip: could not read the generated public key\n'; exit 0; }
cat > "$W/sops.yaml" <<EOF
creation_rules:
  - path_regex: \.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: $PUB
EOF
export SOPS_AGE_KEY_FILE="$W/age.txt"

OUT="$W/ghcr-pull.sops.yaml"

# ---- 1. mint ---------------------------------------------------------------
if printf '%s\n' "$TOKEN" | bash "$SCRIPT" mint --config "$W/sops.yaml" --out "$OUT" \
     --user "$USER" riffradar flux-system >"$W/mint.log" 2>&1; then
  ok "mint wrote the file"
else
  bad "mint failed: $(tr '\n' ' ' < "$W/mint.log")"; printf '%s\n' "  (nothing more to test)"; exit 1
fi

[ -f "$OUT" ] && ok "file exists" || bad "no file at $OUT"

docs=$(grep -c '^kind: Secret' "$OUT" || true)
[ "$docs" = "2" ] && ok "two Secret docs (riffradar + flux-system)" \
  || bad "expected 2 Secret docs, got $docs"

enc=$(grep -c '\.dockerconfigjson: ENC\[' "$OUT" || true)
[ "$enc" = "2" ] && ok "both dockerconfigjson values are ciphertext" \
  || bad "expected 2 encrypted values, got $enc"

if grep -qF -- "$TOKEN" "$OUT"; then
  bad "the plaintext token is in the encrypted file"
else
  ok "no plaintext token in the file"
fi

if grep -qF -- "ghcr.io" "$OUT"; then
  bad "the registry host leaked into the ciphertext file"
else
  ok "no plaintext registry payload either"
fi

# ---- 2. decrypt and inspect -----------------------------------------------
if sops -d --config "$W/sops.yaml" "$OUT" 2>/dev/null > "$W/plain.yaml"; then
  ok "file decrypts with the ephemeral key"
else
  bad "file does not decrypt"; printf 'check: FAILED\n'; exit 1
fi

for ns in riffradar flux-system; do
  grep -qE "^[[:space:]]+namespace: ${ns}$" "$W/plain.yaml" && ok "namespace $ns present" \
    || bad "namespace $ns missing"
done
grep -qE "^[[:space:]]+name: ghcr-pull$" "$W/plain.yaml" && ok "secret name is ghcr-pull" \
  || bad "secret name is not ghcr-pull"

auth=$(printf '%s:%s' "$USER" "$TOKEN" | base64 | tr -d '\n')
n_auth=$(grep -cF -- "$auth" "$W/plain.yaml" || true)
[ "$n_auth" = "2" ] && ok "both namespaces carry the same auth blob" \
  || bad "expected the auth blob twice, found $n_auth"

# ---- 3. add ----------------------------------------------------------------
if bash "$SCRIPT" add --config "$W/sops.yaml" --out "$OUT" newsvc >"$W/add.log" 2>&1; then
  ok "add extended the file without the token"
else
  bad "add failed: $(tr '\n' ' ' < "$W/add.log")"
fi

if sops -d --config "$W/sops.yaml" "$OUT" 2>/dev/null > "$W/plain2.yaml"; then
  docs2=$(grep -c '^kind: Secret' "$OUT" || true)
  [ "$docs2" = "3" ] && ok "three Secret docs after add" \
    || bad "expected 3 Secret docs after add, got $docs2"
  n_auth2=$(grep -cF -- "$auth" "$W/plain2.yaml" || true)
  [ "$n_auth2" = "3" ] && ok "the new namespace carries the credential too" \
    || bad "expected the auth blob 3 times, found $n_auth2"
  grep -qE '^[[:space:]]+namespace: newsvc$' "$W/plain2.yaml" && ok "namespace newsvc present" \
    || bad "namespace newsvc missing"
else
  bad "the file does not decrypt after add"
fi

# `add` twice with the same namespace must not duplicate the doc.
bash "$SCRIPT" add --config "$W/sops.yaml" --out "$OUT" newsvc >/dev/null 2>&1
docs3=$(grep -c '^kind: Secret' "$OUT" || true)
[ "$docs3" = "3" ] && ok "add is idempotent for an existing namespace" \
  || bad "add duplicated a namespace ($docs3 docs)"

# ---- 4. refusals ----------------------------------------------------------
if printf '\n' | bash "$SCRIPT" mint --config "$W/sops.yaml" --out "$W/empty.sops.yaml" \
     --user "$USER" riffradar >/dev/null 2>&1; then
  bad "mint accepted an empty token"
else
  ok "mint refuses an empty token"
fi
[ -f "$W/empty.sops.yaml" ] && bad "mint wrote a file for an empty token" \
  || ok "nothing written for an empty token"

if bash "$SCRIPT" add --config "$W/sops.yaml" --out "$W/missing.sops.yaml" riffradar \
     >/dev/null 2>&1; then
  bad "add ran without an existing credential file"
else
  ok "add refuses when there is no credential to copy"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then echo "check: PASSED"; exit 0; fi
echo "check: FAILED"; exit 1
