/**
 * factory-guard: the Pi extension every factory agent loads.
 *
 * Holds no rules of its own — all policy lives in policy.ts. This file only
 * wires Pi events to the policy, keeps run state (turns, repeat failures),
 * runs the diff guard at settle, snapshots protected files outside any repo,
 * and appends the block log. Fail-closed: any exception in the gate blocks.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  committedDiffBase,
  decideToolCallSafe,
  isProtectedPath,
  type GuardState,
  type RoleProfile,
  type RolesConfig,
  turnCapReason,
} from "./policy.ts";

const HOME = os.homedir();

/** Fallback if roles.json cannot be read — keep in sync with roles.json. */
const EMBEDDED_ROLES: RolesConfig = {
  roles: {
    executor: { turnCap: 60, writesOutsideWorkspace: true, writeScope: "all", allowCommit: true, allowPush: true },
    tester: { turnCap: 25, writesOutsideWorkspace: false, writeScope: "test-only", allowCommit: false, allowPush: false },
    builder: { turnCap: 40, writesOutsideWorkspace: false, writeScope: "no-tests", allowCommit: false, allowPush: false },
    readonly: { turnCap: 20, writesOutsideWorkspace: false, writeScope: "none", allowCommit: false, allowPush: false },
  },
};

function loadRoles(): RolesConfig {
  for (const candidate of rolesJsonCandidates()) {
    try {
      return JSON.parse(fs.readFileSync(candidate, "utf8")) as RolesConfig;
    } catch { /* try next */ }
  }
  return EMBEDDED_ROLES;
}

function rolesJsonCandidates(): string[] {
  const list: string[] = [];
  try { list.push(new URL("./roles.json", import.meta.url).pathname); } catch { /* no import.meta */ }
  const argvDir = process.argv[1] ? path.dirname(process.argv[1]) : "";
  if (argvDir) list.push(path.join(argvDir, "roles.json"));
  list.push(path.join(HOME, "paperclip-agents", "pi", "extensions", "factory-guard", "roles.json"));
  return list;
}

function blockLogPath(): string {
  if (process.env.FACTORY_GUARD_BLOCK_LOG) return process.env.FACTORY_GUARD_BLOCK_LOG;
  const agentDir = process.env.PI_CODING_AGENT_DIR || path.join(HOME, ".pi", "agent");
  return path.join(agentDir, "factory-guard", "blocks.jsonl");
}

function appendBlockLog(entry: { role: string; tool: string; rule: string; path?: string }): void {
  try {
    const p = blockLogPath();
    fs.mkdirSync(path.dirname(p), { recursive: true });
    // time, role, tool, rule id, path if any — never the command text or reason.
    fs.appendFileSync(p, JSON.stringify({ time: new Date().toISOString(), ...entry }) + "\n");
  } catch {
    /* the log must never break the session */
  }
}

function git(cwd: string, args: string[]): { ok: boolean; stdout: string } {
  const r = spawnSync("git", args, { cwd, encoding: "utf8", timeout: 15000 });
  return { ok: r.status === 0, stdout: r.stdout ?? "" };
}

function sha256(file: string): string | null {
  try {
    return createHash("sha256").update(fs.readFileSync(file)).digest("hex");
  } catch {
    return null;
  }
}

