---
name: paperclip-chat-intake
description: "Wojtek asks you for work in Mattermost or another chat: triage it, then record it in Paperclip (GUL) or hand it off as a Paperclip task."
version: 1.2.0
author: Claude Code (GUL-48)
license: MIT
metadata:
  hermes:
    tags: [paperclip, mattermost, tracking, intake]
    related_skills: [paperclip, deadline-bound-task-scope]
---

# Paperclip chat intake

Paperclip (`https://paperclip.voitech.dev`, company "Gulasz101 Homelab", prefix GUL) is the
record of everything Wojtek asks the agents for. He often asks in Mattermost because it is
easier on his phone. You work with him in the chat, and Paperclip keeps the trace.

Three Paperclip rules shape the flow:

- In a chat you **create** and **read** issues; nothing more. Every agent comment or update
  needs `X-Paperclip-Run-Id`, or Paperclip answers 403 with
  `details.code: cross_issue_influence_run_context_required`. That header carries only the
  `Run ID` of the Paperclip run you are in right now, from this session's wake prompt; a chat
  session has none. A run id from your history belongs to that run's issue: using it for a
  chat write falsifies the audit trail.
- A record is **final** once created. Write the whole description before the POST. It never
  mentions its own GUL number: the issue page shows it, and the `Recorded as GUL-<n>` line
  belongs in the chat.
- An issue you create with an assignee queues a Paperclip run for that agent, except in
  `backlog`. For `done` and `cancelled`, Paperclip cancels the queued run before it starts,
  so creating a record costs nothing.

So chat work gets one **record**, created when the work ends. Work that should run without
the chat gets a **hand-off**: a `todo` task that Paperclip runs.

## 1. Triage the request

| The request | You |
|---|---|
| Question, lookup, opinion, status check: nothing changes | answer in chat; no issue |
| Something changes (repo, PR, cluster, host, config, file, post, a message to someone else), or it takes more than about 10 minutes, and you finish it in this conversation | work in chat, then file a **record** (step 2) |
| Long, async or "later/overnight" work, or work another agent owns | file a **hand-off** (step 3) |

Wojtek's words override the table: "track this" means a record, "don't track" means no
issue, "run it in Paperclip" or "make it a task" means a hand-off. When unsure between no
issue and a record, file the record.

Done when you know which row applies.

## 2. Record: chat work, finished

When the work is finished, or abandoned, create one issue:

- `assigneeAgentId`: your own agent id (from `/api/agents/me`, or the agent table below).
- `status`: `done`; or `cancelled` when the work was abandoned or declined. A cancelled record
  states the reason in the first line of its `## Result`: there is no separate field for it.
- `projectId`: from the project table below.
- `title`: the outcome, imperative, at most 80 characters ("Bump the Loki chart to 6.30.1").
- `description`: this template.

```markdown
Origin: <Mattermost or the chat app>, <channel>, <YYYY-MM-DD>. Handled in chat by <your name>.

## Request
> <Wojtek's words, verbatim: every message that defined the task>

## What I did
- <steps and decisions, in order>

## Result
- <outcome, with links: PR, commit, GUL issue, URL>
- Verified: <how you checked it>

## Left open
- <anything not done, or "nothing">
```

A follow-up in the same thread after its record exists gets a new record whose description
starts with `Follow-up to GUL-<n>`. A record with a mistake gets a new record whose description
starts with `Correction to GUL-<n>`, and the original stays as it is: deleting issues is
Wojtek's call.

Done when the API answer carries an `identifier` and you posted
`Recorded as GUL-<n>: https://paperclip.voitech.dev/GUL/issues/GUL-<n>` in the chat.

## 3. Hand-off: Paperclip runs it

Create the issue with `status: "todo"`, assigned to yourself or to the agent who owns that
kind of work (agent table below). The run starts in a fresh session that never sees this
chat, so the description follows this template:

```markdown
Origin: <Mattermost or the chat app>, <channel name> (channel id <id>), <YYYY-MM-DD>.
Handed off by <your name>. Post the result there when done.

## Request
> <Wojtek's words, verbatim: every message that defined the task>

## Context
- <links, findings so far, constraints, what was already tried>

## Done when
- <acceptance criteria the run can check>
```

The channel id comes from the incoming chat message. When your context doesn't show it, write
the channel name alone and leave out the `(channel id ...)` part.

Done when the API answer carries an `identifier` and you posted
`Handed to Paperclip as GUL-<n>: <link>. The result will be posted here.` in the chat.

The woken run works the issue with the `paperclip` skill, then posts a short result and the
GUL link to that channel with `send_message`.

A hand-off runs on someone else's wall clock. Put the scope constraint **in the description**,
not in the chat: state what the deliverable is, what is out of scope, and any prior work to
reuse. A run with a hard budget that is not told what to skip will go and verify the world —
see [deadline-bound-task-scope](../deadline-bound-task-scope/SKILL.md).

## Agents

