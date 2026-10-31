# Shared Hermes skills

Skills every Hermes profile on the M1 Air (`paperclip`) loads, kept in Git so changes are
reviewed and visible. Instructions only: no secrets, no hostnames that are not already public
in this repo. Decision record: [ADR-076](../../docs/adr/adr-076-paperclip-is-the-record-for-chat-requests.md).

| Skill | Source | For |
|---|---|---|
| `paperclip-chat-intake` | this directory | Wojtek asks for work in Mattermost: no issue, a closed record, or a Paperclip hand-off |
| `deadline-bound-task-scope` | this directory | A run with a hard wall-clock budget: deliver the artifact before investigating |
| `paperclip-claude-auth` | this directory | A Claude Code agent in Paperclip lost its login, or the connection credential needs rotating |
| `paperclip` | the installed Paperclip (`~/.paperclip/cli/current/node_modules/@paperclipai/server/skills/paperclip`), linked, not copied | Paperclip woke the agent for a GUL issue |

## How Hermes loads them

```text
~/agent-skills/homelab-2nd/                 # clone of this repo, on main
~/agent-skills/hermes-paperclip/            # listed in skills.external_dirs of each profile
├── paperclip-chat-intake -> ~/agent-skills/homelab-2nd/agents/hermes-skills/paperclip-chat-intake
├── paperclip-claude-auth -> ~/agent-skills/homelab-2nd/agents/hermes-skills/paperclip-claude-auth
└── paperclip             -> ~/.paperclip/cli/current/node_modules/@paperclipai/server/skills/paperclip
```

Each of the 6 profiles (`~/.hermes/config.yaml` and `~/.hermes/profiles/<name>/config.yaml`)
carries:

```yaml
skills:
  external_dirs:
    - ~/agent-skills/hermes-paperclip
```

Check a profile with `hermes -p <name> config get skills.external_dirs`; a new profile needs the
same entry. Hermes follows symlinks when it scans skill directories, and a profile-local skill
with the same name shadows an external one, so the profiles carry no `paperclip*` skills of
their own.

## Updating

After a change merges to `main`:

```bash
git -C ~/agent-skills/homelab-2nd pull --ff-only
```

New sessions pick up skill changes without a gateway restart.

Agents can edit external skills with `skill_manage`. `git -C ~/agent-skills/homelab-2nd
status` shows such edits; bring good ones back through a PR.
