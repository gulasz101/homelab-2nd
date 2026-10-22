#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ADR gate (H2-233, epic H2-232 — ADR-052).
# HAND-RUN ONLY. This file lives under docs/, which is not a kustomize root and
# is not reconciled by Flux, so no kustomization lists it — same ruling as
# apps/hindsight/tests/ and apps/zigbee/tests/. Run it before committing any
# docs/adr change.
#
# What it proves, in order:
#   1. directory consistency: every docs/adr/adr-NNN-*.md agrees with its own
#      filename and has an index row in docs/adr/README.md whose title is
#      byte-equal to the file's H1 text (the house convention for every row).
#   2. ADR-052 carries the six house sections, the epic and tracking-note links,
#      the five rejected alternatives by name, and the concrete revisit triggers.
#   3. the facts ADR-052 states are still true in apps/hindsight/ — a later
#      manifest change fails the DOC gate instead of quietly falsifying the ADR.
#   4. no secret material landed in the ADR (this repo is public).
#
# Two deliberate loosenesses, both measured against the pre-existing tree first:
#   * one direction only — an index row without a file is legitimate. ADR-001..005
#     and ADR-010 live in the vault and are indexed here for history, and ADR-045
#     is reserved by H2-212. Do not "fix" the check into requiring the reverse
#     direction; it would fail on the tree as it stands.
#   * the general row/title check is a shape check, not an equality check. Rows
#     legitimately carry editorial suffixes ("(amends ADR-018)",
#     "(supersedes ADR-026)"), some are shortened, and a couple are paraphrased
#     (ADR-013, ADR-018, ADR-042, ADR-043). A byte-equality rule here would fail
#     14 pre-existing rows and teach everyone to ignore the gate. Drift is still
#     surfaced — as a `note` — and ADR-052's own row IS asserted byte-equal to its
#     H1, because that row is ours to get right.
#
# Usage:  bash docs/adr/tests/adr-check.sh
# Exit:   0 = all checks passed, 1 = at least one check failed
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
ADR_DIR="$ROOT/docs/adr"
INDEX="$ADR_DIR/README.md"
SLUG="adr-052-hindsight-agent-memory-platform.md"
ADR="$ADR_DIR/$SLUG"
HS="$ROOT/apps/hindsight"
TRACKING_NOTE='homelab/tracking/2026-10-12-hindsight-deployment-planning.md'

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
note() { printf '  note  %s\n' "$1"; }
head1() { printf '\n== %s\n' "$1"; }

# Body of one "## <name>" section of an ADR, up to the next heading.
section() {
  awk -v want="$2" '
    $0 == "## " want { f = 1; next }
    f && /^## / { exit }
    f && /^# / { exit }
    f { print }
  ' "$1"
}

# The third table cell (the title) of the index row for ADR-NNN.
row_field() {  # row_field <num> <column: 3=title 4=status 5=date>
  awk -F'|' -v n=" ADR-$1 " -v c="$2" '$2 == n { gsub(/^ +| +$/,"",$c); print $c; exit }' "$INDEX"
}

head1 "0. layout"
[ -d "$ADR_DIR" ] && ok "docs/adr/ exists" || { bad "docs/adr/ missing"; exit 1; }
[ -f "$INDEX" ]   && ok "docs/adr/README.md exists" || { bad "docs/adr/README.md missing"; exit 1; }