Take assignee ids from this table. For an agent missing here, list them with the agents call
in the API section.

| Agent | id | Owns |
|---|---|---|
| Bill Cipher | `7b52b09f-113e-4481-a1d2-d643a02e4086` | CEO: fleet-wide decisions |
| Claude Code | `97efeb2d-5b3a-4110-b893-6cbcbb29164c` | coding work (plans it, then delegates to Pi and OpenCode), reviews |
| Andrzej | `e12b834d-5e42-491a-9cd6-f4ddef2e97f8` | homelab: cluster, GitOps, hosts, network |
| Szarik | `b9cf4e60-2800-4686-a3c7-e38b0ed7432f` | Star Office UI, Mac-side work |
| Florian | `88647850-ccf0-4b25-8216-f3708315db4e` | blog |
| Zdzisław | `676cc93b-a08d-465f-8f59-0a564e5ff71f` | personal brand |
| Matejko | `332563dd-7ce2-4bad-8bb9-6b61f3f7221e` | images |

## Projects

| Project | id | Holds |
|---|---|---|
| Homelab | `ef56effa-5a10-4676-853c-f9114a423fa1` | cluster, GitOps, hosts, network, services |
| Star Office UI | `8660341a-cf5f-4aa0-a659-10e9df10c902` | SOU |
| Blog | `fc3b56f6-33dd-4822-a164-98a890778b18` | blog posts |
| Personal Brand | `62d58d69-6c41-4be8-9b11-1e62ac3bcde6` | LinkedIn, CV, job search |
| Agent Fleet | `4c634772-3280-4203-8fba-576368593eab` | agents, Hermes, Paperclip, models, skills |
| Image Studio | `df5a7cac-9689-44df-88b8-5d0626551123` | images |

## API

Your Paperclip identity is the key in your own profile `.env`. Shell variables do not survive
between terminal calls, so every command below loads the URL and key itself; keep the key out
of output. The URL lines strip a trailing `/api`, so both `.env` styles work.

Check who you are, and list the agents:

```bash
PC_URL=$(sed -n 's/^PAPERCLIP_API_URL=//p' "$HERMES_HOME/.env" | tail -1); PC_URL=${PC_URL%/}; PC_URL=${PC_URL%/api}
PC_KEY=$(sed -n 's/^PAPERCLIP_API_KEY=//p' "$HERMES_HOME/.env" | tail -1)
curl -s "$PC_URL/api/agents/me" -H "Authorization: Bearer $PC_KEY" | jq '{id, name, companyId}'
curl -s "$PC_URL/api/companies/0e2eb054-4cb6-4ea1-a2e7-2b1894285d8c/agents" \
  -H "Authorization: Bearer $PC_KEY" | jq -r '.[] | "\(.name)\t\(.id)"'
```

Create a record or hand-off in one command. The description goes through a private temp file
so newlines survive:

```bash
PC_URL=$(sed -n 's/^PAPERCLIP_API_URL=//p' "$HERMES_HOME/.env" | tail -1); PC_URL=${PC_URL%/}; PC_URL=${PC_URL%/api}
PC_KEY=$(sed -n 's/^PAPERCLIP_API_KEY=//p' "$HERMES_HOME/.env" | tail -1)
DESC=$(mktemp "${TMPDIR:-/tmp}/gul-issue.XXXXXX")
cat > "$DESC" <<'EOF'
<the filled-in record or hand-off template>
EOF
jq -n --arg title "<title>" --rawfile description "$DESC" \
  --arg assignee "<agent id>" --arg project "<project id>" --arg status "<done|cancelled|todo>" \
  '{title: $title, description: $description, status: $status, priority: "medium",
    assigneeAgentId: $assignee, projectId: $project}' \
| curl -s -X POST "$PC_URL/api/companies/0e2eb054-4cb6-4ea1-a2e7-2b1894285d8c/issues" \
    -H "Authorization: Bearer $PC_KEY" -H "Content-Type: application/json" --data @- \
| jq '{identifier, status, error}'
rm -f "$DESC"
```

An answer with `error` instead of `identifier` means nothing was saved: tell Wojtek in the
chat what failed, quoting the error.

Your own key is your only Paperclip credential. `~/.paperclip/auth.json` is Wojtek's board
login and the Paperclip server secrets belong to the server: leave both closed, and when your
key fails, report it in the chat and stop.

## Examples

1. "How full is the OMV disk?" Answer in chat. No issue.
2. Andrzej, asked "bump the Loki chart and make sure it's healthy": PR, merge, Flux
   reconciled, Loki answers queries, all in the chat. Then a `done` record in Homelab.
3. Florian, asked "write a post about the Paperclip rollout tonight": a `todo` hand-off in
   Blog, assigned to Florian, with the tracking-note links and the acceptance criteria.
4. Bill, asked "get Andrzej to rotate the MinIO key": a `todo` hand-off in Homelab assigned
   to Andrzej. Bill replies in chat with the link.
