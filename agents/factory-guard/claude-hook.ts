/**
 * factory-guard for Claude Code agents (GUL-2037 phase 4: the Reviewer on Sonnet).
 *
 * A Claude Code PreToolUse hook. It holds no rules of its own: it maps the Claude
 * tool call onto the Pi tool names and asks the same policy.ts the Pi agents use.
 * Exit 2 blocks the call (Claude shows stderr to the model), exit 0 allows it.
 * Fail-closed: bad input, an unknown role or any exception blocks.
 *
 * Usage, in the agent's Claude settings file:
 *   {"hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command",
 *     "command": "node <dir>/claude-hook.ts readonly"}]}]}}
 */
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import { decideToolCallSafe, type RoleProfile, type RolesConfig } from "./policy.ts";

const HERE = path.dirname(fileURLToPath(import.meta.url));

function deny(reason: string): never {
  process.stderr.write(reason + "\n");
  process.exit(2);
}

function loadRole(name: string): RoleProfile | undefined {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(HERE, "roles.json"), "utf8")) as RolesConfig;
    return cfg.roles[name];
  } catch {
    return undefined;
  }
}

function gitRoot(cwd: string): string | null {
  const r = spawnSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], { encoding: "utf8" });
  return r.status === 0 ? r.stdout.trim() : null;
}

/** Claude tool name + input -> the Pi tool name + input that policy.ts knows. */
export function toPi(tool: string, input: Record<string, unknown>): [string, Record<string, unknown>] {
  const s = (k: string) => (typeof input[k] === "string" ? (input[k] as string) : "");
  switch (tool) {
    case "Bash":
      return ["bash", { command: input.command }];
    case "Write":
    case "Edit":
    case "MultiEdit":
      return ["write", { path: s("file_path") }];
    case "NotebookEdit":
      return ["write", { path: s("notebook_path") }];
    case "Read":
      return ["read", { path: s("file_path") }];
    case "Grep":
      return ["grep", { path: s("path"), pattern: s("pattern"), glob: s("glob") }];
    case "Glob":
      return ["find", { path: s("path"), pattern: s("pattern") }];
    case "LS":
      return ["ls", { path: s("path") }];
    default:
      return [tool, input];
  }
}

function main(): void {
  const roleName = process.argv[2] || process.env.FACTORY_ROLE || "";
  let event: Record<string, unknown>;
  try {
    event = JSON.parse(fs.readFileSync(0, "utf8"));
  } catch {
    deny("factory-guard: hook input is not JSON (malformed-input)");
  }
  const tool = typeof event.tool_name === "string" ? event.tool_name : "";
  const input = event.tool_input;
  if (!tool || input === null || typeof input !== "object" || Array.isArray(input)) {
    deny("factory-guard: hook input has no tool_name / tool_input (malformed-input)");
  }
  const cwd = typeof event.cwd === "string" && event.cwd ? event.cwd : process.cwd();
  const [piTool, piInput] = toPi(tool, input as Record<string, unknown>);
  const decision = decideToolCallSafe(loadRole(roleName), piTool, piInput,
    { cwd, workspaceRoot: gitRoot(cwd), turns: 0 }, os.homedir());
  if (decision) deny(decision.reason);
  process.exit(0);
}

try {
  main();
} catch {
  deny("factory-guard: guard could not decide (internal-error-fail-closed)");
}