export default function (pi: ExtensionAPI): void {
  pi.registerFlag("factory-role", {
    description: "factory-guard role profile (executor|tester|builder|readonly)",
    type: "string",
  });

  const roles = loadRoles();

  const state = {
    turns: 0,
    workspaceRoot: null as string | null,
    workspaceRootCwd: "",
    lastFailedCommand: "",
    failedCount: 0,
    continuationAsked: false,
    snapshots: new Map<string, { sha: string; copy: string | null }>(),
    scratchDir: "",
    /** SHA of HEAD at session_start — the base for blaming this run (GUL-424). */
    headAtStart: null as string | null,
    /** committed-violation paths already logged this process (settle can fire twice). */
    committedLogged: new Set<string>(),
  };

  function roleProfile(): RoleProfile | undefined {
    const flag = pi.getFlag("factory-role");
    if (typeof flag !== "string") return undefined;
    return roles.roles[flag];
  }

  function roleName(): string {
    const flag = pi.getFlag("factory-role");
    return typeof flag === "string" && roles.roles[flag] ? flag : "none";
  }

  function guardState(cwd: string): GuardState {
    if (state.workspaceRootCwd !== cwd) {
      state.workspaceRootCwd = cwd;
      const r = git(cwd, ["rev-parse", "--show-toplevel"]);
      state.workspaceRoot = r.ok ? r.stdout.trim() : null;
    }
    return { cwd, workspaceRoot: state.workspaceRoot, turns: state.turns };
  }

  function scratchDir(): string {
    if (state.scratchDir) return state.scratchDir;
    const base = process.env.PAPERCLIP_RUN_SCRATCH_DIR || os.tmpdir();
    state.scratchDir = path.join(base, "factory-guard-snapshots", String(process.pid));
    fs.mkdirSync(state.scratchDir, { recursive: true });
    return state.scratchDir;
  }

  // ---------- session_start: reset run state, snapshot protected files outside any repo ----------

  pi.on("session_start", async (_event, ctx) => {
    state.turns = 0;
    state.lastFailedCommand = "";
    state.failedCount = 0;
    state.continuationAsked = false;
    state.snapshots.clear();
    state.committedLogged.clear();
    state.workspaceRootCwd = "";
    guardState(ctx.cwd);

    // GUL-424: remember where this run started. The committed-violation scan
    // at settle diffs from here, so a shared checkout that carries foreign
    // commits on its branch no longer blames the executor for them.
    state.headAtStart = null;
    if (state.workspaceRoot) {
      const h = git(state.workspaceRoot, ["rev-parse", "HEAD"]);
      const sha = h.ok ? h.stdout.trim() : "";
      if (/^[0-9a-f]{7,40}$/.test(sha)) state.headAtStart = sha;
    }

    const files: string[] = [];
    const agentDir = process.env.PI_CODING_AGENT_DIR || path.join(HOME, ".pi", "agent");
    for (const f of ["settings.json", "models.json", "AGENTS.md", "SOUL.md", "CLAUDE.md", "HEARTBEAT.md", "TOOLS.md"]) {
      files.push(path.join(agentDir, f));
    }
    try {
      for (const e of fs.readdirSync(path.join(agentDir, "extensions"), { withFileTypes: true })) {
        if (e.isFile()) files.push(path.join(agentDir, "extensions", e.name));
      }
    } catch { /* no extensions dir */ }
    try {
      const pcRoot = path.join(HOME, "paperclip-agents");
      for (const d of fs.readdirSync(pcRoot, { withFileTypes: true })) {
        if (!d.isDirectory()) continue;
        for (const f of ["AGENTS.md", "SOUL.md", "CLAUDE.md", "HEARTBEAT.md", "TOOLS.md"]) {
          files.push(path.join(pcRoot, d.name, f));
        }
      }
    } catch { /* no paperclip-agents */ }

    for (const file of files) {
      try {
        if (!fs.statSync(file).isFile()) continue;
        if (state.workspaceRoot && file.startsWith(state.workspaceRoot + path.sep)) continue; // the repo diff guard covers it
        const sha = sha256(file);
        if (!sha) continue;
        // Never store copies of files that may hold credentials — watch the hash only.
        const mayCopy = isProtectedPath(file, HOME)
          && !/^(settings\.json|models\.json|auth\.json|mcp-auth\.json)$/.test(path.basename(file));
        let copy: string | null = null;
        if (mayCopy) {
          copy = path.join(scratchDir(), sha.slice(0, 12) + "-" + path.basename(file));
          fs.copyFileSync(file, copy);
        }
        state.snapshots.set(file, { sha, copy });
      } catch { /* ignore unreadable */ }
    }
  });

  // ---------- tool_call: the gate ----------

  pi.on("tool_call", async (event, ctx) => {
    // decideToolCallSafe already fails closed; this try covers our own plumbing.
    try {
      const role = roleProfile();
      const gated = event.toolName === "write" || event.toolName === "edit"
        || event.toolName === "bash" || event.toolName === "powershell";

      if (role && gated && state.turns >= role.turnCap) {
        appendBlockLog({ role: roleName(), tool: event.toolName, rule: "turn-cap" });
        return { block: true, reason: turnCapReason(role.turnCap) };
      }

      if (role && event.toolName === "bash" && state.failedCount >= 2
        && typeof (event.input as { command?: unknown } | undefined)?.command === "string"
        && (event.input as { command: string }).command === state.lastFailedCommand) {
        appendBlockLog({ role: roleName(), tool: "bash", rule: "repeat-guard" });
        return {
          block: true,
          reason: "factory-guard: same failing command, nothing changed. Change something or stop.",
        };
      }

      const decision = decideToolCallSafe(role, event.toolName, event.input, guardState(ctx.cwd), HOME);
      if (decision) {
        const entry: { role: string; tool: string; rule: string; path?: string } = {
          role: roleName(), tool: event.toolName, rule: decision.ruleId,
        };
        const inp = event.input as Record<string, unknown> | undefined;
        if (inp && typeof inp.path === "string") entry.path = inp.path; // path only — never command text
        appendBlockLog(entry);
        return { block: true, reason: decision.reason };
      }
      return undefined;
    } catch {
      appendBlockLog({ role: roleName(), tool: event.toolName ?? "?", rule: "internal-error-fail-closed" });
      return { block: true, reason: "factory-guard: guard could not decide, failing closed" };
    }
  });

  // ---------- tool_result: repeat-guard memory ----------

  pi.on("tool_result", async (event) => {
    try {
      if (event.toolName === "bash" && event.isError) {
        const command = (event.input as { command?: unknown } | undefined)?.command;
        if (typeof command === "string") {
          if (command === state.lastFailedCommand) state.failedCount++;
          else { state.lastFailedCommand = command; state.failedCount = 1; }
        }
        return undefined;
      }
      if ((event.toolName === "write" || event.toolName === "edit") && !event.isError) {
        state.lastFailedCommand = "";
        state.failedCount = 0;
      }
    } catch { /* observation only */ }
    return undefined;
  });

  // ---------- turn_end: turn counting ----------

  pi.on("turn_end", async () => {
    state.turns++;
    return undefined;
  });

  // ---------- agent_before_settle: diff guard, once, then at most one continuation ----------

  pi.on("agent_before_settle", async (_event, ctx) => {
    const violations: string[] = [];
    let committedViolations: string[] = [];
    try {
      const role = roleProfile();
      const gs = guardState(ctx.cwd);
      const repoRoot = state.workspaceRoot;

      if (repoRoot) {
        // uncommitted changes + untracked files
        const st = git(repoRoot, ["status", "--porcelain", "--untracked-files=all"]);
        if (st.ok) {
          for (const line of st.stdout.split("\n")) {
            if (!line.trim()) continue;
            const xy = line.slice(0, 2);
            let rel = line.slice(3).trim();
            if (rel.includes(" -> ")) rel = rel.split(" -> ").pop()!.replace(/^"|"$/g, ""); // renames: judge the new path
            const abs = path.resolve(repoRoot, rel);
            const d = decideToolCallSafe(role, "write", { path: abs }, gs, HOME);
            if (!d) continue; // in scope
            if (xy === "??") {
              // quarantine untracked violation (never delete)
              const qdir = path.join(
                process.env.PAPERCLIP_RUN_SCRATCH_DIR || os.tmpdir(),
                "factory-guard-quarantine",
                String(process.pid),
              );
              fs.mkdirSync(qdir, { recursive: true });
              const dest = path.join(qdir, rel.replace(/[\/\\]/g, "__"));
              try { fs.renameSync(abs, dest); } catch { /* may already be gone */ }
              violations.push(`quarantined ${rel} -> ${dest}`);
              appendBlockLog({ role: roleName(), tool: "diff-guard", rule: "quarantine-" + d.ruleId, path: rel });
            } else {
              const r = git(repoRoot, ["restore", "--staged", "--worktree", "--", rel]);
              violations.push(`restored ${rel}${r.ok ? "" : " (restore FAILED)"}`);
              appendBlockLog({ role: roleName(), tool: "diff-guard", rule: "restore-" + d.ruleId, path: rel });
            }
          }
        }
        // Committed violations — blame THIS RUN, not the branch (GUL-424).
        // Base: HEAD at session_start (this run's commits only). No start SHA
        // (resumed session) -> old merge-base fallback. Start SHA present but
        // no longer an ancestor of HEAD -> the branch got switched under the
        // run: report nothing rather than re-flag foreign commits.
        let base = "";
        if (state.headAtStart) {
          const anc = git(repoRoot, ["merge-base", "--is-ancestor", state.headAtStart, "HEAD"]);
          base = committedDiffBase(state.headAtStart, anc.ok, null) ?? "";
        } else {
          let mb: string | null = null;
          for (const cand of ["origin/main", "main"]) {
            const r = git(repoRoot, ["merge-base", cand, "HEAD"]);
            if (r.ok && r.stdout.trim()) { mb = r.stdout.trim(); break; }
          }
          base = committedDiffBase(null, false, mb) ?? "";
        }
        if (base) {
          const ch = git(repoRoot, ["diff", "--name-only", `${base}..HEAD`]);
          if (ch.ok) {
            committedViolations = ch.stdout.split("\n").filter(Boolean).filter((rel) => {
              const abs = path.resolve(repoRoot, rel);
              return decideToolCallSafe(role, "write", { path: abs }, gs, HOME) !== undefined;
            });
            for (const rel of committedViolations) {
              // settle can fire twice (report + continuation): log each path once per run
              if (state.committedLogged.has(rel)) continue;
              state.committedLogged.add(rel);
              appendBlockLog({ role: roleName(), tool: "diff-guard", rule: "committed-violation", path: rel });
            }
          }
        }
      }

      // protected files outside any repo: restore from copy or report
      for (const [file, snap] of state.snapshots) {
        const now = sha256(file);
        if (now === snap.sha) continue;
        if (snap.copy && now !== null) {
          try {
            fs.copyFileSync(snap.copy, file);
            violations.push(`restored ${file}`);
            appendBlockLog({ role: roleName(), tool: "diff-guard", rule: "restore-outside-repo", path: file });
            continue;
          } catch { /* fall through to report */ }
        }
        violations.push(`CHANGED AND NOT RESTORABLE ${file}`);
        appendBlockLog({ role: roleName(), tool: "diff-guard", rule: "changed-no-copy", path: file });
      }
    } catch {
      appendBlockLog({ role: roleName(), tool: "diff-guard", rule: "diff-guard-error" });
    }

    if ((violations.length > 0 || committedViolations.length > 0) && !state.continuationAsked) {
      state.continuationAsked = true;
      const lines = [
        "factory-guard diff guard acted after your last turn:",
        ...violations.map((v) => `- ${v}`),
        ...committedViolations.map((v) => `- COMMITTED IN VIOLATION (not rewritten): ${v}`),
        "Put this exact list in your issue comment. If anything is listed as COMMITTED IN VIOLATION, end the comment with RESULT: guard-violation.",
      ].join("\n");
      return {
        entries: [
          {
            type: "custom_message" as const,
            customType: "factory-guard-violations",
            content: [{ type: "text" as const, text: lines }],
            display: true,
          },
        ],
        continue: true,
      };
    }
    return undefined;
  });
}
