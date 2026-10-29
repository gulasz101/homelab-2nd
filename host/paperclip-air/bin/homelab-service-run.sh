#!/bin/sh
# ---------------------------------------------------------------------------
# homelab-service-run.sh <service> — the exec wrapper every root LaunchDaemon
# in this tree calls (ADR-098).
#
# Why a wrapper instead of the command directly in the plist: the command is
# host state (installed paths, homebrew versions, env), not repo state. The
# installer derives it once from the LaunchAgent that used to run the service
# and stores it in /Users/paperclip/.config/homelab/services.env (0600). So the
# repo owns *supervision*, the host owns *the command*, and neither guesses.
#
# Installed at /usr/local/libexec/homelab/homelab-service-run.sh (root:wheel
# 0755). Runs as the appliance user because the plist sets UserName.
# ---------------------------------------------------------------------------
set -eu

SVC="${1:-}"
SERVICES_ENV="/Users/paperclip/.config/homelab/services.env"

if [ -z "$SVC" ]; then
  echo "usage: homelab-service-run.sh <service>" >&2
  exit 64
fi

if [ ! -r "$SERVICES_ENV" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') FATAL: $SERVICES_ENV is missing or unreadable." >&2
  echo "  Run host/paperclip-air/bin/homelab-install-daemons.sh, or write the file by hand." >&2
  echo "  launchd will keep retrying (KeepAlive) and throttle this job until it works." >&2
  exit 78
fi

# shellcheck disable=SC1090
. "$SERVICES_ENV"

VAR=$(printf 'SVC_%s_CMD' "$(printf '%s' "$SVC" | tr '-' '_' | tr '[:lower:]' '[:upper:]')")
eval "CMD=\${$VAR:-}"

if [ -z "${CMD:-}" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') FATAL: $VAR is empty in $SERVICES_ENV" >&2
  exit 78
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') starting $SVC: $CMD"
# exec twice on purpose: the inner sh expands the command line (cd, env prefixes,
# && chains) and the outer exec hands the pid to launchd, so KeepAlive watches
# the real process and not a shell that forked it.
exec /bin/sh -c "exec $CMD"
