#!/usr/bin/env sh
# Git credential helper for github.com.
#
# Supplies the token from the environment so it is never written to disk
# (no ~/.git-credentials, no token embedded in remote URLs).
[ "${1:-}" = "get" ] || exit 0
printf 'username=%s\n' "x-access-token"
printf 'password=%s\n' "${GITHUB_TOKEN:-${GH_TOKEN:-}}"
