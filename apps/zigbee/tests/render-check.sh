#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# H2-214 validation gate for the zigbee namespace. HAND-RUN ONLY - this file is
# deliberately NOT listed in apps/zigbee/kustomization.yaml, so Flux never
# reconciles it (same ruling as apps/mail-archiver/drill/).
#
# What it proves, in order:
#   1. the group renders at all  -> kubectl kustomize apps/zigbee
#   2. the whole apps tree still renders with the group wired in
#   3. every rendered object validates -> kubeconform -strict (core schemas +
#      the datreeio CRDs catalog for HelmRelease / PrometheusRule /
#      ServiceMonitor / AlertmanagerConfig)
#   4. every HelmRelease's chart values actually render -> helm template, and
#      the chart-rendered objects validate too
#   5. the properties this ticket's acceptance criteria name are really there:
#      pinned image tags (no :latest), the z2m radio-head triple
#      (nodeSelector + serial-by-id hostPath + PVC), no plaintext Secret
#      anywhere in the group, observability wiring for every workload
#   6. every manifest file on disk is wired into the kustomization (the classic
#      "wrote the file, forgot the wiring" bug)
#
# Usage:  bash apps/zigbee/tests/render-check.sh
# Exit:   0 = all checks passed, 1 = at least one check failed
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DIR="$ROOT/apps/zigbee"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

K8S_VERSION=1.31.0
CRD_SCHEMA='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# -skip Secret: this repo's Secrets are SOPS-encrypted and carry a `sops:`
# metadata block that the strict Secret schema rejects. That is a known,
# intentional shape, so Secrets are skipped here and checked directly instead:
# section 5b asserts every Secret in the group is SOPS-encrypted and has no
# plaintext payload.
KUBECONFORM=(kubeconform -strict -summary -kubernetes-version "$K8S_VERSION"
  -skip Secret
  -schema-location default -schema-location "$CRD_SCHEMA")

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
note() { printf '  note  %s\n' "$1"; }
head1() { printf '\n== %s\n' "$1"; }

# Chart sources for the HelmRelease objects. Kept here so the check is
# self-contained; the assertion below makes sure they still match
# apps/zigbee/helm-repositories.yaml, so the table cannot silently drift.
declare -A CHART_REPO=(
  [zigbee2mqtt]="https://charts.zigbee2mqtt.io"
  [node-red]="https://schwarzit.github.io/node-red-chart"
  [influxdb2]="https://helm.influxdata.com"
)

# Pull the `values:` block out of a HelmRelease and dedent it by 4 spaces.
extract_values() {
  awk '
    /^  values:/ { invalues = 1; next }
    invalues {
      if ($0 ~ /^[^ ]/ || $0 ~ /^  [^ ]/) exit
      sub(/^    /, ""); print
    }
  ' "$1"
}

