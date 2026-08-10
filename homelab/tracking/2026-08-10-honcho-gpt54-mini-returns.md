# Honcho Dream specialists still calling `gpt-5.4-mini`

## Date

2026-08-10

## Symptom

Supreme Leader spotted fresh errors in the `honcho-api` logs:

```text
2026-08-09 10:23:57,259 - src.llm.api - WARNING - Error on attempt 1/3 with openai/gpt-5.4-mini: Error code: 403 - {'error': {'message': "key not allowed to access model. This key can only access models=[...]. Tried to access gpt-5.4-mini", 'type': 'key_model_access_denied', 'param': 'model', 'code': '403'}}
2026-08-09 10:24:05,361 - src.dreamer.orchestrator - ERROR - [0qM6DnNbdSgzGvulw7gq4] Induction specialist failed: RetryError[<Future at 0x7f275ffe9450 state=finished raised PermissionDeniedError>]
```

The failures were coming from `induction_specialist` inside the Dream orchestrator.

## Root cause

ADR-005 (2026-07-03) already forced all Honcho LLM features onto the internal LiteLLM hub by overriding their `MODEL_CONFIG` env vars. At that time the Dream module exposed a single `DREAM_MODEL_CONFIG`. Since then the upstream Honcho image (`ghcr.io/gulasz101/honcho:latest`) split Dream into two specialists:

- `DREAM.DEDUCTION_MODEL_CONFIG`
- `DREAM.INDUCTION_MODEL_CONFIG`

Both still hardcode `openai/gpt-5.4-mini` as the default. The old `DREAM_MODEL_CONFIG__*` env vars in `apps/honcho/honcho-configmap.yaml` were therefore being ignored, so the induction specialist fell back to the forbidden model and LiteLLM rejected it with `403 key_model_access_denied`.

## What was fixed

1. Updated `apps/honcho/honcho-configmap.yaml`:
   - Removed the stale `DREAM_MODEL_CONFIG__*` entries.
   - Added overrides for both Dream specialists:
     - `DREAM_DEDUCTION_MODEL_CONFIG__MODEL=mistral-3.5-middle`
     - `DREAM_INDUCTION_MODEL_CONFIG__MODEL=mistral-3.5-middle`
   - Set matching `TRANSPORT=openai` and `OVERRIDES__BASE_URL=http://litellm.llm-hub.svc.cluster.local:4000/v1` for both.

2. Updated `docs/adr/adr-005-honcho-llm-hub-only.md`:
   - Replaced `DREAM_MODEL_CONFIG` with `DREAM_DEDUCTION_MODEL_CONFIG` and `DREAM_INDUCTION_MODEL_CONFIG`.
   - Added a note explaining the upstream split.
   - Added a revisit trigger if Honcho merges the two configs back together.

3. Committed and pushed:
   - `92945cd` — `fix(honcho): override Dream deduction/induction specialist models to mistral-3.5-middle`

4. Reconciled and rolled out:
   - `flux reconcile kustomization apps --with-source`
   - `kubectl rollout restart deployment/honcho-api deployment/honcho-deriver -n honcho`

## Verification

- ConfigMap now contains `DREAM_DEDUCTION_MODEL_CONFIG__MODEL: mistral-3.5-middle` and `DREAM_INDUCTION_MODEL_CONFIG__MODEL: mistral-3.5-middle`.
- New pods have both env vars.
- Runtime check inside the pod confirms the loaded settings:

```bash
kubectl exec -n honcho deployment/honcho-api -- python -c \
  "from src.config import settings; print(settings.DREAM.INDUCTION_MODEL_CONFIG.model, settings.DREAM.DEDUCTION_MODEL_CONFIG.model)"
# mistral-3.5-middle mistral-3.5-middle
```

## Remaining risk

`ghcr.io/gulasz101/honcho:latest` is pulled with `imagePullPolicy: Always`. If Honcho renames these config fields or adds a third Dream specialist, the defaults could again route to a model not in our hub. The only robust long-term fix is either:

- pin to a tagged image and rebuild Honcho with homelab-friendly defaults, or
- keep auditing the upstream `src/config.py` defaults whenever the image changes.

## References

- `apps/honcho/honcho-configmap.yaml`
- `docs/adr/adr-005-honcho-llm-hub-only.md`
- Commit `92945cd`
