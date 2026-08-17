---
title: "Fix security scan task list and verify homelab-task-executor cronjob"
status: done
priority: low
created: 2026-08-17
labels:
  - security
  - scan
  - cronjob
  - tasks
assigned: andrzej
source: mattermost-follow-up
---

## Context

After fixing the plaintext Mattermost webhook Secret, the Supreme Leader noticed the nightly security scan report listed four "Open task notes":

- `001-fix-barman-cloud-plaintext-secret.md`
- `002-harden-otel-collector-security-context.md`
- `003-review-nvidia-gpu-exporter-hostpath.md`
- `004-reduce-security-scan-noise.md`

and asked why those tasks were not being processed any more.

## Investigation

1. Checked the frontmatter of all four task notes. All are `status: done`.
2. Listed Hermes cronjobs. Found `homelab-task-executor` (`e21fa9f94e97`) scheduled at `0 4 * * *`, last run at 2026-08-17 04:00:48 with `last_status: ok`.
3. Manually ran `homelab-task-executor`. It returned `execution_success: true` and produced no output, which is the expected behavior when there are zero open tasks.
4. Conclusion: the task executor is healthy; the security scan script was falsely reporting done tasks as "open" because it used `ls -1` on the tasks directory without reading frontmatter.

## Fix

Patched `scripts/homelab-security-scan.sh` to parse each task note's frontmatter `status:` field and only print files whose status is `open` or `in_progress`. If none are open, it prints `(none)`.

```bash
python3 - "$TASK_DIR" <<'PY'
import pathlib, re, sys
d = pathlib.Path(sys.argv[1])
open_tasks = []
for f in sorted(d.glob('*.md')):
    text = f.read_text()
    m = re.search(r'^status:\s*(\S+)', text, re.M)
    if m and m.group(1) in ('open', 'in_progress'):
        open_tasks.append(f.name)
if open_tasks:
    for name in open_tasks:
        print(name)
else:
    print('(none)')
PY
```

Committed and pushed:

```bash
cd /Users/wojciechgula/Projects/homelab-2nd
git add scripts/homelab-security-scan.sh
git commit -m "fix(security-scan): only list open or in-progress task notes" \
           -m "Parse frontmatter status instead of ls -1 on the tasks directory."
git push
```

Commit: `93bd872`

## Verification

Re-ran the security scan locally:

```bash
"$HOME/.hermes/profiles/andrzej/scripts/homelab-security-scan.sh"
```

Output tail:

```
| Plaintext Secret manifests | 0 |
| hostPath volumes | 1 |
| Privileged containers | 1 |
| Root (uid/gid 0) containers | 1 |

Summary:
| Category | Count |
| Critical issues | 0 |
| Warnings | 4 |

No criticals, but warnings need review.
```

Because there are now zero critical findings, the script prints the warnings branch and does not print the "Open task notes" section at all. When a future scan does have critical findings, the task list will now correctly show only open/in-progress tasks.

## Files changed

- `scripts/homelab-security-scan.sh`

## Notes

- The `homelab-task-executor` cronjob is still scheduled and healthy. The reason it has not produced task-execution output is that all current task notes are `status: done`.
- The remaining 4 warnings in the scan are upstream-chart / accepted risks, not open tasks.
- The new task note `005-fix-mattermost-webhook-plaintext-secret.md` was also marked `status: done` after the webhook Secret was encrypted.
