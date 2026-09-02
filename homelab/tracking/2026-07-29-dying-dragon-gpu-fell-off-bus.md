---
topic: homelab / hardware / openviking / gpu
date: 2026-07-29
slug: dying-dragon-gpu-fell-off-bus
---

# The Dying Dragon: GTX 970M Fell Off the Bus

## Alert

2026-07-29T10:05:25+02:00 — OpenViking watchdog pinged @wojtek:

> Embedding inference probe returned HTTP 000
> Endpoint: http://192.168.1.179:30114

## First check

Both health endpoints answered:

```bash
curl http://127.0.0.1:1933/health
# {"status":"ok","healthy":true,"version":"v0.3.24","auth_mode":"api_key"}

curl http://192.168.1.179:30114/
# Ollama is running
```

But in `gpu-embedding` one Ollama pod was dead:

```bash
kubectl get pods -n gpu-embedding -o wide
# ollama-embeddings-7f7b8747b9-pz27p   0/1   UnexpectedAdmissionError   8d
# ollama-embeddings-7f7b8747b9-xjf2d   1/1   Running                  11h
```

## Root cause

Pod `pz27p` failed with:

```text
Allocate failed due to no healthy devices present;
cannot allocate unhealthy devices nvidia.com/gpu
```

`nvidia-smi` from the host:

```text
Unable to determine the device handle for GPU0000:01:00.0: Unknown Error
```

`dmesg`:

```text
NVRM: Xid (PCI:0000:01:00): 79, pid=811977, name=nvidia-smi,
      GPU has fallen off the bus.
NVRM: GPU 0000:01:00.0: GPU has fallen off the bus.
```

Also notable: the PCIe link had downgraded to **2.5GT/s** (capable of 8GT/s), and the `nvidia-device-plugin-gpu-feature-discovery` pod was in `CrashLoopBackOff` with:

```text
failed to get full GPU device editors: error getting device handle for index '0': Unknown Error
```

## Supreme Leader's confession

Wojtek revealed the dragon had been running at **~100°C for the last month** while churning embeddings. That is not a cooling strategy; that is an assisted-suicide strategy for a 9-year-old laptop GPU.

## Fix applied

1. Rebooted `homelab-2nd`.
2. Post-reboot verified GPU back on the bus:

```bash
nvidia-smi
# NVIDIA GeForce GTX 970M, Persistence-M On, 57°C, Ollama using 697MiB
```

3. NVIDIA device plugin back to `2/2 Running`.
4. New Ollama pod `ollama-embeddings-7f7b8747b9-ktswk` Running.
5. Force-deleted the two stale dead pods (`pz27p`, `xjf2d`) so they stop polluting alerts.

## Alerting verdict: successful

The OpenViking embedding-probe watchdog did exactly what it was for. It turned a silent GPU failure into an actionable ping. Without it, the dead GPU would have sat there until someone tried to embed something and wondered why it was slow or broken. **The alert brought attention to the dead GPU before a human noticed.**

## What is still wrong

The hardware is dying. Reboot fixed it this time, but it had already failed twice in ~24 hours. Running the dGPU at 100°C for a month has cooked the solder/connector/PSU. Until extra cooling is installed and temperatures drop, expect repeats.

## Next steps

1. **Install extra cooling** as Wojtek plans.
2. Monitor GPU temp in the `gpu-embedding` Grafana dashboard; aim to keep it well below 85°C under sustained load.
3. If it falls off the bus again, consider:
   - forcing PCIe link to gen1/gen2 for stability,
   - migrating OpenViking embeddings to a CPU-only Ollama deployment.
4. Keep the watchdog as-is; it is already proving its value.

## Commands used

```bash
ssh homelab-2nd
sudo -n kubectl get pods -n gpu-embedding -o wide
sudo kubectl describe pod -n gpu-embedding ollama-embeddings-7f7b8747b9-pz27p
sudo nvidia-smi
sudo dmesg | grep -iE "nvrm|xid.*79|gpu.*fallen"
sudo lspci -vv -s 01:00.0 | grep -iE "aspm|lnkcap|lnksta"
sudo shutdown -r +0 "Rebooting to recover fallen-off NVIDIA GPU"
sudo kubectl delete pod -n gpu-embedding ollama-embeddings-7f7b8747b9-pz27p ollama-embeddings-7f7b8747b9-xjf2d --force
```
