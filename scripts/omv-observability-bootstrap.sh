#!/usr/bin/env bash
# One-time bootstrap for OMV observability metrics.
# Run as root on openmediavault.local.
# This script:
#   - enables Docker Engine native metrics on 192.168.1.180:9323
#   - installs and starts Prometheus node_exporter on 0.0.0.0:9100
#   - verifies both endpoints respond

set -euo pipefail

NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_ARCH="linux-amd64"
NODE_EXPORTER_TAR="node_exporter-${NODE_EXPORTER_VERSION}.${NODE_EXPORTER_ARCH}.tar.gz"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_TAR}"
OMV_IP="192.168.1.180"

log() {
  echo "[omv-obs] $(date -Iseconds) - $*"
}

# --- Docker metrics ----------------------------------------------------------
log "Configuring Docker Engine metrics on ${OMV_IP}:9323"

if [[ -f /etc/docker/daemon.json ]]; then
  log "Backing up existing /etc/docker/daemon.json"
  cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
fi

# Write a fresh daemon.json. OMV currently has none, so this is safe.
cat > /etc/docker/daemon.json <<EOF
{
  "metrics-addr": "${OMV_IP}:9323",
  "experimental": true
}
EOF

log "Reloading Docker without restarting containers"
if systemctl is-active --quiet docker; then
  systemctl reload docker || true
  # If reload didn't pick it up, fall back to SIGHUP on the daemon
  pkill -SIGHUP -x dockerd || true
else
  systemctl start docker
fi

# Give Docker a moment to open the metrics port
sleep 2

if ss -tlnp | grep -q ":9323"; then
  log "Docker metrics endpoint listening on :9323"
else
  log "WARNING: Docker metrics endpoint not yet listening on :9323"
fi

# --- node_exporter -----------------------------------------------------------
log "Installing node_exporter ${NODE_EXPORTER_VERSION}"

cd /tmp
curl -fsSL -o "${NODE_EXPORTER_TAR}" "${NODE_EXPORTER_URL}"
tar -xzf "${NODE_EXPORTER_TAR}"
cp "node_exporter-${NODE_EXPORTER_VERSION}.${NODE_EXPORTER_ARCH}/node_exporter" /usr/local/bin/node_exporter
chmod +x /usr/local/bin/node_exporter
rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.${NODE_EXPORTER_ARCH}" "${NODE_EXPORTER_TAR}"

# Create systemd unit
cat > /etc/systemd/system/node-exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=/usr/local/bin/node_exporter --path.rootfs=/host
ExecReload=/bin/kill -HUP $MAINPID
StandardOutput=journal
StandardError=journal
SyslogIdentifier=node-exporter

[Install]
WantedBy=multi-user.target
EOF

# For container-level filesystem metrics, node_exporter expects /host rootfs mount.
# Create the mount point if it doesn't exist and patch the unit to require it.
mkdir -p /host

# Patch the unit to mount host rootfs inside the service's mount namespace.
# We use a bind mount so node_exporter sees the host filesystem under /host.
mkdir -p /etc/systemd/system/node-exporter.service.d
cat > /etc/systemd/system/node-exporter.service.d/host-rootfs.conf <<'EOF'
[Service]
BindReadOnlyPaths=/:/host
EOF

systemctl daemon-reload
systemctl enable --now node-exporter

sleep 2

if systemctl is-active --quiet node-exporter; then
  log "node_exporter is active"
else
  log "ERROR: node_exporter failed to start"
  systemctl status node-exporter --no-pager || true
  exit 1
fi

# --- Verification ------------------------------------------------------------
log "Verifying endpoints"

if curl -fsS "http://${OMV_IP}:9323/metrics" | grep -q "^# TYPE"; then
  log "Docker metrics endpoint OK: http://${OMV_IP}:9323/metrics"
else
  log "WARNING: Docker metrics endpoint did not return metrics"
fi

if curl -fsS "http://${OMV_IP}:9100/metrics" | grep -q "^# TYPE node_"; then
  log "node_exporter endpoint OK: http://${OMV_IP}:9100/metrics"
else
  log "ERROR: node_exporter endpoint did not return metrics"
  exit 1
fi

log "OMV observability bootstrap complete"
log "Next: add the following static scrape configs to kube-prometheus-stack:"
echo "  - job_name: omv-node"
echo "    static_configs:"
echo "      - targets: ['${OMV_IP}:9100']"
echo "        labels:"
echo "          instance: openmediavault"
echo "          host: openmediavault"
echo "  - job_name: omv-docker"
echo "    static_configs:"
echo "      - targets: ['${OMV_IP}:9323']"
echo "        labels:"
echo "          instance: openmediavault"
echo "          host: openmediavault"
