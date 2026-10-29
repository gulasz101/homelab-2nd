#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUL-552: self-test for scripts/helmrelease-pin-vs-cluster.sh.
#
# Runs offline: every case is a throwaway git repo in a mktemp dir plus a
# kubectl stub first on PATH. No cluster, no network - so this runs in CI
# (scripts/check.sh discovers it) as well as on the Air.
#
#   pin below deployed      -> FAIL (exit 1)
#   pin equal deployed      -> PASS (exit 0)
#   pin above deployed      -> PASS (exit 0)
#   new HelmRelease         -> PASS with a NOTE (not in the cluster)
#   chart from GitRepository-> PASS with a NOTE (no semver to compare)
#   prerelease vs release   -> 1.2.3-rc.1 below 1.2.3 -> FAIL
#   no metadata.namespace   -> resolved from the cluster index
#   kubectl unreachable     -> exit 2, never a PASS
#   the GUL-479 replay      -> open-webui 17.0.0 vs deployed 17.3.0 -> FAIL
#
# bash 3.2-safe (macOS on the Air, bash 4 on ubuntu-latest): no assoc arrays.
#
# Usage: bash scripts/tests/helmrelease-pin-vs-cluster-check.sh
# Exit:  0 = every case behaves, 1 = at least one case is wrong
# ---------------------------------------------------------------------------
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/scripts/helmrelease-pin-vs-cluster.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pin-vs-cluster-XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS_N=0
FAIL_N=0
ok()  { printf '  ok   %s\n' "$1"; PASS_N=$((PASS_N + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL_N=$((FAIL_N + 1)); }

[ -f "$SCRIPT" ] || { printf 'FAIL: %s does not exist\n' "$SCRIPT"; exit 1; }

# ---- kubectl stub ----------------------------------------------------------
STUB="$TMP/bin"
mkdir -p "$STUB"
cat > "$STUB/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
# Stub kubectl for helmrelease-pin-vs-cluster-check.
#   $KUBE_STUB_DIR/hrs   one "namespace|name|chartVersion" per line
#   $KUBE_STUB_DIR/down  when it exists the cluster is unreachable
if [ -f "$KUBE_STUB_DIR/down" ]; then
  echo 'The connection to the server 192.168.1.179:6443 was refused - did you specify the right host or port?' >&2
  exit 1
fi
case "$*" in
  *" -A "*|*" -A")
    awk -F'|' 'NF >= 2 { print $1 "|" $2 }' "$KUBE_STUB_DIR/hrs"
    exit 0 ;;
esac
# kubectl get hr -n <ns> <name> -o jsonpath=...
ns=$4
name=$5
v=$(awk -F'|' -v n="$name" -v s="$ns" '$2 == n && $1 == s { print $3; exit }' "$KUBE_STUB_DIR/hrs")
if [ -z "$v" ]; then
  echo "Error from server (NotFound): helmreleases.helm.toolkit.fluxcd.io \"$name\" not found" >&2
  exit 1
fi
printf '%s' "$v"
STUBEOF
chmod +x "$STUB/kubectl"
export PATH="$STUB:$PATH"
export KUBE_STUB_DIR="$TMP/kube"
mkdir -p "$KUBE_STUB_DIR"

set_hrs() { # lines of "ns|name|version" (empty argument clears)
  : > "$KUBE_STUB_DIR/hrs"
  [ -n "${1:-}" ] && printf '%s\n' "$1" > "$KUBE_STUB_DIR/hrs"
  return 0
}

# ---- fixture repo ----------------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO/scripts"
cp "$SCRIPT" "$REPO/scripts/helmrelease-pin-vs-cluster.sh"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name "pin test"

hr_file() { # path name namespace version [extra-source]
  local p="$REPO/$1" name=$2 ns=$3 version=$4 source=${5:-}
  mkdir -p "$(dirname "$p")"
  {
    printf 'apiVersion: helm.toolkit.fluxcd.io/v2\nkind: HelmRelease\nmetadata:\n  name: %s\n' "$name"
    [ -n "$ns" ] && printf '  namespace: %s\n' "$ns"
    printf 'spec:\n'
    if [ "$source" = "git" ]; then
      printf '  chartRef:\n    kind: GitRepository\n    name: %s-source\n' "$name"
    else
      printf '  chart:\n    spec:\n      chart: %s\n      version: "%s"\n      sourceRef:\n        kind: HelmRepository\n        name: %s\n' \
        "$name" "$version" "$name"
    fi
    printf '  interval: 1h\n'
  } > "$p"
}

commit() { # message -> prints the new sha
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "$1"
  git -C "$REPO" rev-parse HEAD
}

hr_file apps/llm-hub/openwebui-helm-release.yaml open-webui llm-hub 17.3.0
BASE=$(commit base)

LAST_OUT="$TMP/out"
LAST_ERR="$TMP/err"
run() { # base head - runs the script from inside the fixture repo
  ( cd "$REPO" && bash scripts/helmrelease-pin-vs-cluster.sh "$1" "$2" ) \
    > "$LAST_OUT" 2> "$LAST_ERR"
  LAST_RC=$?
}

expect() { # name want_rc [stdout-grep]
  local name=$1 want=$2 pat=${3:-}
  if [ "$LAST_RC" != "$want" ]; then
    bad "$name (want rc=$want got $LAST_RC)"
    sed 's/^/       /' "$LAST_OUT" "$LAST_ERR" >&2
    return
  fi
  if [ -n "$pat" ] && ! grep -q -- "$pat" "$LAST_OUT"; then
    bad "$name (rc ok, but stdout lacks '$pat')"
    sed 's/^/       /' "$LAST_OUT" >&2
    return
  fi
  ok "$name (rc=$LAST_RC)"
}

echo "== semver: pin vs deployed =="

set_hrs "llm-hub|open-webui|17.3.0"

hr_file apps/llm-hub/openwebui-helm-release.yaml open-webui llm-hub 17.0.0
C=$(commit lower)
run "$BASE" "$C"
expect "pin below deployed -> FAIL" 1 "FAIL apps/llm-hub/openwebui-helm-release.yaml"
grep -q 'RESULT: FAIL' "$LAST_OUT" && ok "lower pin prints RESULT: FAIL" || bad "lower pin RESULT line"

hr_file apps/llm-hub/openwebui-helm-release.yaml open-webui llm-hub 17.3.0
# the file has to change for the diff to include it; the pin stays the same
printf '# re-stated, no version change\n' >> "$REPO/apps/llm-hub/openwebui-helm-release.yaml"
C=$(commit equal)
run "$BASE" "$C"
expect "pin equal deployed -> PASS" 0 "PASS apps/llm-hub/openwebui-helm-release.yaml"

hr_file apps/llm-hub/openwebui-helm-release.yaml open-webui llm-hub 18.0.0
C=$(commit higher)
run "$BASE" "$C"
expect "pin above deployed -> PASS" 0 "PASS apps/llm-hub/openwebui-helm-release.yaml"
set_hrs "llm-hub|open-webui|17.3.0"

echo "== semver: prerelease sorts below the release =="

hr_file apps/demo/pre-helm-release.yaml demo-app demo 1.2.3-rc.1
C=$(commit prerelease)
set_hrs "demo|demo-app|1.2.3"
run "$C^" "$C"
expect "1.2.3-rc.1 below deployed 1.2.3 -> FAIL" 1 "FAIL apps/demo/pre-helm-release.yaml"
set_hrs "demo|demo-app|1.2.3-rc.1"
run "$C^" "$C"
expect "prerelease equal deployed prerelease -> PASS" 0 "PASS apps/demo/pre-helm-release.yaml"
set_hrs "demo|demo-app|1.2.3-rc.2"
run "$C^" "$C"
expect "older prerelease below newer prerelease -> FAIL" 1 "FAIL apps/demo/pre-helm-release.yaml"

echo "== not comparable: new release, GitRepository chart =="

set_hrs "llm-hub|open-webui|17.3.0"
hr_file apps/brand-new/brand-new-helm-release.yaml brand-new brand-new 0.1.0
C=$(commit new-release)
run "$C^" "$C"
expect "new HelmRelease not in the cluster -> PASS" 0 "NOTE apps/brand-new/brand-new-helm-release.yaml"
grep -q 'not in the cluster yet' "$LAST_OUT" && ok "new release note names the reason" || bad "new release note text"

hr_file apps/gitrepo/app-helm-release.yaml gitrepo-app gitrepo "" git
C=$(commit gitrepo-chart)
run "$C^" "$C"
expect "chartRef GitRepository (no semver) -> PASS" 0 "NOTE apps/gitrepo/app-helm-release.yaml"
grep -q 'no spec.chart.spec.version' "$LAST_OUT" && ok "gitrepo note names the reason" || bad "gitrepo note text"

echo "== namespace resolution and cluster reachability =="

hr_file apps/zonk/zonk-helm-release.yaml zonk-app "" 1.0.0
C=$(commit no-namespace)
set_hrs "zonk|zonk-app|2.0.0"
run "$C^" "$C"
expect "missing metadata.namespace resolved from the cluster -> FAIL" 1 "FAIL apps/zonk/zonk-helm-release.yaml"
grep -q '(zonk)' "$LAST_OUT" && ok "resolved namespace printed" || bad "resolved namespace missing"

: > "$KUBE_STUB_DIR/down"
run "$C^" "$C"
expect "kubectl unreachable -> exit 2" 2
grep -q 'cannot reach the cluster' "$LAST_ERR" && ok "unreachable cluster names the reason" || bad "unreachable cluster message"
grep -q 'RESULT: PASS' "$LAST_OUT" && bad "unreachable cluster must never print a PASS" || ok "unreachable cluster never prints PASS"
rm -f "$KUBE_STUB_DIR/down"

echo "== usage =="
( cd "$REPO" && bash scripts/helmrelease-pin-vs-cluster.sh "$BASE" ) > "$LAST_OUT" 2> "$LAST_ERR"
LAST_RC=$?
expect "one argument -> exit 2" 2
( cd "$REPO" && bash scripts/helmrelease-pin-vs-cluster.sh "$BASE" refs/heads/does-not-exist ) \
  > "$LAST_OUT" 2> "$LAST_ERR"
LAST_RC=$?
expect "unknown ref -> exit 2" 2

echo "== GUL-479 replay: open-webui 17.0.0 against a cluster running 17.3.0 =="

# The real diff, when the history is here (CI checks out fetch-depth 0 and the
# Air has the full clone). f09586c is work order 1's green commit: it pinned
# open-webui from ">=0.5.0" to "17.0.0" while 17.3.0 was deployed.
REPLAY_BASE=""
REPLAY_HEAD=""
if git -C "$ROOT" rev-parse --verify --quiet f09586c^{commit} >/dev/null 2>&1; then
  REPLAY_BASE="f09586c^"
  REPLAY_HEAD="f09586c"
  printf '  ..   replaying the real GUL-479 commit f09586c from %s\n' "$ROOT"
else
  hr_file apps/llm-hub/openwebui-helm-release.yaml open-webui llm-hub 17.0.0
  REPLAY_HEAD=$(commit gul-479-replay)
  REPLAY_BASE="$REPLAY_HEAD^"
  printf '  ..   history not available, replaying the same one-line diff in the fixture\n'
fi

set_hrs "llm-hub|open-webui|17.3.0
cnpg-system|cloudnative-pg|0.29.1
observability|opentelemetry-collector|0.178.0
observability|prometheus-stack|92.14.1"
( cd "$ROOT" && bash scripts/helmrelease-pin-vs-cluster.sh "$REPLAY_BASE" "$REPLAY_HEAD" ) \
  > "$LAST_OUT" 2> "$LAST_ERR"
LAST_RC=$?
if [ "$LAST_RC" = 1 ] && grep -q 'FAIL apps/llm-hub/openwebui-helm-release.yaml' "$LAST_OUT"; then
  ok "GUL-479 replay fails on the open-webui downgrade (rc=1)"
else
  bad "GUL-479 replay should FAIL on open-webui (rc=$LAST_RC)"
  sed 's/^/       /' "$LAST_OUT" "$LAST_ERR" >&2
fi
if [ "$LAST_RC" = 1 ] && grep -q 'pins 17.0.0 but the cluster runs 17.3.0' "$LAST_OUT"; then
  ok "replay names both versions"
else
  bad "replay does not name 17.0.0 vs 17.3.0"
fi
# The three releases the same commit pinned to what was running stay green.
grep -c '^PASS ' "$LAST_OUT" | grep -q '^3$' \
  && ok "the other three pins in that commit pass" \
  || bad "expected 3 PASS lines for the other pins"

echo
printf 'helmrelease-pin-vs-cluster-check: %d passed, %d failed\n' "$PASS_N" "$FAIL_N"
[ "$FAIL_N" -eq 0 ] && exit 0 || exit 1
