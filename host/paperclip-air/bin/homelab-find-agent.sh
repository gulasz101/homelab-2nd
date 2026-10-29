#!/bin/bash
# ---------------------------------------------------------------------------
# homelab-find-agent.sh — locate the LaunchAgent a service used to run under.
#
# The Air's agents were not all named the same way (dev.voitech.homelab.paperclip,
# com.voitech.minio-proxy, ...), and guessing costs a second supervisor. This
# searches by substring on the plist filename, which is how the 2026-10-29
# recovery found them too.
#
# Sourced by homelab-install-daemons.sh. Sourced (not executed) so the caller
# keeps its own shell options.
# ---------------------------------------------------------------------------

# Prints one path per line; empty output means "no agent for this service".
find_agent_plists() { # $1 = service name
  local svc="$1" dir p base
  dir="${HOMELAB_AGENT_DIR:-/Users/paperclip/Library/LaunchAgents}"
  [ -d "$dir" ] || return 0
  for p in "$dir"/*.plist; do
    [ -f "$p" ] || continue
    base=$(printf '%s' "$(basename "$p")" | tr '[:upper:]' '[:lower:]')
    case "$base" in
      *"$svc"*) printf '%s\n' "$p" ;;
    esac
  done
}
