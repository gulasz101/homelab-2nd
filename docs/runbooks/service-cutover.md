# Runbook: cutting over a service the house depends on

**Use for:** moving or restarting anything other devices need in order to work: Pi-hole (DNS on
`192.168.1.179`), the `.179` front-door address, the k3s API, MQTT for Tasmota devices, OMV NFS.
**Written after:** the 2026-11-12 Pi-hole move. LAN DNS was down 01:23 → 07:55 because the new
Pi-hole node resolved names through Pi-hole, and the operator's SSH hop stalled on a NetBird SSO
prompt with nobody watching. Tracking note: `homelab/tracking/2026-11-11-control-plane-move-clevo-t460-to-mimir-loki.md`.

A cutover is an **outage window**: it has a start, a time limit, a health check and a revert. Write
all four down before step 1.

## Before the window

1. **Pre-pull every image on the target node** while the old service is still serving:
   ```sh
   ssh mimir@192.168.1.145 'sudo k3s crictl pull docker.io/pihole/pihole:<tag>'   # and sidecars
   ```
   The new node may resolve names through the very service you are about to stop.
2. **Check the dependency is not the service itself.** DNS: the target's `/etc/resolv.conf`, and
   OPNsense lets only `192.168.1.179` send port 53 to the internet. NFS: OMV `/etc/exports` grants
   per node IP. Run `scripts/node-refs.sh` for the old node (see `decommission-node.md`).
3. **Pick a path that cannot prompt.** LAN key SSH (`mimir@192.168.1.145`, `paperclip.local`) or
   kubectl to `https://192.168.1.145:6443`. Never NetBird SSH (`ssh paperclip`, `ssh m1max`): it can
   stop and wait for a browser login. Keep `~/.ssh/config`'s `Host *` timeouts in place.
4. **Write the revert** as a command you can paste, e.g. scale the old Deployment back up and pin it
   to the old node.

## During the window

5. **Run the cutover as one script on the target host** (`ssh host 'bash -s' < cutover.sh`), so a
   dead laptop or a stalled hop cannot stop it halfway.
6. **Arm a deadman** in the same script. It reverts unless the health check passes in time:
   ```sh
   # DNS example: revert if .179 does not answer within 10 minutes
   deadline=$(( $(date +%s) + 600 ))
   until dig +short +time=2 +tries=1 @192.168.1.179 example.com | grep -q .; do
     [ "$(date +%s)" -ge "$deadline" ] && { echo "DEADMAN: reverting"; <revert command>; exit 1; }
     sleep 10
   done
   ```
7. **Post progress** to Mattermost `#cc-updates` at start, at the health check, and at the end
   (skill `cc-updates`), so a stall is visible to a human.

## After the window

8. Verify from a **client's** point of view, not the server's: `dig @192.168.1.179` from a LAN host,
   the public URLs, a NodePort on `.179`.
9. Record the window (start, end, impact) in the activity's tracking note.