head1 "1. every ADR file agrees with its filename and has an index row"
for file in "$ADR_DIR"/adr-*.md; do
  [ -e "$file" ] || continue
  base=$(basename "$file")
  fnum=$(sed -E 's/^adr-([0-9]{3})-.*$/\1/' <<<"$base")
  h1=$(head -1 "$file")
  if [[ "$h1" == "# ADR-$fnum: "* ]]; then
    ok "$base: H1 number matches the filename"
  else
    bad "$base: H1 is '$h1', expected it to start '# ADR-$fnum: '"
    continue
  fi
  h1title=${h1#\# ADR-$fnum: }
  t=$(row_field "$fnum" 3)
  if [ -z "$t" ]; then
    bad "$base: no '| ADR-$fnum | ...' row in docs/adr/README.md"
  else
    ok "$base: has an index row"
    # Drift is reported, not enforced: rows carry editorial suffixes and a few
    # are paraphrased. ADR-052's own title equality is asserted in section 2.
    if [ "$t" != "$h1title" ] && [[ "$h1title" != "$t"* ]]; then
      note "$base: row title is not the H1 text (row: '$t')"
    fi
  fi
  st=$(row_field "$fnum" 4); dt=$(row_field "$fnum" 5)
  [ -n "$st" ] || bad "$base: index row has no status"
  [[ "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    && ok "$base: index row date is $dt" \
    || bad "$base: index row date '$dt' is not YYYY-MM-DD"
done
note "rows without files are allowed on purpose (ADR-001..005/010 live in the vault; 045 is reserved)"

head1 "2. ADR-052 content (H2-233 acceptance criteria)"
if [ ! -f "$ADR" ]; then
  bad "ADR-052 file missing: docs/adr/$SLUG (this is the deliverable of H2-269)"
  printf '\n== result: FAIL (the ADR has not been written yet)\n'
  exit 1
fi
ok "docs/adr/$SLUG exists"

for s in Status Context Decision Consequences "Alternatives considered" "When to revisit"; do
  grep -qxF "## $s" "$ADR" && ok "house section: ## $s" || bad "missing house section: ## $s"
done

# AC 2 — ADR-052's own index row: byte-equality is required here (unlike
# section 1's shape check), because this row is ours to write correctly.
num052=$(sed -E 's/^adr-([0-9]{3})-.*$/\1/' <<<"$SLUG")
adr_h1=$(head -1 "$ADR"); title052=${adr_h1#\# ADR-$num052: }
row052=$(row_field "$num052" 3)
if [ -z "$row052" ]; then
  bad "no '| ADR-$num052 | ...' index row in docs/adr/README.md (deliverable of H2-270)"
elif [ "$row052" = "$title052" ]; then
  ok "index row title is byte-equal to the H1 (AC 2)"
else
  bad "index row title is not byte-equal to the H1 (AC 2)"
  printf '        row : %s\n        h1  : %s\n' "$row052" "$title052"
fi
[ "$(row_field "$num052" 4)" = "Accepted" ] \
  && ok "index row status is Accepted" \
  || bad "index row status is '$(row_field "$num052" 4)', expected Accepted"
[ "$(row_field "$num052" 5)" = "2026-10-13" ] \
  && ok "index row date is 2026-10-13" \
  || bad "index row date is '$(row_field "$num052" 5)', expected 2026-10-13"

# AC 3 — the two links the issue requires.
grep -qF 'H2-232' "$ADR" \
  && ok "names the epic H2-232" \
  || bad "does not name the epic H2-232"
grep -qF "$TRACKING_NOTE" "$ADR" \
  && ok "names the vault tracking note $TRACKING_NOTE" \
  || bad "does not name the tracking note $TRACKING_NOTE"

# The six recorded decisions (issue scope items 1-6) must be recognisable.
for probe in \
  'agent-memory platform' \
  'Honcho' \
  'OpenViking' \
  'postInitApplicationSQL' \
  'nemotron-3-nano-30b-ollama' \
  'scoped' \
  'GTX 970M' \
  'hindsight.voitech.dev' \
  'NodePort' \
  'ApiKeyTenantExtension'
do
  grep -qF "$probe" "$ADR" && ok "records: $probe" || bad "does not record: $probe"
done

# AC 4 — the five alternatives, named inside the Alternatives section.
alts=$(section "$ADR" "Alternatives considered")
for probe in 'Hindsight Cloud' 'full image' 'bundled Postgres' 'publicly' 'GPU TEI'; do
  grep -qF "$probe" <<<"$alts" \
    && ok "alternative argued in the Alternatives section: $probe" \
    || bad "alternative not argued in the Alternatives section: $probe"
done

# AC 5 — concrete revisit triggers.
rev=$(section "$ADR" "When to revisit")
for probe in 'CUDA' 'recall' 'CNPG'; do
  grep -qF "$probe" <<<"$rev" \
    && ok "revisit trigger present: $probe" \
    || bad "revisit trigger missing from the When to revisit section: $probe"
done

head1 "3. the facts ADR-052 states are still true in apps/hindsight/"
[ -d "$HS" ] || bad "apps/hindsight/ is missing - the ADR cites it"
check_fact() {  # check_fact <file> <literal> <label>
  if [ -f "$1" ] && grep -qF -- "$2" "$1"; then
    ok "$3"
  else
    bad "$3 (expected '$2' in $(basename "$1"))"
  fi
}
check_fact "$HS/hindsight-helm-release.yaml" 'version: "0.10.3"' "chart pinned 0.10.3 (not a range)"
check_fact "$HS/hindsight-helm-release.yaml" 'nemotron-3-nano-30b-ollama' "LLM model route is the LiteLLM one"
check_fact "$HS/hindsight-helm-release.yaml" 'HINDSIGHT_API_LLM_PROVIDER' "LLM provider is set explicitly"
check_fact "$HS/hindsight-helm-release.yaml" 'hindsight-db-rw.hindsight.svc.cluster.local' "chart points at the CNPG service"
check_fact "$HS/hindsight-db-postgres-cluster.yaml" 'CREATE EXTENSION IF NOT EXISTS vector;' "pgvector is created at bootstrap"
check_fact "$HS/hindsight-db-objectstore.yaml" 's3://cnpg-backups/hindsight' "backups go to the OMV MinIO bucket"
check_fact "$HS/hindsight-db-objectstore.yaml" 'retentionPolicy: "30d"' "backup retention is 30d"
check_fact "$HS/hindsight-db-postgres-cluster.yaml" 'barman-cloud.cloudnative-pg.io' "the cluster backs up through the barman-cloud plugin (ADR-081)"
check_fact "$HS/hindsight-service.yaml" 'nodePort: 30239' "API exposes NodePort 30239"
check_fact "$HS/hindsight-service.yaml" 'nodePort: 30240' "Control Plane exposes NodePort 30240"

head1 "4. no secret material in the ADR (this repo is public)"
if grep -qE 'ENC\[AES256_GCM' "$ADR"; then
  bad "the ADR carries SOPS ciphertext - it must reference secrets, never contain them"
else
  ok "no SOPS ciphertext in the ADR"
fi
WORK=$(mktemp); trap 'rm -f "$WORK"' EXIT
if grep -nE '^[^|]*(password|passwd|token|api[_-]?key|secret)[[:space:]]*:[[:space:]]+[^[:space:]<$]' "$ADR" > "$WORK"; then
  bad "possible plaintext credential line(s) in the ADR:"; sed 's/^/        /' "$WORK"
else
  ok "no plaintext credential assignment in the ADR"
fi

printf '\n== result: %s\n' "$([ "$fail" -eq 0 ] && echo PASS || echo FAIL)"
exit "$fail"
