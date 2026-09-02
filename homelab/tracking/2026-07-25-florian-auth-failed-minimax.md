---
date: 2026-07-25
tags: [homelab, litellm, florian, auth, gitops]
---

# Florian Profile: Auth Failed for Provider (minimax-m3-go)

## Symptom
Florian profile (Hermes blog-writing agent) was failing with "Authentication failed and could not be refreshed — switching to fallback provider" when trying to use `minimax-m3-go` via `llm.voitech.dev`.

## Root Cause
**The `hermes-florian` LiteLLM virtual key was never enrolled in the key-provisioner CronJob, so its model whitelist never got expanded beyond the single model it was created with.**

Timeline:
- **2026-06-26**: Florian profile created. Its LiteLLM key (`hermes-florian`, token `sk-...nsOg`) was created manually with only `glm-5.2-ollama` model access.
- **2026-07-07**: The `litellm-key-provisioner` CronJob was deployed to reconcile all user keys against the `DESIRED_MODELS` list. It only knew about 5 keys: `WIFE_KEY`, `WOJTEK_KEY`, `HERMES_ANDRZEJ_KEY`, `MEMORY_HONCHO_KEY`, `HERMES_BILL_CIPHER_KEY`.
- **Recently**: Florian's profile default model was changed to `minimax-m3-go`. LiteLLM rejected every request with HTTP 403:
  ```
  key not allowed to access model. This key can only access models=['glm.5.2', 'glm-5.2-ollama']. Tried to access minimax-m3-go
  ```

## Immediate Fix (2026-07-25 ~12:00)
Used the LiteLLM master key to manually update `hermes-florian` key to the full model list (58 models). Verified:
- `POST /key/update` returned 200
- `GET /key/info` confirms `minimax-m3-go` and `openai/minimax-m3-go` are now in the whitelist
- LiteLLM logs now show `200 OK` for `minimax-m3` requests from Florian's IP (`10.42.0.81` — the Honcho deriver pod which routes Florian's cron jobs)

## GitOps Gap (TODO)
The fix is **not durable**. If the provisioner runs and Florian's key isn't in its list, it won't be touched — but also won't regress because the provisioner only updates keys it knows about. The real risk is:
1. If someone rotates/regenerates the key, the new one won't be provisioned.
2. If models are added/removed, Florian won't get the update.

### Files that need updating in `gulasz101/homelab-2nd`:

1. **`apps/llm-hub/litellm-user-keys.sops.yaml`** — Add `hermes-florian-key: <encrypted>`
2. **`apps/llm-hub/litellm-key-provisioner-cronjob.yaml`** — Add env var:
   ```yaml
   - name: HERMES_FLORIAN_KEY
     valueFrom:
       secretKeyRef:
         name: litellm-user-keys
         key: hermes-florian-key
   ```
3. **`apps/llm-hub/litellm-key-provisioner-configmap.yaml`** — Add `HERMES_FLORIAN_KEY` to `KEY_ENV_NAMES` list.

### Why Florian wasn't in the provisioner from day one
The key was created manually (probably via `POST /key/generate`) before the provisioner existed. When the provisioner was written, Florian was forgotten. This is a classic "manually created resource drifts from GitOps state" bug.

## Lessons
- **Every manually created LiteLLM key must be backfilled into the `litellm-user-keys` secret and the provisioner env list.**
- The provisioner should probably log a warning if it finds keys in LiteLLM that it doesn't know about — orphan detection.
- The error message "Authentication failed and could not be refreshed" from Hermes is misleading here; the real error is LiteLLM 403 `key_model_access_denied`, which shows up in `gateway.error.log`.

## Verification Commands
```bash
# Check Florian key models
ssh gulasz101@homelab-2nd 'sudo kubectl exec -n llm-hub deployment/litellm -- python -c "
import urllib.request, json, os
mk = os.environ[\"PROXY_MASTER_KEY\"]
url = \"http://localhost:4000/key/info?key=9312416402a7f031ba944d031b1b4043434ce61fa1b26bd6f90757ce51806a9a\"
req = urllib.request.Request(url, headers={\"Authorization\": \"Bearer \" + mk})
resp = urllib.request.urlopen(req)
data = json.loads(resp.read().decode())
print(sorted(data.get(\"info\",{}).get(\"models\",[])))
"'
```
