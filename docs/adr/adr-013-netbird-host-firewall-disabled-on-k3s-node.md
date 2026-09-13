# ADR-013: NetBird host firewall disabled on the k3s control-plane node

**Status:** Accepted  
**Date:** 2026-09-13  

## Context

`homelab-2nd` runs two things that both program the Linux packet filter:

1. **k3s** — its embedded kube-router network-policy controller and kube-proxy program the nftables `ip filter` table through the **bundled `iptables-nft` v1.8.11** (`/var/lib/rancher/k3s/data/<hash>/bin/aux/iptables`).
2. **NetBird 0.77.0** — the mesh VPN client, running the **kernel WireGuard** interface (`wt0`), which writes its firewall rules with the **Google `nftables` Go library** (native nftables, not `iptables`).

On 2026-09-13, right after the Supreme Leader stopped/started NetBird following a change to policies in the NetBird admin panel, k3s entered a ~9-second crash loop (`NRestarts=141`, ~855 starts in 3 hours). Every workload flapped, the API server was intermittently unavailable, and load average hit 12 on 8 cores.

Root cause (confirmed by reading the journal and reproducing the failed command):

- NetBird inserts native-nft rules into the `ip filter` INPUT/FORWARD/OUTPUT chains (`iifname "wt0" … accept`, `oifname "wt0" ct state established,related …`, `meta mark …`).
- kube-router's netpol controller verifies its own jump rule with `iptables -t filter -C FORWARD -m comment --comment "kube-router netpol - …" -j KUBE-ROUTER-FORWARD`. To do the check, `iptables-nft` must parse the whole chain back. It cannot parse NetBird's rules:
  ```
  iptables v1.8.11 (nf_tables): chain `FORWARD' in table `filter' is incompatible, use 'nft' tool.
  Error: cmp sreg undef
  ```
- kube-router treats that as fatal — `klog.Fatalf` in `network_policy_controller.go:405` — so the **entire k3s server process exits with code 2**. `Restart=always` + `RestartSec=5s` turns it into a crash loop.
- kube-proxy hits the same parse failure on its FORWARD chain-jump checks (`Failed to ensure chain jumps … cmp sreg undef`) but only logs and retries every 30s, so Service routing is degraded rather than fatal.

This is a documented, upstream-acknowledged incompatibility: k3s #11493, k3s #11415 ("nftables with conntrack can break k3s"), kube-router #1788, netbird #2926 / #6022 / #6166. There is no k3s or iptables version that fixes it — k3s already bundles iptables 1.8.11, which still fails (netbird #2926).

Constraints:

- **NetBird must stay on the node.** It is the remote-access path, and its mesh IP `100.96.90.128` is a k3s `tls-san` and the address exposed for the docs-mcp MCP endpoint.
- **k3s must stay fully functional**, including NetworkPolicy enforcement and Service routing.

## Decision

**Disable NetBird's host firewall management on `homelab-2nd`, keeping its kernel WireGuard interface and routing.**

Set `DisableFirewall: true` in the NetBird profile (`/var/lib/netbird/default.json`) by cycling the client:

```bash
sudo netbird down
sudo netbird up --disable-firewall
```

NetBird then no longer writes any native nftables rules. Its `table ip netbird` disappears entirely, the nftables `ip filter` table is written only by k3s's `iptables-nft`, and both kube-router and kube-proxy work normally again.

Two implementation notes worth remembering:

- In **NetBird 0.77.0** the `NB_DISABLE_FIREWALL=true` environment variable (via the systemd `EnvironmentFile`) did **not** take effect; the *profile config* is the source of truth. A copy is left in `/etc/sysconfig/netbird` as belt-and-braces, but the profile is what works.
- `netbird up --disable-firewall` is a no-op while the client is already connected ("Already connected") — it must be preceded by `netbird down`.

**Operational constraint:** never run `netbird up` on this node without `--disable-firewall`, or the rules return and k3s goes back into the crash loop.

## Consequences

**Positive**

- k3s is stable again: `NRestarts=0`, no `klog.Fatalf`, NetworkPolicy controller completes its full sync.
- kube-proxy programs its FORWARD chain jumps again; Services behave correctly.
- NetworkPolicy is enforced as designed (the cluster does carry policies: `flux-system/allow-egress`, `allow-scraping`, `allow-webhooks`, `nextcloud/nextcloud-redis`).
- NetBird mesh, kernel WireGuard (`wt0`), routing and SSH-over-NetBird all keep working.
- The conflict is removed at the source, so it cannot recur on the next policy change or NetBird restart.

**Negative**

- NetBird's **client-side ACL/Policies are no longer enforced on this host**. Host exposure now rests on the LAN/router boundary plus in-cluster NetworkPolicy/Kubernetes RBAC.
- A future NetBird policy change in the admin panel will not be enforced at this node.
- There is a sharp edge: a manual `netbird up` without the flag silently reintroduces the k3s crash loop.

## Alternatives considered

- **k3s `disable-network-policy: true`.** Stops the fatal crash loop, but kube-proxy still cannot program its FORWARD chain jumps, so Services stay degraded. A stopgap, not a fix.
- **Upgrade or downgrade NetBird / iptables.** No known-good version: the bug is open through NetBird ≥ 0.73.2, and k3s already bundles iptables 1.8.11 which still fails. Rejected.
- **`nft flush ruleset` + restart k3s.** Recovers temporarily, but NetBird immediately re-adds the incompatible rules on the next reconcile. Rejected.
- **Run NetBird in a network namespace / on a separate host.** The node itself needs the mesh interface and routes; isolating it is complex and would break the intended topology. Rejected.
- **Migrate the k3s dataplane to Cilium** (kube-proxy replacement + native nftables/eBPF NetworkPolicy). The robust long-term answer if NetBird ACL enforcement is ever required, but it is a real migration and NetBird's kube-proxy mark interactions would still need care (netbird #6022). Deferred.

## When to revisit

- **If NetBird ACL enforcement on this node becomes required** → execute the Cilium dataplane migration (kube-proxy replacement + Cilium NetworkPolicy), which avoids the iptables-nft read path entirely.
- **If upstream fixes the incompatibility** such that iptables-nft can parse NetBird's rules (or kube-router stops `klog.Fatalf`ing and kube-proxy handles it gracefully) → re-enable the host firewall (`netbird up` without `--disable-firewall`).
- **If NetBird ships a supported way to write only iptables-nft-compatible rules** (the requested `--skip-native-firewall`, netbird #6166) → prefer that over disabling the whole firewall.