# Read one scalar out of a HelmRelease (chart name / chart version).
extract_chart_field() {
  awk -v key="$2" '
    /^  chart:/ { inchart = 1; next }
    inchart && /^  [^ ]/ { exit }
    inchart && $1 == key":" { gsub(/"/, "", $2); print $2; exit }
  ' "$1"
}

head1 "0. layout"
[ -d "$DIR" ] || { bad "apps/zigbee/ does not exist"; exit 1; }
[ -f "$DIR/kustomization.yaml" ] && ok "apps/zigbee/kustomization.yaml exists" || bad "apps/zigbee/kustomization.yaml missing"
grep -q '^  - zigbee/$' "$ROOT/apps/kustomization.yaml" \
  && ok "apps/kustomization.yaml wires the zigbee group" \
  || bad "apps/kustomization.yaml does not reference zigbee/"

head1 "1. render the group"
if kubectl kustomize "$DIR" > "$WORK/zigbee.yaml" 2> "$WORK/kustomize.err"; then
  ok "kubectl kustomize apps/zigbee -> $(grep -c '^kind:' "$WORK/zigbee.yaml") objects"
else
  bad "kubectl kustomize apps/zigbee failed:"; sed 's/^/        /' "$WORK/kustomize.err"; exit 1
fi

head1 "2. render the whole apps tree (wiring regression check)"
if kubectl kustomize "$ROOT/apps" > "$WORK/apps.yaml" 2> "$WORK/apps.err"; then
  ok "kubectl kustomize apps -> $(grep -c '^kind:' "$WORK/apps.yaml") objects"
else
  bad "kubectl kustomize apps failed:"; sed 's/^/        /' "$WORK/apps.err"
fi

head1 "3. kubeconform -strict on the group render"
if "${KUBECONFORM[@]}" "$WORK/zigbee.yaml" > "$WORK/kc.txt" 2>&1; then
  ok "$(tail -1 "$WORK/kc.txt")"
else
  bad "kubeconform rejected the group render:"
  grep -v '^Summary:' "$WORK/kc.txt" | sed 's/^/        /'
fi

head1 "4. helm template every HelmRelease (chart values must really render)"
releases=$(grep -c '^kind: HelmRelease' "$WORK/zigbee.yaml")
[ "$releases" -eq 3 ] && ok "3 HelmReleases rendered" || bad "expected 3 HelmReleases, found $releases"
for f in "$DIR"/*helm-release.yaml; do
  [ -e "$f" ] || { bad "no *helm-release.yaml files found"; break; }
  rel=$(basename "$f" | sed 's/-helm-release.yaml$//')
  chart=$(extract_chart_field "$f" chart)
  version=$(extract_chart_field "$f" version)
  url=${CHART_REPO[$chart]:-}
  [ -n "$chart" ] && [ -n "$version" ] || { bad "$(basename "$f"): chart/version not parsed"; continue; }
  [ -n "$url" ] || { bad "$(basename "$f"): no chart repo known for chart '$chart'"; continue; }
  grep -q "$url" "$DIR/helm-repositories.yaml" \
    && ok "$rel: repo $url matches helm-repositories.yaml" \
    || bad "$rel: repo $url is not declared in helm-repositories.yaml"
  extract_values "$f" > "$WORK/$rel.values.yaml"
  if helm template "$rel" "$chart" --repo "$url" --version "$version" \
       --namespace zigbee -f "$WORK/$rel.values.yaml" > "$WORK/$rel.yaml" 2> "$WORK/$rel.err"; then
    ok "$rel: helm template $chart-$version -> $(grep -c '^kind:' "$WORK/$rel.yaml") objects"
  else
    bad "$rel: helm template failed:"; sed 's/^/        /' "$WORK/$rel.err"
    continue
  fi
  if "${KUBECONFORM[@]}" "$WORK/$rel.yaml" > "$WORK/$rel.kc.txt" 2>&1; then
    ok "$rel: kubeconform $(tail -1 "$WORK/$rel.kc.txt")"
  else
    # One documented, narrow exception. The upstream zigbee2mqtt chart never
    # sets StatefulSet.spec.serviceName. The published JSON schema marks that
    # field required, but the API server does not - see
    # k8s.io/kubernetes/pkg/apis/apps/validation: it only validates serviceName
    # when it is non-empty. A one-replica StatefulSet behind a normal ClusterIP
    # Service does not need per-pod DNS, so this is accepted - but ONLY if it is
    # the single complaint. Anything else is a real failure.
    # 2026-10-13: accept the SINGULAR 'missing property' too. This exception was
    # written against a kubeconform that said `missing properties: 'serviceName'`;
    # the installed one emits `missing property 'serviceName'`. Same single
    # complaint, different wording across validator versions - the guard had
    # silently stopped matching and was reporting a known-accepted upstream bug
    # as a hard failure. Match either spelling rather than exactly one.
    if [ "$rel" = "zigbee2mqtt" ] \
       && [ "$(grep -c ' is invalid:' "$WORK/$rel.kc.txt")" -eq 1 ] \
       && grep -qE "missing propert(y|ies):? 'serviceName'" "$WORK/$rel.kc.txt"; then
      note "$rel: kubeconform's only complaint is the upstream chart's absent StatefulSet.serviceName (schema requires it, the API server does not) - accepted"
    else
      bad "$rel: kubeconform rejected the chart render:"
      grep -v '^Summary:' "$WORK/$rel.kc.txt" | sed 's/^/        /'
    fi
  fi
done

head1 "5. acceptance-criteria properties"
R="$WORK/zigbee.yaml"

grep -q '^kind: Namespace' "$R" && grep -q '^  name: zigbee$' "$R" \
  && ok "namespace zigbee is declared" || bad "namespace zigbee is not declared"

# 5a. pinned image tags: no :latest and no empty image tag anywhere.
if grep -nE 'image:.*:latest|tag: *"?latest"? *$|tag: *""' "$R" > "$WORK/latest.txt"; then
  bad "unpinned image found:"; sed 's/^/        /' "$WORK/latest.txt"
else
  ok "no :latest / empty image tag in the group render"
fi
# chart versions must be exact (no ranges) so the app versions cannot drift.
if grep -nE '^ *version: *"?[><=~^]' "$R" > "$WORK/ranges.txt"; then
  bad "chart version range found (app version would drift):"; sed 's/^/        /' "$WORK/ranges.txt"
else
  ok "all chart versions are exact pins"
fi

# 5b. every Secret in the group must be SOPS-encrypted, with no plaintext
#     payload. (kubeconform skips Secret; this is the check that replaces it.)
if grep -q '^kind: Secret' "$R"; then
  secrets=$(grep -c '^kind: Secret' "$R")
  sops_secrets=$(grep -c '^sops:' "$R")
  if [ "$secrets" -eq "$sops_secrets" ] && ! grep -qE '^(data|stringData): *[^ ]' "$R"; then
    ok "all $secrets Secret(s) in the group are SOPS-encrypted with no plaintext payload"
  else
    bad "the group has a Secret that is not SOPS-encrypted ($secrets Secret docs, $sops_secrets sops blocks)"
  fi
else
  ok "no Secret objects in the group (all referenced by name only)"
fi

# 5c. the z2m radio-head triple.
Z="$WORK/zigbee2mqtt.yaml"
if [ -f "$Z" ]; then
  grep -q 'kubernetes.io/hostname: zigbee-node' "$Z" \
    && ok "z2m nodeSelector pins the radio head (zigbee-node)" \
    || bad "z2m nodeSelector is missing"
  grep -q '/dev/serial/by-id/usb-Itead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_V2_.*-if00-port0' "$Z" \
    && ok "z2m hostPath uses the serial-by-id dongle path" \
    || bad "z2m hostPath does not use the serial-by-id dongle path"
  grep -q 'type: CharDevice' "$Z" \
    && ok "z2m dongle hostPath is typed CharDevice (kubelet verifies the device instead of mounting an empty dir)" \
    || bad "z2m dongle hostPath has no type - a missing dongle would silently become an empty directory"
  grep -q 'mountPath: /dev/ttyUSB0' "$Z" \
    && ok "z2m dongle is mounted at /dev/ttyUSB0 (the path in the migrated config)" \
    || bad "z2m dongle is not mounted at /dev/ttyUSB0"
  grep -q 'mountPath: /run/udev' "$Z" \
    && ok "z2m has /run/udev (adapter enumeration info, as the source compose did)" \
    || bad "z2m is missing the /run/udev mount"
  # The gate must really be wired into the container command, not just present
  # as a ConfigMap (helm merges a list over the chart's `command: {}` default).
  grep -q 'sh /config/preflight.sh' "$Z" \
    && ok "z2m container command runs the preflight gate before the bridge" \
    || bad "z2m preflight gate is not wired into the container command"
  # State lives on the radio head's local-path volume (H2-210's decision, see
  # ADR-046). The chart derives the PVC name from the StatefulSet name.
  grep -q '^  name: zigbee2mqtt$' "$Z" && grep -q '^      name: data-volume$' "$Z" \
    && grep -q 'storageClassName: local-path' "$Z" \
    && ok "z2m StatefulSet uses a local-path volumeClaimTemplate (PVC data-volume-zigbee2mqtt-0)" \
    || bad "z2m storage is not the expected local-path volumeClaimTemplate"
  grep -q '^kind: ConfigMap' "$Z" \
    && ok "z2m chart renders its config ConfigMap (config-as-code; the network key arrives via valuesFrom at runtime)" \
    || bad "z2m chart rendered no ConfigMap - the config-as-code values are not reaching the bridge"
else
  bad "zigbee2mqtt did not render"
fi

# 5d. static storage: the NFS PVs must carry storageClassName "" and bind by name.
for pair in "node-red-data-pv.yaml:node-red-data:node-red-data-pvc.yaml:node-red-data"; do
  IFS=: read -r pvfile pvname pvcfile pvcname <<< "$pair"
  pv="$DIR/$pvfile"; pvc="$DIR/$pvcfile"
  [ -f "$pv" ] || { bad "$pvfile missing"; continue; }
  [ -f "$pvc" ] || { bad "$pvcfile missing"; continue; }
  grep -q '^  storageClassName: ""$' "$pv" && grep -q "openmediavault.local" "$pv" \
    && grep -q '^  persistentVolumeReclaimPolicy: Retain$' "$pv" \
    && ok "$pvname: OMV NFS PV with storageClassName \"\" and Retain" \
    || bad "$pvname: PV is not a static OMV NFS volume with Retain"
  grep -q '^  storageClassName: ""$' "$pvc" && grep -q "^  volumeName: $pvname$" "$pvc" \
    && ok "$pvcname: bound by name to $pvname" \
    || bad "$pvcname: not bound by name to $pvname"
done

# 5e. observability wiring (guardrail 9).
grep -q '^kind: PrometheusRule' "$R" && ok "PrometheusRule present" || bad "no PrometheusRule"
grep -q '^kind: ServiceMonitor' "$R" && ok "ServiceMonitor present (InfluxDB /metrics)" || bad "no ServiceMonitor"
grep -q '^kind: AlertmanagerConfig' "$R" && ok "AlertmanagerConfig present" || bad "no AlertmanagerConfig"
grep -q 'loki_rule: "true"' "$R" && ok "Loki ruler rule present" || bad "no Loki ruler rule"
grep -q 'grafana_dashboard: "1"' "$R" && ok "Grafana dashboard ConfigMap present" || bad "no Grafana dashboard ConfigMap"

# 5f. no obvious plaintext secret material in the group.
if grep -rnE '(password|passwd|token|api[_-]?key|network_key|secret): *[^ ]' "$DIR" \
     --include='*.yaml' --exclude='tests/*' > "$WORK/plaintext.txt"; then
  # Secret *names* and secretKeyRef/secretRef references are fine; values are not.
  # 2026-10-13: added the ENC[...] exclusion. The check was firing on every
  # SOPS-encrypted value in the group (`admin-password: ENC[AES256_GCM,...]`),
  # i.e. reporting correctly-encrypted ciphertext as plaintext leakage. That is
  # both a false alarm and dangerous: a gate that always cries wolf gets
  # ignored, and then a REAL leak slips through unnoticed. An `ENC[` marker
  # means sops got to it, which is exactly what we want.
  if grep -vE 'secretName|name:|secretKeyRef|key:|secretRef|(PASSWORD|TOKEN|KEY)_|existingSecret|password_file|credentialSecret|network_key.*(never|must not)|token.*(H2-215|owned)|ENC\[' "$WORK/plaintext.txt" > "$WORK/plaintext-real.txt"; then
    if [ -s "$WORK/plaintext-real.txt" ]; then
      bad "possible plaintext secret material:"; sed 's/^/        /' "$WORK/plaintext-real.txt"
    else
      ok "no plaintext secret values in the group"
    fi
  else
    ok "no plaintext secret values in the group"
  fi
else
  ok "no plaintext secret values in the group"
fi

# 5g. per-workload properties on the chart renders.
N="$WORK/node-red.yaml"
if [ -f "$N" ]; then
  grep -q 'image: "docker.io/nodered/node-red:4.1.16-22"' "$N" \
    && ok "node-red image pinned to 4.1.16-22 (4.1 line, not the 5.x jump)" \
    || bad "node-red image is not the pinned 4.1.16-22"
  grep -q 'claimName: node-red-data' "$N" && grep -q 'mountPath: /data' "$N" \
    && ok "node-red mounts the OMV NFS claim at /data" \
    || bad "node-red does not mount node-red-data at /data"
  # 2026-10-13: this used to assert "no LAN exposure of the flow editor". That
  # is now deliberately false - node-red-lan-service.yaml publishes NodePort
  # 30180 at Supreme Leader's request. The cluster-internal Service rendered by
  # the chart MUST stay ClusterIP (that is what mosquitto/node-red DNS inside
  # the namespace resolve to, and what a LAN client should NOT be able to reach
  # once the NodePort is the reviewed front door); the LAN exposure is asserted
  # separately below against node-red-lan-service.yaml.
  grep -q 'type: ClusterIP' "$N" \
    && ok "node-red chart Service is ClusterIP (in-clusterDNS path unchanged)" \
    || bad "node-red chart Service is not ClusterIP"
  # The LAN door must exist, be a NodePort, and carry purpose-written docs.
  L="$ROOT/apps/zigbee/node-red-lan-service.yaml"
  if [ -f "$L" ]; then
    grep -q 'type: NodePort' "$L" \
      && ok "node-red editor is exposed on the LAN via a dedicated NodePort Service" \
      || bad "node-red-lan-service.yaml exists but is not a NodePort"
    grep -q 'nodePort: 30180' "$L" \
      && ok "node-red LAN port is 30180 (outside the used NodePort set)" \
      || bad "node-red LAN nodePort has drifted from 30180"
  else
    bad "node-red LAN access is expected (apps/zigbee/node-red-lan-service.yaml missing)"
  fi
  # Same deal for MQTT: Tasmota devices need the broker on the LAN.
  M="$ROOT/apps/zigbee/mosquitto-lan-service.yaml"
  if [ -f "$M" ]; then
    grep -q 'type: NodePort' "$M" && grep -q 'nodePort: 30188' "$M" \
      && ok "mosquitto is exposed on the LAN via NodePort 30188 with its own Service" \
      || bad "mosquitto-lan-service.yaml is missing or has drifted from nodePort 30188"
  else
    bad "mosquitto-lan-service.yaml missing - Tasmota devices cannot reach the broker"
  fi
  # The InfluxDB name mismatch silently ate every sensor sample. Assert the alias.
  A="$ROOT/apps/zigbee/influxdb-alias-service.yaml"
  if [ -f "$A" ]; then
    grep -q 'name: influxdb' "$A" && grep -q 'port: 8086' "$A" \
      && ok "influxdb compatibility alias serves :8086 for the migrated flows" \
      || bad "influxdb alias has drifted - Node-RED flows will ENOTFOUND again"
  else
    bad "influxdb-alias-service.yaml missing - Node-RED cannot write to InfluxDB"
  fi
  grep -q 'kind: ConfigMap' "$N" \
    && bad "the node-red chart rendered a ConfigMap - it would shadow the restored /data/settings.js" \
    || ok "node-red chart renders no settings ConfigMap (the restored /data wins)"
else
  bad "node-red did not render"
fi

I="$WORK/influxdb.yaml"
if [ -f "$I" ]; then
  grep -q 'image: "influxdb:2.9.1-alpine"' "$I" \
    && ok "influxdb image pinned to 2.9.1-alpine (not the chart's 2023 appVersion)" \
    || bad "influxdb image is not pinned to 2.9.1-alpine"
  grep -q 'claimName: influxdb' "$I" \
    && ok "influxdb uses the hand-written PVC (storage decision is in the repo)" \
    || bad "influxdb does not use the hand-written PVC"
  grep -q 'kind: PersistentVolumeClaim' "$I" \
    && bad "the influxdb chart created its own PVC - useExisting is not in effect" \
    || ok "influxdb chart creates no PVC of its own (useExisting honoured)"
  grep -q 'kubernetes.io/hostname: homelab-2nd' "$I" \
    && ok "influxdb is pinned to the node holding its local-path volume" \
    || bad "influxdb is not pinned to homelab-2nd"
  grep -q 'name: zigbee-influxdb-credentials' "$I" \
    && ok "influxdb reads admin credentials from the SOPS secret (H2-215 contract)" \
    || bad "influxdb does not reference zigbee-influxdb-credentials"
else
  bad "influxdb did not render"
fi

head1 "6. every manifest on disk is wired into the kustomization"
missing=0
while IFS= read -r file; do
  name=$(basename "$file")
  [ "$name" = "kustomization.yaml" ] && continue
  if grep -q -- "- $name\$" "$DIR/kustomization.yaml"; then :; else
    bad "$name is not listed in apps/zigbee/kustomization.yaml"; missing=1
  fi
done < <(find "$DIR" -maxdepth 1 -name '*.yaml' | sort)
[ "$missing" -eq 0 ] && ok "all $(find "$DIR" -maxdepth 1 -name '*.yaml' | wc -l) manifest files are wired"

printf '\n== result: %s\n' "$([ "$fail" -eq 0 ] && echo PASS || echo FAIL)"
exit "$fail"
