# ADR-075: Paperclip org chart, agent runtimes and the "plan big, execute cheap" split

**Date:** 2026-10-20
**Status:** Accepted
**Deciders:** Wojtek Gula; implemented by Claude Code (H2-327)
**Project:** agent platform
**Related:** ADR-073 (Hermes on the Air), ADR-074 (Paperclip control plane), ADR-068 (Go fallback)

## Context

Paperclip (ADR-074) had one agent, Andrzej, wired to Hermes at `http://127.0.0.1:8642`. Two
problems and one goal:

- The Hermes API server picks the profile from the URL prefix `/p/<profile>/`; without it a
  request runs as `default`. Andrzej's Paperclip runs (GUL-1) were really Bill Cipher.
- Named profiles only accept their own `API_SERVER_KEY` and fail closed; none had one.
- The owner wants a real company: every Hermes agent registered with a role, more cheap
  engineers, and Claude Code as a planner rather than a typist. During the SOU work, tasks that
  were planned precisely were done well by DeepSeek Flash and Qwen Flash.

## Decision

1. **Org chart** (company "Gulasz101 Homelab", prefix GUL), heartbeats off (wake on assignment
   or comment), budgets 0 (flat-rate subscriptions):

   | Agent | Role | Reports to | Runtime |
   |---|---|---|---|
   | Bill Cipher | CEO | owner | `hermes_gateway` → `/` (profile `default`) |
   | Claude Code | PM (technical PM) | Bill | `claude_local` (CLI engine, Opus 5.5, effort xhigh) |
   | Andrzej | CTO | Bill | `hermes_gateway` → `/p/andrzej` |
   | Florian | CMO | Bill | `hermes_gateway` → `/p/florian` |
   | Zdzisław | Personal Brand Manager | Florian | `hermes_gateway` → `/p/zdzislaw` |
   | Szarik | Engineer (Star Office UI) | Andrzej | `hermes_gateway` → `/p/szarik` |
   | Pi | Engineer (coding, review) | Andrzej | `pi_local`, Pi 1.3, `llmhub/qwen3.8-flash-go`, thinking `max` |
   | OpenCode | Engineer (coding) | Andrzej | `opencode_local`, every llm-hub model, default `deepseek-v4.1-flash-go` |

2. **Per-profile Hermes keys.** Each named profile has its own `API_SERVER_KEY` in its `.env`;
   Paperclip stores each one as a `local_encrypted` secret and the agent's `apiBaseUrl` carries
   the profile prefix.
3. **One llm-hub key for the Paperclip coders** (`paperclip-coders`, same model list as
   `hermes-andrzej-key`), in `litellm-user-keys.sops.yaml` and the key provisioner so its model
   list stays current. On the Air it lives in `~/.config/llm-hub/paperclip-coders.key` (600);
   Pi (`!cat`) and OpenCode (`{file:...}`) read it from there, never inline.
4. **Pi `max` reasoning is mapped explicitly.** Pi clamps `xhigh`/`max` to `high` unless the
   model's `thinkingLevelMap` defines them; `qwen3.8-*-go` map `max → "max"`, which LiteLLM passes
   to Zen Go as `reasoning_effort`.
5. **docs-mcp is mandatory for every engineer and for Claude Code.** The `docs` MCP server
   (`http://192.168.1.179:6280/mcp`) is registered for Claude Code, Pi and OpenCode, and the
   upstream skills `docs-search`, `docs-manage`, `fetch-url` (arabold/docs-mcp-server) are
   installed once in `~/agent-skills/docs-mcp/` with a header pinning
   `--server-url http://192.168.1.179:6280/api`, then linked into each tool. Andrzej's SOUL rule
   7, trimmed to one line on 2026-10-17, was restored in full.
6. **OpenChamber stays in Itsaplan, not Paperclip.** It is resource-heavy; OpenCode on the Air
   covers the cheap-coder lane. While Itsaplan lives, Andrzej and Szarik can still delegate to its
   OpenChamber runners.
7. **Charters** for the non-Hermes agents live in `~/paperclip-agents/<agent>/AGENTS.md` on the
   Air (role plus house rules: docs first, SOPS, GitOps, no gateway restarts, verify).

## Consequences

- Paperclip work reaches the intended Hermes profile; GUL-2…6 smoke tests each reported their
  own profile.
- Planning happens once, with the expensive model; execution runs on flat-rate Go/Ollama models.
- `pi_local` and `opencode_local` require a git workspace: a project whose workspace is not a
  git repo (Agent Fleet → `~/.hermes`) blocks them. Give coders issues in git-backed projects.
- The Hermes adapter calls `/stop` when `timeoutSec` expires; long jobs need a longer timeout
  (Szarik: 36000 s).
- More config lives only on the Air (`~/.pi`, `~/.config/opencode`, `~/agent-skills`,
  `~/paperclip-agents`, symlinked skills). A host move must copy these and their symlink targets.
- Claude Code needs one interactive `claude` login on the Air before its Paperclip runs work.
- The `claude_local` adapter passes `--strict-mcp-config`, which hides user-scope MCP servers;
  Claude Code's `extraArgs` add `--mcp-config ~/paperclip-agents/claude-code/mcp-docs.json`
  (repeated `--mcp-config` flags accumulate).
- The Air and the Max talk both ways over LAN SSH (Air key `id_ed25519.paperclip-to-m1max`,
  alias `m1max`), so Air-hosted agents can use the Max's GPU (FLUX) and services.

## Alternatives considered

- **OpenChamber runners as Paperclip agents via an HTTP bridge**: rejected for now, too heavy
  for the gain; OpenCode on the Air uses the same engine and models.
- **Pi Durable**: experimental library with no official docs and no Paperclip adapter; revisit
  when it has both.
- **One shared Hermes key for every profile**: Hermes refuses it by design (named profiles fail
  closed), and it would let any profile act as another.

## When to revisit

- Itsaplan is drained: drop the OpenChamber delegation lane, move SOU/H2 work fully to Paperclip.
- Pi Durable or a Paperclip adapter for it ships.
- Paperclip's `pi_local` adapter catches up with Pi 1.x (it documents Pi 0.74 and `xhigh` as max).
- The Go subscription's weekly wall (ADR-068) starts blocking the coders: add an Ollama route
  as Pi's fallback.
