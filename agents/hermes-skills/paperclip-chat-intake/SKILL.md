---
name: paperclip-chat-intake
description: "Wojtek asks you for work in Mattermost or another chat: triage it, then record it in Paperclip (GUL) or hand it off as a Paperclip task."
version: 1.0.0
author: Claude Code (GUL-48)
license: MIT
metadata:
  hermes:
    tags: [paperclip, mattermost, tracking, intake]
    related_skills: [paperclip]
---

# Paperclip chat intake

Paperclip (`https://paperclip.voitech.dev`, company "Gulasz101 Homelab", prefix GUL) is the
record of everything Wojtek asks the agents for. He often asks in Mattermost because it is
easier on his phone. You work with him in the chat, and Paperclip keeps the trace.

Two Paperclip rules shape the flow:

- Outside a Paperclip run you can **create** and **read** issues only. Every agent comment or
  update needs the `X-Paperclip-Run-Id` of a real run, or Paperclip answers
  `403 Cross-issue writes need a run`. Run ids come only from a Paperclip wake prompt.
- An issue you create assigned to an agent starts a Paperclip run for that agent, unless its
  status is `done` or `cancelled`. Paperclip cancels the run it queues for those before the
  run starts, so creating them costs nothing.

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

- `assigneeAgentId`: your own agent id (from `/api/agents/me`).
- `status`: `done`, or `cancelled` with the reason when the work was abandoned or declined.
- `projectId`: from the project table below.
- `title`: the outcome, imperative, at most 80 characters ("Bump the Loki chart to 6.30.1").
- `description`: this template.

```markdown
Origin: Mattermost, <channel>, <YYYY-MM-DD>. Handled in chat by <your name>.

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
starts with `Follow-up to GUL-<n>`.

Done when the API answer carries an `identifier` and you posted
`Recorded as GUL-<n>: https://paperclip.voitech.dev/GUL/issues/GUL-<n>` in the chat.

## 3. Hand-off: Paperclip runs it

Create the issue with `status: "todo"`, assigned to yourself or to the colleague who owns
that kind of work (Andrzej: homelab and hosts; Szarik: Star Office UI and Mac-side work;
Florian: blog; Zdzisław: personal brand; Matejko: images; Claude Code: planning and reviews).
The run starts in a fresh session that never sees this chat, so the description carries:

- Wojtek's request, quoted verbatim;
- the context the run needs: links, findings so far, constraints;
- acceptance criteria the run can check;
- the line `Origin: Mattermost <channel name> (channel id <id>). Post the result there when done.`

Done when the API answer carries an `identifier` and you posted
`Handed to Paperclip as GUL-<n>: <link>. The result will be posted here.` in the chat.

The woken run works the issue with the `paperclip` skill, then posts a short result and the
GUL link to that Mattermost channel with `send_message`.

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
between terminal calls, so load the key inside every command, and keep it out of output:

```bash
PC_URL=$(sed -n 's/^PAPERCLIP_API_URL=//p' "$HERMES_HOME/.env" | tail -1)
PC_KEY=$(sed -n 's/^PAPERCLIP_API_KEY=//p' "$HERMES_HOME/.env" | tail -1)
curl -s "$PC_URL/api/agents/me" -H "Authorization: Bearer $PC_KEY" | jq '{id, name, companyId}'
```

Create an issue: write the description to a file first, so newlines survive.

```bash
PC_URL=$(sed -n 's/^PAPERCLIP_API_URL=//p' "$HERMES_HOME/.env" | tail -1)
PC_KEY=$(sed -n 's/^PAPERCLIP_API_KEY=//p' "$HERMES_HOME/.env" | tail -1)
jq -n --arg title "<title>" --rawfile description /tmp/gul-record.md \
  --arg assignee "<agent id>" --arg project "<project id>" --arg status "done" \
  '{title: $title, description: $description, status: $status, priority: "medium",
    assigneeAgentId: $assignee, projectId: $project}' \
| curl -s -X POST "$PC_URL/api/companies/0e2eb054-4cb6-4ea1-a2e7-2b1894285d8c/issues" \
    -H "Authorization: Bearer $PC_KEY" -H "Content-Type: application/json" --data @- \
| jq '{identifier, status, error}'
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
