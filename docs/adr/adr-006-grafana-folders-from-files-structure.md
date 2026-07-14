# ADR-006: Grafana folder structure for provisioned dashboards

Date: 2026-07-14
Status: Accepted
Supersedes: nothing
Superseded by: nothing

## Context

Grafana dashboards are provisioned from repo ConfigMaps by the Grafana Helm chart sidecar. Each ConfigMap carries a `grafana.folder` annotation (e.g. `Homelab`, `honcho`, `auth`, `observability`) so that dashboards would appear grouped in the Grafana UI.

After the sidecar was enabled, all dashboards were provisioned but they all landed in the default **General** folder. The sidecar logs showed it was correctly placing files under `/tmp/dashboards/<folder>/<dashboard>.json`, so the annotation was being honoured by the sidecar, but Grafana itself ignored the directory structure.

The root cause was the generated `sc-dashboardproviders.yaml` in the Grafana pod:

```yaml
providers:
  - name: 'sidecarProvider'
    orgId: 1
    folder: ''
    folderUid: ''
    type: file
    disableDeletion: false
    allowUiUpdates: false
    updateIntervalSeconds: 30
    options:
      foldersFromFilesStructure: false
      path: /tmp/dashboards
```

`foldersFromFilesStructure: false` tells Grafana to treat `/tmp/dashboards` as a flat directory and dump every provisioned dashboard into the configured `folder` (empty → General). This makes the `grafana.folder` annotation useless.

## Decision

Set `foldersFromFilesStructure: true` in the Grafana dashboard sidecar provider configuration by adding the following to `infrastructure/observability/grafana-helm-release.yaml`:

```yaml
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    folderAnnotation: grafana.folder
    reloadURL: "http://grafana.observability.svc.cluster.local:3000/api/admin/provisioning/dashboards/reload"
    provider:
      foldersFromFilesStructure: true
```

With this setting, Grafana uses the subdirectory names created by the sidecar as folder names in the UI. The `grafana.folder` annotation on ConfigMaps therefore controls both the on-disk path and the Grafana folder.

## Consequences

### Positive
- Dashboards are grouped logically: `Homelab`, `auth`, `honcho`, `llm-hub`, `nextcloud`, `docs-mcp`, `gpu-embedding`, `mattermost`, `observability`.
- Folder grouping is GitOps-driven: change the annotation, reconcile Flux, reload Grafana.
- Future services follow the same convention with no extra manual folder creation.

### Negative / Risks
- Renaming a folder annotation moves the dashboard in the UI. This is desirable, but a typo would create an unexpected folder.
- Grafana 11 unified storage is still experimental for provisioned dashboards; if unified-storage indexing breaks again, the reload step may be needed after folder changes.
- Changing `foldersFromFilesStructure` forces Grafana to re-import dashboards into folders. IDs remain stable because dashboards are matched by `uid`, but a one-time provisioning reload is required.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Define fixed providers in `grafana.ini` for each folder | Rejected. Adds N provider stanzas to the Helm values and must be updated every time a new folder is added. The sidecar directory structure is already correct. |
| Create folders manually via the Grafana UI/API | Rejected. GitOps is law (Guardrail #1). Folders and dashboards must come from the repo. |
| Remove `grafana.folder` annotations and live with a flat list | Rejected. With 10+ dashboards, a flat General folder is unusable for operations. |
| Use `folderAnnotation` only and rely on Grafana to create folders | Rejected. The chart's `folderAnnotation` only affects where the sidecar writes files; without `foldersFromFilesStructure: true` Grafana still imports to the provider's configured folder. |

## When to revisit

Revisit this ADR if:
- We upgrade to a Grafana chart version that changes the default provider behaviour.
- Grafana deprecates `foldersFromFilesStructure` or unified storage becomes the only backend and behaves differently.
- We decide to move dashboards to per-namespace folders automatically derived from the namespace name rather than the `grafana.folder` annotation.

## References

- `infrastructure/observability/grafana-helm-release.yaml`
- Tracking note: `homelab/tracking/2026-07-14-dashboards-missed-overnight-run.md`
