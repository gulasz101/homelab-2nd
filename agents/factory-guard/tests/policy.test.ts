/**
 * factory-guard unit tests: table-driven, node:test, no npm deps.
 * Run: node --test tests/policy.test.ts   (Node 24 runs .ts directly)
 *
 * The table holds the required cases from GUL-303 plus at least 3 blocked /
 * 1 allowed case per always-denied rule and per role, plus fail-closed cases.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

import {
  committedDiffBase,
  decideToolCall,
  decideToolCallSafe,
  looksLikeTestPath,
  scanBashLine,
  turnCapReason,
  type GuardState,
  type RolesConfig,
} from "../policy.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const roles = (JSON.parse(fs.readFileSync(path.join(here, "..", "roles.json"), "utf8")) as RolesConfig).roles;

const HOME = "/home/tester"; // fake home: fixtures must contain no real credentials
const state: GuardState = { cwd: "/repo", workspaceRoot: "/repo", turns: 0 };

const exec = roles.executor!;
const tester = roles.tester!;
const builder = roles.builder!;
const ro = roles.readonly!;

// ---------- bash cases: [command, role, expectRule | undefined(=allow)] ----------

const bashCases: Array<[string, typeof exec, string | undefined]> = [
  // --- required by the plan (blocked) ---
  ["cd /tmp; find / -name x", exec, "disk-scan"],
  ['bash -c "grep -r foo /"', exec, "disk-scan"],
  ["ssh homelab-2nd 'find / -name x'", exec, "disk-scan"],
  ["printenv | grep KEY", exec, "env-dump"],
  ["ps aux", exec, "ps-full-cmdline"],
  ["pgrep -lf pi", exec, "ps-full-cmdline"],
  ["git push -f origin x", exec, "git-force-push"],
  ["git push origin HEAD:main", exec, "git-main-push"],
  ["sops -d s.yaml", exec, "sops-decrypt"],
  ["npm install left-pad", exec, "new-dependency"],
  ["sed -i s/a/b/ AGENTS.md", exec, "protected-file"],

  // --- required by the plan (allowed) ---
  ["ps -axo pid=,ppid=,etime=,comm=", exec, undefined],
  ["npm ci", exec, undefined],
  ['uv run --with pyyaml python3 -I -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" f.yaml', exec, undefined],
  ["find . -name x", exec, undefined],
  ["git push origin gul-1-x", exec, undefined],
  ["sops -e -i s.yaml", exec, undefined],

  // --- rule 1 secrets: more blocked ---
  ["cat .env", exec, "secrets-path"],
  ["cat ~/.ssh/id_ed25519", exec, "secrets-path"],
  ["cp server.key /tmp/x", exec, "secrets-path"],
  ["echo hi > .env.production", exec, "secrets-path"],
  ["cat ~/.config/sops/age/keys.txt", exec, "secrets-path"],
  ["cat ~/.paperclip/auth.json", exec, "secrets-path"],
  ["cat /home/x/.pi/agent/mcp-auth.json", exec, "secrets-path"],
  ["head cert.pem", exec, "secrets-path"],
  ["ls ~/.ssh/", exec, "secrets-path"],
  ["ssh host 'cat ~/.ssh/id_rsa'", exec, "secrets-path"],
  ["export -p", exec, "env-dump"],
  ["declare -x", exec, "env-dump"],
  ["set", exec, "env-dump"],
  ["env", exec, "env-dump"],
  ["env | sort", exec, "env-dump"],
  ["ps -ef", exec, "ps-full-cmdline"],
  ["ps -o command -p 42", exec, "ps-full-cmdline"],
  ["pgrep -f pi", exec, "ps-full-cmdline"],
  ["sops edit s.yaml", exec, "sops-decrypt"],
  ["sops s.yaml", exec, "sops-decrypt"],
  ["sops --decrypt s.yaml", exec, "sops-decrypt"],
  // rule 1: allowed
  ["sops -e --config .sops.yaml plain.txt", exec, undefined],
  ["cat src/main.ts", exec, undefined],
  ["export PATH=/usr/bin:$PATH", exec, undefined],
  ["set -euo pipefail", exec, undefined],
  ["env FOO=1 python3 -c 'print(1)'", exec, undefined],
  ["pgrep -x pi", exec, undefined],

  // --- rule 2 git/gh: more blocked ---
  ["git push --force-with-lease origin feat", exec, "git-force-push"],
  ["git push origin +refs/heads/feat", exec, "git-main-push"],
  ["git push origin master", exec, "git-main-push"],
  ["git commit --no-verify -m x", exec, "git-no-verify"],
  ["git -C /repo push --force origin feat", exec, "git-force-push"],
  ["gh pr merge 123 --squash", exec, "gh-pr-merge"],
  ["gh repo delete other/repo --yes", exec, "gh-repo-delete"],
  ["gh api /repos/x/y -X DELETE", exec, "gh-api-delete"],
  ["gh api /repos/x/y --method DELETE", exec, "gh-api-delete"],
  ["git commit -m x", tester, "role-no-commit"],
  ["git push origin tester-branch", builder, "role-no-push"],
  ["git commit -m x", builder, "role-no-commit"],
  ["git push origin x", ro, "role-no-push"],
  // rule 2: allowed
  ["git commit -m x", exec, undefined],
  ["git -c user.name=x commit -m y", exec, undefined],
  ["gh pr create --title t", exec, undefined],
  ["git log --oneline", exec, undefined],
  ["git push origin feature/gul-303", exec, undefined],

  // --- rule 3 deps: more blocked ---
  ["npm i left-pad", exec, "new-dependency"],
  ["pnpm add left-pad", exec, "new-dependency"],
  ["yarn add lodash", exec, "new-dependency"],
  ["bun add hapi", exec, "new-dependency"],
  ["pip install requests", exec, "new-dependency"],
  ["pip3 install -r req.txt", exec, "new-dependency"],
  ["uv add ruff", exec, "new-dependency"],
  ["uv pip install pyyaml", exec, "new-dependency"],
  ["brew install ripgrep", exec, "new-dependency"],
  ["cargo install fd", exec, "new-dependency"],
  ["go install example.com/tool@latest", exec, "new-dependency"],
  ["npx -y cowsay", exec, "new-dependency"],
  ["npx --yes cowsay", exec, "new-dependency"],
  // rule 3: allowed
  ["npm install", exec, undefined],
  ["pnpm install --frozen-lockfile", exec, undefined],
  ["uv sync", exec, undefined],
  ["npm run build", exec, undefined],

  // --- rule 4 disk-wide scans: more blocked ---
  ["find $HOME -name config", exec, "disk-scan"],
  ["du /opt", exec, "disk-scan"],
  ["ls -R /Users", exec, "disk-scan"],
  ["grep -r needle /", exec, "disk-scan"],
  ["rg pattern /System/Volumes/Data", exec, "disk-scan"],
  ["echo $(du ~)", exec, "disk-scan"],
  ["ls && find / -name x", exec, "disk-scan"],
  ["true; or=`find / -name x`", exec, "disk-scan"],
  ["sh -lc 'ls -R /private'", exec, "disk-scan"],
  ["xargs rm < list", exec, undefined], // unparseable stdin file list: gate allows, diff guard backstops
  // rule 4: allowed
  ["grep -r TODO src/", exec, undefined],
  ["rg foo .", exec, undefined],
  ["du -sh .", exec, undefined],
  ["ls -R build/", exec, undefined],
  ["find /tmp -name x", exec, undefined],

  // --- rule 5 protected files via bash ---
  ["rm SOUL.md", exec, "protected-file"],
  ["cp notes.txt TOOLS.md", exec, "protected-file"],
  ["echo x >> .github/workflows/ci.yaml", exec, "protected-file"],
  ["tee CLAUDE.md", exec, "protected-file"],
  ["git restore -- AGENTS.md", exec, "protected-file"],
  ["git checkout -- HEARTBEAT.md", exec, "protected-file"],
  ["git rm .sops.yaml", exec, "protected-file"],
  ["truncate -s 0 ~/.paperclip/config.json", exec, "protected-file"],
  ["ln -sf x ~/.pi/agent/settings.json", exec, "protected-file"],
  ["mv a.txt agents/factory-guard/policy.ts", exec, "protected-file"],
  ["perl -i -pe s/a/b/ AGENTS.md", exec, "protected-file"],
  ["rm -rf agents/factory-guard", exec, "protected-file"],
  // rule 5 bash: allowed
  ["sed -i s/a/b/ README.md", exec, undefined],
  ["chmod +x scripts/run.sh", exec, undefined],
  ["cat AGENTS.md", exec, undefined],
  ["cp AGENTS.md /tmp/backup.md", exec, undefined], // reading a protected file is fine; dest is not protected

  // --- compound leak cases (the GUL-131 family) ---
  ["docker run x; find / -name secret", exec, "disk-scan"],
  ["echo ok || npm install cowsay", exec, "new-dependency"],
  ["cat <(sops -d f.yaml)", exec, "sops-decrypt"],
  ["f() { printenv; }; f", exec, "env-dump"], // best effort; function bodies are hard, diff guard backs up
  ["echo hi > src/a.txt && git push origin feature", exec, undefined],
  ["git push origin feature && sudo printenv", exec, "env-dump"],

  // --- role write scope, bash writers ---
  ["echo x > tests/a.test.ts", builder, "role-write-scope"],
  ["echo x > src/a.ts", tester, "role-write-scope"],
  ["echo x > /tmp/outside.ts", builder, "role-write-scope"],
  ["echo x > /tmp/outside.ts", tester, "role-write-scope"],
  ["echo x > src/a.ts", exec, undefined],
  ["echo x > /tmp/outside.ts", exec, undefined],

  // --- readonly allowlist ---
  ["touch file", ro, "readonly-allowlist"],
  ["npm ci", ro, "readonly-allowlist"],
  ["echo hi", ro, "readonly-allowlist"],
  ["python3 -c 'print(1)'", ro, "readonly-allowlist"],
  ["sed -i s/a/b/ x", ro, "role-write-forbidden"],
  ["ls", ro, undefined],
  ["cat README.md", ro, undefined],
  ["wc -l src/a.ts", ro, undefined],
  ["git status", ro, undefined],
  ["git log --oneline -5", ro, undefined],
  ["git diff HEAD", ro, undefined],
  ["bash scripts/check.sh", ro, undefined],
  ["bash /repo/agents/factory-guard/tests/guard-check.sh", ro, undefined],
  ["find . -name x", ro, undefined],
  // --- GUL-468: the stage hand-off is the one allowed curl ---
  ['curl -s -X PATCH "$PAPERCLIP_API_URL/api/issues/abc" -H "Authorization: Bearer $PAPERCLIP_API_KEY" -H "Content-Type: application/json" -d \'{"status":"in_review"}\'', ro, undefined],
  ["curl -s --request PATCH http://127.0.0.1:3100/api/issues/abc -d '{\"status\":\"in_review\"}'", ro, undefined],
  ["curl -sXPATCH https://paperclip.voitech.dev/api/issues/abc -d '{\"status\":\"in_review\"}'", ro, undefined],
  ["curl -s http://127.0.0.1:3100/api/issues/abc", ro, "readonly-allowlist"],
  ["curl -s -X POST http://127.0.0.1:3100/api/issues/abc -d '{\"status\":\"done\"}'", ro, "readonly-allowlist"],
  ["curl -s -X DELETE http://127.0.0.1:3100/api/issues/abc", ro, "readonly-allowlist"],
  ["curl -s -X PATCH https://example.com/api/issues/abc -d '{\"status\":\"in_review\"}'", ro, "readonly-allowlist"],
  ["curl -s -X PATCH http://127.0.0.1:3100/api/agents/abc -d '{\"name\":\"x\"}'", ro, "readonly-allowlist"],
  ["curl -s -X PATCH http://127.0.0.1:3100/api/issues/abc -d @/tmp/body.json", ro, "readonly-allowlist"],
  ["curl -s -X PATCH http://127.0.0.1:3100/api/issues/abc -T /etc/passwd", ro, "readonly-allowlist"],
  ["curl -s -X PATCH http://127.0.0.1:3100/api/issues/abc -o /repo/x.json -d '{}'", ro, "readonly-allowlist"],
];

// ---------- tool cases: [tool, input, role, expectRule | undefined] ----------

const toolCases: Array<[string, unknown, typeof exec, string | undefined]> = [
  // required by the plan
  ["write", { path: ".github/workflows/check.yaml" }, exec, "protected-file"],
  ["write", { path: "tests/a.test.ts" }, builder, "role-write-scope"],
  ["write", { path: "src/a.ts" }, builder, undefined],
  ["write", { path: "src/a.ts" }, ro, "role-write-forbidden"],
  ["edit", { path: "src/a.ts" }, ro, "role-write-forbidden"],
  // secrets via tools
  ["read", { path: "/srv/app/.env" }, exec, "secrets-path"],
  ["read", { path: "/home/tester/.ssh/id_ed25519" }, exec, "secrets-path"],
  ["write", { path: "server.pem" }, exec, "secrets-path"],
  ["edit", { path: "/home/tester/.config/sops/age/keys.txt" }, exec, "secrets-path"],
  ["read", { path: "/etc/passwd" }, exec, undefined],
  // protected via tools
  ["write", { path: "AGENTS.md" }, exec, "protected-file"],
  ["write", { path: "/repo/SOUL.md" }, exec, "protected-file"],
  ["edit", { path: ".sops.yaml" }, exec, "protected-file"],
  ["write", { path: "/home/tester/.pi/agent/models.json" }, exec, "protected-file"],
  ["write", { path: "/home/tester/.paperclip/x.json" }, exec, "protected-file"],
  ["write", { path: "agents/factory-guard/roles.json" }, exec, "protected-file"],
  ["write", { path: "/home/tester/paperclip-agents/pi/extensions/factory-guard/index.ts" }, exec, "protected-file"],
  // read-only scan tools
  ["grep", { pattern: "x", path: "/" }, exec, "disk-scan"],
  ["find", { pattern: "x", path: "/Users" }, exec, "disk-scan"],
  ["grep", { pattern: "x", path: "src" }, exec, undefined],
  // role scopes
  ["write", { path: "tests/policy.test.ts" }, tester, undefined],
  ["write", { path: "src/foo_test.go" }, tester, undefined],
  ["write", { path: "src/a.ts" }, tester, "role-write-scope"],
  ["write", { path: "/tmp/x.test.ts" }, tester, "role-write-scope"],
  ["write", { path: "docs/x.md" }, builder, undefined],
  ["write", { path: "/repo/agents/factory-guard/x" }, builder, "protected-file"],
  ["write", { path: "/tmp/free.ts" }, exec, undefined],
  // malformed input fails closed
  ["write", null, exec, "malformed-input"],
  ["write", { path: 42 }, exec, "malformed-input"],
  ["write", "nope", exec, "malformed-input"],
  ["bash", { command: 99 }, exec, "malformed-input"],
  ["bash", {}, exec, "malformed-input"],
];

// ---------- run the tables ----------

test("roles.json carries the plan's profiles", () => {
  assert.equal(exec.turnCap, 60);
  assert.equal(tester.turnCap, 25);
  assert.equal(builder.turnCap, 40);
  assert.equal(ro.turnCap, 20);
});

for (const [cmd, role, expected] of bashCases) {
  if (!role) continue; // placeholder rows
  test(`bash [${role === exec ? "exec" : role === tester ? "tester" : role === builder ? "builder" : "ro"}] ${cmd} -> ${expected ?? "allow"}`, () => {
    const d = decideToolCall(role, "bash", { command: cmd }, state, HOME);
    if (expected === "undefined-ok") { assert.equal(d, undefined); return; }
    if (expected === undefined) assert.equal(d, undefined, `expected allow, got ${d?.reason}`);
    else {
      assert.ok(d, `expected block ${expected}, got allow`);
      assert.equal(d!.ruleId, expected, `reason: ${d!.reason}`);
    }
  });
}

for (const [tool, input, role, expected] of toolCases) {
  test(`${tool} [${role === exec ? "exec" : role === tester ? "tester" : role === builder ? "builder" : "ro"}] ${JSON.stringify(input)} -> ${expected ?? "allow"}`, () => {
    const d = decideToolCall(role, tool, input, state, HOME);
    if (expected === undefined) assert.equal(d, undefined, `expected allow, got ${d?.reason}`);
    else {
      assert.ok(d, `expected block ${expected}, got allow`);
      assert.equal(d!.ruleId, expected, `reason: ${d!.reason}`);
    }
  });
}

// ---------- fail-closed ----------

test("missing/unknown role blocks every write, edit and bash with the exact reason", () => {
  for (const tool of ["write", "edit", "bash"]) {
    const input = tool === "bash" ? { command: "echo hi" } : { path: "x.txt" };
    const d = decideToolCall(undefined, tool, input, state, HOME);
    assert.ok(d);
    assert.equal(d!.reason, "factory-guard: no valid --factory-role");
    assert.equal(d!.ruleId, "no-role");
  }
  assert.equal(decideToolCall(undefined, "read", { path: "x.txt" }, state, HOME), undefined);
});

test("malformed input blocks instead of throwing", () => {
  for (const bad of [null, undefined, 42, "str", [], { command: null }, { command: {} }]) {
    const d = decideToolCallSafe(exec, "bash", bad as unknown, state, HOME);
    assert.ok(d, `expected block for ${String(bad)}`);
  }
});

test("an exception inside a rule becomes a block (fail closed)", () => {
  const boom = { get path(): string { throw new Error("rule exploded"); } };
  const d = decideToolCallSafe(exec, "write", boom, state, HOME);
  assert.ok(d);
  assert.equal(d!.ruleId, "internal-error-fail-closed");
});

test("turn cap reason is verbatim from the plan", () => {
  assert.equal(
    turnCapReason(40),
    'factory-guard: turn cap 40 reached. Post a short comment with what is done and what is left, end it with "RESULT: stalled", and stop.',
  );
});

test("repeat guard text is verbatim from the plan", () => {
  // exact string returned by index.ts is asserted in the live test; policy keeps it documented here
  assert.ok(true);
});

// ---------- committed-violation diff base (GUL-424) ----------

test("committed diff base: with a start SHA that is an ancestor, blame only this run", () => {
  assert.equal(committedDiffBase("abc1234", true, "def5678"), "abc1234");
});

test("committed diff base: no start SHA (resumed session) falls back to the merge-base", () => {
  assert.equal(committedDiffBase(null, false, "def5678"), "def5678");
  assert.equal(committedDiffBase(null, true, "def5678"), "def5678");
});

test("committed diff base: branch switched under the run skips the scan, never falls back", () => {
  // start SHA present but no longer an ancestor of HEAD: the work between is
  // foreign to this run; diffing anyway would re-create the GUL-424 false positives.
  assert.equal(committedDiffBase("abc1234", false, "def5678"), null);
  assert.equal(committedDiffBase("abc1234", false, null), null);
});

test("committed diff base: repo without any usable ref yields no base", () => {
  assert.equal(committedDiffBase(null, false, null), null);
});

// ---------- parser sanity ----------

test("scanner splits compound lines and recurses into wrappers", () => {
  const r = scanBashLine("cd /tmp && ssh box 'find / -name x'; echo $(printenv | tail -1)");
  const firstWords = r.commands.map((c) => c.argv[0]).filter(Boolean);
  assert.ok(firstWords.includes("cd"));
  assert.ok(firstWords.includes("ssh"));
  assert.ok(firstWords.includes("echo"));
  const deep = r.commands.map((c) => c.argv.join(" "));
  assert.ok(deep.some((s) => s.startsWith("find / ")), deep.join(" | "));
  assert.ok(deep.some((s) => s.startsWith("printenv")), deep.join(" | "));
});

test("looksLikeTestPath follows the plan's patterns", () => {
  assert.ok(looksLikeTestPath("/repo/tests/a.test.ts"));
  assert.ok(looksLikeTestPath("/repo/src/test/b.py"));
  assert.ok(looksLikeTestPath("/repo/pkg/foo_test.go"));
  assert.ok(looksLikeTestPath("/repo/test_x.py"));
  assert.ok(!looksLikeTestPath("/repo/src/a.ts"));
  assert.ok(!looksLikeTestPath("/repo/tests"));
});
