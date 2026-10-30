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

# A plain substring search gets this wrong in both directions on a real host:
# "hermes-gateway" is NOT a substring of "ai.hermes.gateway.plist" (so the
# gateway agent was never found and its daemon was never installed), and
# "paperclip" IS a substring of "io.paperclip.minio-proxy.plist" (so the
# paperclip iteration retired the MinIO proxy's agent as a side effect).
# Explicit map first, substring search only as the fallback for a host we have
# not seen.
#
# Prints one path per line; empty output means "no agent for this service".
find_agent_plists() { # $1 = service name
  local svc="$1" dir p base names found=0
  dir="${HOMELAB_AGENT_DIR:-/Users/paperclip/Library/LaunchAgents}"
  [ -d "$dir" ] || return 0
  case "$svc" in
    hermes-gateway)  names="ai.hermes.gateway.plist dev.voitech.homelab.hermes-gateway.plist" ;;
    paperclip)       names="io.paperclip.server.plist dev.voitech.homelab.paperclip.plist" ;;
    minio-lan-proxy) names="io.paperclip.minio-proxy.plist com.voitech.minio-proxy.plist dev.voitech.homelab.minio-lan-proxy.plist" ;;
    gemini-tunnel)   names="ai.hermes.gemini-tunnel.plist dev.voitech.homelab.gemini-tunnel.plist" ;;
    syncthing)       names="sh.brew.syncthing.plist dev.voitech.homelab.syncthing.plist" ;;
    *)               names="" ;;
  esac
  for base in $names; do
    [ -f "$dir/$base" ] && { printf '%s\n' "$dir/$base"; found=1; }
  done
  [ "$found" -eq 1 ] && return 0
  for p in "$dir"/*.plist; do
    [ -f "$p" ] || continue
    base=$(printf '%s' "$(basename "$p")" | tr '[:upper:]' '[:lower:]')
    case "$base" in
      *"$svc"*) printf '%s\n' "$p" ;;
    esac
  done
}
