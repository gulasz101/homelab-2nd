#!/usr/bin/env bash
# Re-sync apps/arr-stack/arr-stack-api-keys.sops.yaml with the LIVE API keys
# held by the running arr-stack apps.
#
# Why: the *arr apps own their API keys in their own config. A rebuild/restore
# can repopulate those configs from backup with keys that differ from Git,
# which breaks Homepage widgets (and historically CrashLoopBackOff'd Bazarr).
# Run this after any arr-stack config restore, then commit + push.
#
# See docs/adr/adr-014-arr-stack-api-keys-owned-by-apps.md
#     docs/arr-stack-recovery.md
#
# Key values are NEVER printed.
set -euo pipefail

NS="${NS:-arr-stack}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_FILE="$REPO_ROOT/apps/arr-stack/arr-stack-api-keys.sops.yaml"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
command -v sops    >/dev/null || { echo "ERROR: sops not found"    >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 not found" >&2; exit 1; }

sha() { printf %s "$1" | sha256sum | cut -c1-12; }

read_xml_key() { # <app> <container> <tag> <path>
  kubectl -n "$NS" exec "deploy/$1" -c "$2" -- \
    sed -n "s:.*<$3>\([^<]*\)</$3>.*:\1:p" "$4" 2>/dev/null | tr -d '\r\n'
}

read_bazarr_key() {
  # Bazarr 1.6 stores the key as `auth:\n  apikey: <value>` in config.yaml.
  kubectl -n "$NS" exec deploy/bazarr -c bazarr -- \
    awk '/^auth:/ {f=1; next} f && /apikey:/ {sub(/.*apikey:[ \t]*/,""); print; exit}' \
    /config/config/config.yaml 2>/dev/null | tr -d '" \t\r\n'
}

sync_key() { # <logical-name> <value>
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "  $name: EMPTY — SKIPPED (is the pod running?)" >&2
    return 1
  fi
  local lit
  lit="$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$value")"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  $name: len=${#value} sha=$(sha "$value")  (dry-run)"
  else
    sops set "$SECRET_FILE" "[\"stringData\"][\"$name-api-key\"]" "$lit"
    echo "  $name: len=${#value} sha=$(sha "$value")  written"
  fi
}

echo "Syncing $(realpath --relative-to="$REPO_ROOT" "$SECRET_FILE" 2>/dev/null || echo "$SECRET_FILE") from live '$NS' apps"
echo "(key values are not printed; $([[ $DRY_RUN == 1 ]] && echo 'DRY RUN' || echo 'WRITING'))"

sync_key sonarr   "$(read_xml_key sonarr   sonarr   ApiKey /config/config.xml)"
sync_key radarr   "$(read_xml_key radarr   radarr   ApiKey /config/config.xml)"
sync_key prowlarr "$(read_xml_key prowlarr prowlarr ApiKey /config/config.xml)"
sync_key bazarr   "$(read_bazarr_key)"

echo
echo "Not auto-synced (see ADR-014): jellyfin-api-key (stable) and qbittorrent-password (set in-app once)."
if [[ "$DRY_RUN" == "0" ]]; then
  echo
  echo "Next:"
  echo "  git add apps/arr-stack/arr-stack-api-keys.sops.yaml && git commit -m 'fix(arr-stack): re-sync api keys after restore' && git push"
  echo "  kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt=\"\$(date +%s)\" --overwrite"
  echo "  kubectl -n arr-stack rollout restart deploy/homepage"
fi
