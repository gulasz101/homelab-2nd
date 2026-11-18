#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 2026-11-18: the LiteLLM Admin UI is SSO-only, and it must stay that way.
#
# Why this exists: the UI had a working local login nobody configured. With
# UI_PASSWORD unset, LiteLLM falls back to the MASTER KEY as the UI password for
# the username `admin` (get_ui_credentials() in proxy/auth/login_utils.py), so
# the Admin UI answered to a shared static secret. LiteLLM's own security banner
# said so; a stale comment in the HelmRelease claimed the opposite ("no
# UI_USERNAME/UI_PASSWORD ... hides the local login form"). Nothing in the repo
# caught the difference, so this script does: the flags below are asserted, and
# a reintroduced env credential fails the gate.
#
# Hermetic: reads one file, no network, no cluster, no sops, no git writes.
# bash 3.2 compatible (macOS) - no associative arrays.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
MANIFEST="${REPO_ROOT}/apps/llm-hub/litellm-helm-release.yaml"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

if [ ! -f "$MANIFEST" ]; then
  bad "manifest not found: $MANIFEST"
  exit 1
fi

# general_settings block only: the model routes must never satisfy these checks.
GENERAL=$(awk '/^      general_settings:/{f=1;next} f && /^      [a-z_]+:/{f=0} f' "$MANIFEST")
if [ -z "$GENERAL" ]; then
  bad "could not find the general_settings block in $MANIFEST"
  exit 1
fi

for pair in \
  "disable_env_credential_login: true|the master-key/UI_USERNAME fallback login is disabled unconditionally" \
  "disable_password_login_when_sso_enabled: true|username/password login is refused while SSO is configured"
do
  needle=${pair%%|*}
  why=${pair#*|}
  if printf '%s\n' "$GENERAL" | grep -qx "[[:space:]]*${needle}"; then
    pass "$needle ($why)"
  else
    bad "general_settings is missing '${needle}' - $why"
  fi
done

# A static credential in the HelmRelease is the same defect wearing a different
# hat: UI_USERNAME/UI_PASSWORD in git would be a shared secret in a public repo.
if grep -qE '^[[:space:]]*-?[[:space:]]*name:[[:space:]]*UI_(USERNAME|PASSWORD)[[:space:]]*$' "$MANIFEST"; then
  bad "UI_USERNAME/UI_PASSWORD are set in the HelmRelease - a static UI credential belongs in no manifest"
else
  pass "no UI_USERNAME/UI_PASSWORD env credential in the HelmRelease"
fi

# The SSO auto-redirect is what makes SSO the only door a human sees.
if grep -qE '^[[:space:]]*value:[[:space:]]*"?true"?[[:space:]]*$' <(grep -A1 'name: AUTO_REDIRECT_UI_LOGIN_TO_SSO' "$MANIFEST"); then
  pass "AUTO_REDIRECT_UI_LOGIN_TO_SSO is true (SSO is the only door the UI shows)"
else
  bad "AUTO_REDIRECT_UI_LOGIN_TO_SSO is not true - a human could be shown a local login form"
fi

if [ "$fail" -ne 0 ]; then
  printf '\nThe Admin UI login path is not SSO-only. See docs/adr/pending/litellm-admin-ui-is-sso-only.md\n'
  exit 1
fi
printf '\nAll LiteLLM Admin UI auth assertions hold.\n'
