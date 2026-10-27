/**
 * factory-guard policy: pure decision functions, no Pi imports.
 *
 * Everything the guard knows lives here so it can be unit-tested with
 * `node --test tests/policy.test.ts`. index.ts only wires Pi events to
 * these functions and handles side effects (git, logging, snapshots).
 *
 * Fail-closed is a rule, not a hope: malformed input, unknown role and any
 * throw inside a rule must end up as a block. Callers use decideToolCallSafe,
 * which turns exceptions into blocks.
 */

// ---------- types ----------

export interface RoleProfile {
  /** Turn cap for the role; counted per Pi process (per Paperclip wake). */
  turnCap: number;
  /** May write outside the workspace repo (only executor). */
  writesOutsideWorkspace: boolean;
  /** all | test-only | no-tests | none */
  writeScope: "all" | "test-only" | "no-tests" | "none";
  allowCommit: boolean;
  allowPush: boolean;
}

export interface RolesConfig {
  roles: Record<string, RoleProfile>;
}

export interface GuardState {
  /** Working directory of the Pi session. */
  cwd: string;
  /** Git top-level of cwd, or null when cwd is not in a repo. */
  workspaceRoot: string | null;
  /** Turns counted so far (turn_end events). */
  turns: number;
}

export interface BlockDecision {
  block: true;
  reason: string;
  ruleId: string;
}

export type Decision = BlockDecision | undefined;

function block(ruleId: string, what: string): BlockDecision {
  return {
    block: true,
    reason: `factory-guard: ${what} (${ruleId})`,
    ruleId,
  };
}

// ---------- constants ----------

const WRITE_TOOLS = new Set(["write", "edit"]);
const BASH_TOOLS = new Set(["bash", "powershell"]);
const READ_TOOLS = new Set(["read"]);
const SEARCH_TOOLS = new Set(["grep", "find", "ls", "fd"]);

/** Rule 1: secrets — ssh key basename prefixes. */
const SECRET_BASENAME_PREFIXES = ["id_ed25519", "id_rsa"];
const PROTECTED_MD_NAMES = new Set([
  "AGENTS.md",
  "SOUL.md",
  "CLAUDE.md",
  "HEARTBEAT.md",
  "TOOLS.md",
]);

/** Rule 4: disk-wide scan roots — same list as today's shellCommandPrefix. */
const SCAN_ROOTS = [
  "/",
  "/System",
  "/System/Volumes/Data",
  "/Users",
  "/Volumes",
  "/private",
  "/opt",
  "/Library",
];

/** Rule 5: bash writer commands that create/modify/remove files (besides `>`). */
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh", "/bin/bash", "/bin/sh", "/usr/bin/bash"]);

const ROLE_NO_REASON = "factory-guard: no valid --factory-role";

// ---------- path helpers ----------

function baseName(p: string): string {
  const parts = p.split(/[\\/]/).filter((s) => s.length > 0);
  return parts.length > 0 ? parts[parts.length - 1] : p;
}

function pathSegments(p: string): string[] {
  return p.split(/[\\/]/).filter((s) => s.length > 0);
}

/** Expand a leading ~ / $HOME to home for comparison; other $vars are left as-is. */
function expandHome(p: string, home: string): string {
  if (p === "~" || p === "$HOME" || p === "${HOME}") return home;
  if (p.startsWith("~/")) return home + p.slice(1);
  if (p.startsWith("$HOME/")) return home + p.slice("$HOME".length);
  if (p.startsWith("${HOME}/")) return home + p.slice("${HOME}".length);
  return p;
}

function isSecretPath(raw: string, home: string): boolean {
  const p = expandHome(raw, home);
  const base = baseName(p);
  if (base === ".env" || base.startsWith(".env.")) return true;
  if (base.endsWith(".pem") || base.endsWith(".key")) return true;
  if (SECRET_BASENAME_PREFIXES.some((pre) => base.startsWith(pre))) return true;
  const segs = pathSegments(p);
  if (segs.includes(".ssh")) return true;
  // age key files: ~/.config/sops/age/**, house keys named age-*, *.age-key.*
  if (/[\/]age[\/]/.test(p)) return true;
  if (/^age[-._]/.test(base)) return true;
  if (/age[-._].*key|.*[-._]age[-._]key/i.test(base)) return true;
  if (base === "auth.json" && (p.includes(".paperclip/") || segs.includes("agent"))) return true;
  if (base === "mcp-auth.json") return true;
  return false;
}

/** Rule 5: protected file targets, for write/edit tools and bash writers. */
export function isProtectedPath(raw: string, home: string): boolean {
  const p = expandHome(raw, home);
  const base = baseName(p);
  if (PROTECTED_MD_NAMES.has(base)) return true;
  if (base === ".sops.yaml" || base === ".sops.yml") return true;
  const segs = pathSegments(p);
  // .github/workflows/**
  for (let i = 0; i + 1 < segs.length; i++) {
    if (segs[i] === ".github" && segs[i + 1] === "workflows") return true;
  }
  // agents/factory-guard/** in any checkout, and the installed extensions copy
  for (let i = 0; i + 1 < segs.length; i++) {
    if (segs[i] === "agents" && segs[i + 1] === "factory-guard") return true;
  }
  for (let i = 0; i + 1 < segs.length; i++) {
    if (segs[i] === "extensions" && segs[i + 1] === "factory-guard") return true;
  }
  // ~/.pi/agent/settings.json | models.json | extensions/**
  if (segs.length >= 3 && segs[segs.length - 3] === ".pi" && segs[segs.length - 2] === "agent") {
    if (base === "settings.json" || base === "models.json") return true;
    if (segs.includes("extensions")) return true;
  }
  if (segs.includes(".pi") && segs.includes("agent") && PROTECTED_MD_NAMES.has(base)) return true;
  // ~/.paperclip/**
  if (segs.includes(".paperclip")) return true;
  return false;
}

function withinRoot(resolved: string, root: string | null): boolean {
  if (!root) return false;
  if (resolved === root) return true;
  return resolved.startsWith(root.endsWith("/") ? root : root + "/");
}

function resolveToolPath(p: string, state: GuardState, home: string): string {
  const exp = expandHome(p, home);
  if (exp.startsWith("/")) return exp;
  return (state.cwd.replace(/\/+$/, "") || "") + "/" + exp;
}

// ---------- test-path classification ----------

export function looksLikeTestPath(p: string): boolean {
  const segs = pathSegments(p).map((s) => s.toLowerCase());
  const idx = segs.lastIndexOf("tests");
  if (idx !== -1 && idx < segs.length - 1) return true;
  const idx2 = segs.lastIndexOf("test");
  if (idx2 !== -1 && idx2 < segs.length - 1) return true;
  const base = segs[segs.length - 1] ?? "";
  if (/\.test\.[a-z0-9]+$/.test(base)) return true;
  if (/_test\.[a-z0-9]+$/.test(base)) return true;
  if (/^test_.*\.py$/.test(base)) return true;
  return false;
}

// ---------- write-scope decision (shared by tools and bash writers) ----------

function decideWritePath(
  role: RoleProfile,
  rawPath: string,
  state: GuardState,
  home: string,
): Decision {
  const p = expandHome(rawPath, home);
  if (isProtectedPath(p, home)) return block("protected-file", `protected path ${p}`);
  if (isSecretPath(p, home)) return block("secrets-path", `secret path ${p}`);
  const resolved = resolveToolPath(p, state, home);
  const inRepo = withinRoot(resolved, state.workspaceRoot);
  switch (role.writeScope) {
    case "none":
      return block("role-write-forbidden", `readonly role forbids writes: ${p}`);
    case "test-only":
      if (!inRepo) return block("role-write-scope", `outside workspace repo: ${p}`);
      if (!looksLikeTestPath(resolved)) return block("role-write-scope", `not a test path: ${p}`);
      return undefined;
    case "no-tests":
      if (!inRepo) return block("role-write-scope", `outside workspace repo: ${p}`);
      if (looksLikeTestPath(resolved)) return block("role-write-scope", `test path denied for builder: ${p}`);
      return undefined;
    case "all":
      if (!inRepo && !role.writesOutsideWorkspace) {
        return block("role-write-scope", `outside workspace repo: ${p}`);
      }
      return undefined;
  }
}

function decideWritePathMaybeNoRole(
  role: RoleProfile | undefined,
  rawPath: string,
  state: GuardState,
  home: string,
): Decision {
  if (!role) return { block: true, reason: ROLE_NO_REASON, ruleId: "no-role" };
  return decideWritePath(role, rawPath, state, home);
}

// ---------- bash parsing ----------

/**
 * A parsed simple command: argv with quotes removed plus the paths it
 * redirects to. Recursed wrappers contribute their own SimpleCommands.
 */
interface SimpleCommand {
  argv: string[];
  /** Targets of `>`, `>>` redirects in this segment. */
  writeTargets: string[];
}

interface ScanResult {
  commands: SimpleCommand[];
  /** Words from every command including stripped prefixes (for secret scanning). */
  allWords: string[];
}

/**
 * Tokenize bash text honoring quotes, escapes, $() (recursed), backticks
 * (recursed) and heredocs (body skipped). Splits on ; && || | & and newlines.
 * Deliberately imperfect — the diff guard is the backstop for what this misses.
 */
export function scanBashLine(text: string, depth = 0): ScanResult {
  const out: ScanResult = { commands: [], allWords: [] };
  if (depth > 6 || typeof text !== "string") return out; // runaway nesting or garbage: stop parsing

  const segments: Array<{ words: string[]; redirs: string[] }> = [];
  let currentWords: string[] = [];
  let currentRedirs: string[] = [];
  let word = "";
  let wordHasContent = false;
  const substitutions: string[] = [];
  let pendingRedirect: "write" | "append" | "ignore" | null = null;

  const flushWord = () => {
    if (!wordHasContent) return;
    if (pendingRedirect === "write" || pendingRedirect === "append") {
      if (!(/^[0-9]+>&/.test(word) || word === "&1" || word === "&2")) {
        currentRedirs.push(word);
      }
      pendingRedirect = null;
    } else {
      currentWords.push(word);
    }
    word = "";
    wordHasContent = false;
  };
  const flushSegment = () => {
    flushWord();
    if (currentWords.length > 0 || currentRedirs.length > 0) {
      segments.push({ words: currentWords, redirs: currentRedirs });
    }
    currentWords = [];
    currentRedirs = [];
  };

  let i = 0;
  const n = text.length;
  while (i < n) {
    const c = text[i];

    if (c === "\\" && text[i + 1] === "\n") { i += 2; continue; }
    if (c === "\\" && i + 1 < n) { word += text[i + 1]; wordHasContent = true; i += 2; continue; }

    if (c === "'") {
      let j = i + 1; let inner = "";
      while (j < n && text[j] !== "'") { inner += text[j]; j++; }
      word += inner; wordHasContent = true; i = j + 1; continue;
    }
    if (c === '"') {
      let j = i + 1; let inner = "";
      while (j < n && text[j] !== '"') {
        if (text[j] === "\\" && j + 1 < n) { inner += text[j + 1]; j += 2; continue; }
        if (text[j] === "$" && text[j + 1] === "(") {
          const [content, end] = readParens(text, j + 1);
          substitutions.push(content); j = end; continue;
        }
        if (text[j] === "`") {
          const [content, end] = readBacktick(text, j);
          substitutions.push(content); j = end; continue;
        }
        inner += text[j]; j++;
      }
      word += inner; wordHasContent = true; i = j + 1; continue;
    }
    if (c === "`") {
      const [content, end] = readBacktick(text, i);
      substitutions.push(content); i = end; continue;
    }
    if (c === "$" && text[i + 1] === "(") {
      const [content, end] = readParens(text, i + 1);
      substitutions.push(content); i = end; continue;
    }
    if (c === "(") {
      // subshell `( cmd )` and process substitution `<( cmd )` — the '<' was consumed
      // as an input redirect marker, the parens body still needs recursion
      flushWord();
      const [content, end] = readParens(text, i);
      substitutions.push(content); i = end; continue;
    }
    if (c === "$" && text[i + 1] === "{") {
      let j = i + 2; let inner = "";
      while (j < n && text[j] !== "}") { inner += text[j]; j++; }
      word += "${" + inner + "}"; wordHasContent = true; i = j + 1; continue;
    }

    if (c === "\n" || c === ";") { flushSegment(); i++; continue; }
    if (c === "|" && text[i + 1] === "|") { flushSegment(); i += 2; continue; }
    if (c === "&" && text[i + 1] === "&") { flushSegment(); i += 2; continue; }
    if (c === "|") { flushSegment(); i++; continue; }
    if (c === "&") { flushSegment(); i++; continue; }

    if (c === ">") {
      flushWord();
      pendingRedirect = text[i + 1] === ">" ? "append" : "write";
      i += text[i + 1] === ">" ? 2 : 1;
      // fd-dup forms attached to the operator: `2>&1`, `>&2`
      const nxt = text[i] ?? "";
      if (nxt === "&" || /[0-9]/.test(nxt) && text.slice(i).match(/^[0-9]*>&/) !== null) {
        let k = i; let dup = "";
        while (k < n && !/\s/.test(text[k])) { dup += text[k]; k++; }
        pendingRedirect = null;
        i = k;
      }
      continue;
    }
    if (c === "<") {
      flushWord();
      if (text[i + 1] === "<") {
        let k = i + 2;
        if (text[k] === "-") k++;
        if (text[k] === "<") { // <<< here-string: skip the value token
          while (k < n && /\s/.test(text[k])) k++;
          while (k < n && !/\s/.test(text[k])) k++;
          i = k; continue;
        }
        let delim = "";
        while (k < n && !/[\s;|&]/.test(text[k])) { delim += text[k]; k++; }
        delim = delim.replace(/^['"]|['"]$/g, "");
        if (delim) {
          const lineStart = text.indexOf("\n", k);
          if (lineStart === -1) { i = n; continue; }
          const rest = text.slice(lineStart + 1);
          const lines = rest.split("\n");
          let consumed = 0;
          for (const line of lines) { consumed++; if (line.trimEnd() === delim) break; }
          const skipped = lines.slice(0, consumed).join("\n");
          i = lineStart + 1 + skipped.length + (consumed < lines.length ? 1 : 0);
          continue;
        }
      } else {
        pendingRedirect = "ignore"; // input redirect reads; secrets rule catches paths
        i++;
      }
      continue;
    }

    if (/\s/.test(c)) { flushWord(); i++; continue; }

    word += c; wordHasContent = true; i++;
  }
  flushSegment();

  for (const seg of segments) {
    out.commands.push(normalizeSegment(seg.words, seg.redirs, out));
  }

  // Recurse into command substitutions.
  for (const sub of substitutions) {
    mergeScan(out, scanBashLine(sub, depth + 1));
  }
  // Recurse into the tails of wrapper commands (bash -c, ssh remote, xargs, eval).
  for (const cmd of out.commands.slice()) {
    for (const wtext of unwrapCommands(cmd.argv)) {
      mergeScan(out, scanBashLine(wtext, depth + 1));
    }
  }

  for (const cmd of out.commands) {
    for (const w of cmd.argv) out.allWords.push(w);
    for (const t of cmd.writeTargets) out.allWords.push(t);
  }
  return out;
}

function mergeScan(into: ScanResult, other: ScanResult): void {
  into.commands.push(...other.commands);
  into.allWords.push(...other.allWords);
}

function readParens(text: string, parenIdx: number): [string, number] {
  // text[parenIdx] === '(' — returns the inner content and the index after the close
  let depth = 0; let j = parenIdx; let content = "";
  let inS = false; let inD = false;
  for (; j < text.length; j++) {
    const c = text[j];
    if (inS) { if (c === "'") inS = false; content += c; continue; }
    if (inD) {
      if (c === "\\" && j + 1 < text.length) { content += c + text[j + 1]; j++; continue; }
      if (c === '"') inD = false;
      content += c; continue;
    }
    if (c === "'") { inS = true; content += c; continue; }
    if (c === '"') { inD = true; content += c; continue; }
    if (c === "\\") { content += c + (text[j + 1] ?? ""); j++; continue; }
    if (c === "(") { depth++; if (depth === 1) continue; content += c; continue; }
    if (c === ")") { depth--; if (depth === 0) { j++; break; } content += c; continue; }
    content += c;
  }
  return [content, j];
}

function readBacktick(text: string, start: number): [string, number] {
  let j = start + 1; let content = "";
  while (j < text.length && text[j] !== "`") {
    if (text[j] === "\\") { content += text[j + 1] ?? ""; j += 2; continue; }
    content += text[j]; j++;
  }
  return [content, Math.min(j + 1, text.length)];
}

const PREFIX_CMDS = new Set(["sudo", "command", "nohup", "time", "nice", "ionice", "stdbuf"]);

/** Strip env assignments and known prefixes; attach segment redirect targets. */
function normalizeSegment(argv: string[], redirs: string[], out: ScanResult): SimpleCommand {
  const writeTargets = redirs.slice();
  let k = 0;
  while (k < argv.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(argv[k])) {
    out.allWords.push(argv[k]); // assignment values can name paths; scan them too
    k++;
  }
  while (k < argv.length) {
    const c0 = baseName(argv[k]);
    if (PREFIX_CMDS.has(c0)) { k++; continue; }
    if (c0 === "env") {
      const save = k;
      k++;
      while (k < argv.length && (argv[k].startsWith("-") || /^[A-Za-z_][A-Za-z0-9_]*=/.test(argv[k]))) {
        if (["-S", "--split-string", "-u", "--unset"].includes(argv[k])) { k += 2; continue; }
        k++;
      }
      if (k >= argv.length) { k = save; break; } // `env` alone: keep it visible to the env-dump rule
      continue;
    }
    if (c0 === "timeout") {
      k++;
      while (k < argv.length && argv[k].startsWith("-")) {
        if (["-s", "--signal", "-k", "--kill-after"].includes(argv[k])) { k += 2; continue; }
        k++;
      }
      if (k < argv.length && /^[0-9.]+[smhd]?$/.test(argv[k])) k++; // duration
      continue;
    }
    break;
  }
  return { argv: argv.slice(k), writeTargets };
}

/** Find embedded command strings in wrapper commands (bash -c, ssh host '...', xargs, eval). */
function unwrapCommands(argv: string[]): string[] {
  const found: string[] = [];
  if (argv.length === 0) return found;
  const c0 = baseName(argv[0]);
  if (SHELLS.has(c0)) {
    for (let i = 1; i < argv.length; i++) {
      const a = argv[i];
      if (a === "-c" || (a.startsWith("-") && !a.startsWith("--") && a.endsWith("c") && a.length <= 3)) {
        if (argv[i + 1]) { found.push(argv[i + 1]); break; }
      }
    }
  } else if (c0 === "sshpass") {
    const sidx = argv.findIndex((a) => baseName(a) === "ssh");
    if (sidx !== -1) return unwrapCommands(argv.slice(sidx));
  } else if (c0 === "ssh") {
    const VALUE_OPTS = new Set(["-p", "-i", "-l", "-o", "-F", "-b", "-c", "-D", "-L", "-R", "-e", "-J", "-m", "-w"]);
    let j = 1; let sawHost = false; const remote: string[] = [];
    for (; j < argv.length; j++) {
      const a = argv[j];
      if (!sawHost) {
        if (a.startsWith("-")) {
          if (VALUE_OPTS.has(a)) j++;
          continue;
        }
        if (a === "--") continue;
        sawHost = true; continue; // this token is the host
      }
      remote.push(a);
    }
    if (remote.length > 0) found.push(remote.join(" "));
  } else if (c0 === "xargs") {
    const rest: string[] = [];
    for (let i = 1; i < argv.length; i++) {
      const a = argv[i];
      if (a.startsWith("-")) {
        if (["-I", "-i", "-n", "-N", "-P", "-d", "-E", "-s", "-t", "-E"].includes(a)) i++;
        continue;
      }
      rest.push(a);
    }
    if (rest.length > 0) found.push(rest.join(" "));
  } else if (c0 === "eval") {
    found.push(argv.slice(1).join(" "));
  }
  return found;
}

// ---------- bash rules ----------

function isRootPath(word: string, home: string): boolean {
  const p = expandHome(word, home);
  if (!p.startsWith("/")) return false;
  const norm = p.length > 1 ? p.replace(/\/+$/, "") : p;
  if (norm === home) return true; // $HOME / ~ are roots in their own right
  if (norm.startsWith(home + "/")) return true;
  for (const root of SCAN_ROOTS) {
    const r = root.length > 1 ? root.replace(/\/+$/, "") : root;
    if (norm === r) return true;
    if (r !== "/" && norm.startsWith(r + "/")) return true;
  }
  return false;
}

function gitSubcommand(argv: string[]): { sub: string; args: string[] } | undefined {
  let i = 1;
  while (i < argv.length) {
    const a = argv[i];
    if (a === "-C" || a === "-c") { i += 2; continue; }
    if (a.startsWith("-")) { i++; continue; }
    return { sub: a, args: argv.slice(i + 1) };
  }
  return undefined;
}

/** Writer targets of a bash command that are not `>` redirects. */
function writerTargets(c0: string, args: string[]): string[] {
  const nonOpt = args.filter((a) => !a.startsWith("-") && a !== "--");
  switch (c0) {
    case "sed": {
      if (!args.some((a) => /^-i(\..*)?$/.test(a) || a === "--in-place" || a.startsWith("--in-place="))) return [];
      return nonOpt.slice(1); // first non-option is the script, the rest are files
    }
    case "perl": {
      if (!args.some((a) => /^-i/.test(a))) return [];
      return nonOpt.slice(1);
    }
    case "mv":
    case "cp":
      return nonOpt.length > 0 ? [nonOpt[nonOpt.length - 1]] : []; // destination
    case "rm":
      return nonOpt;
    case "truncate":
      return nonOpt;
    case "chmod":
    case "chown": {
      // mode args look like 644 / u+x / owner:group and never contain / or .
      const looksLikeMode = (a: string) =>
        !a.includes("/") && !a.includes(".") && (/^[0-7]{3,4}$/.test(a) || /^[-+u ga*:=Rc]+$/.test(a) || /^[ugoa]/.test(a));
      return nonOpt.filter((a) => !looksLikeMode(a));
    }
    case "ln":
      return nonOpt.length > 0 ? [nonOpt[nonOpt.length - 1]] : [];
    case "tee":
      return nonOpt;
    case "dd": {
      const outArg = args.find((a) => a.startsWith("of="));
      return outArg ? [outArg.slice(3)] : [];
    }
    default:
      return [];
  }
}

const READONLY_CMDS = new Set(["ls", "cat", "head", "tail", "wc", "grep", "rg", "find", "git"]);

function decideBash(command: string, role: RoleProfile, state: GuardState, home: string): Decision {
  const scan = scanBashLine(command);

  // Rule 1: secrets — any word anywhere mentioning a secret path
  for (const w of scan.allWords) {
    if (isSecretPath(w, home)) return block("secrets-path", `access to ${w}`);
  }
  // Rule 1: printenv anywhere (covers brace/function bodies the parser cannot run)
  if (scan.allWords.some((w) => w === "printenv")) return block("env-dump", "printenv");

  for (const cmd of scan.commands) {
    const argv = cmd.argv;
    if (argv.length === 0) {
      // redirect-only segment (`> file`): still a write
      for (const t of cmd.writeTargets) {
        const d = decideWritePathMaybeNoRole(role, t, state, home);
        if (d) return d;
      }
      continue;
    }
    const c0 = baseName(argv[0]);
    const args = argv.slice(1);

    // Rule 1: sops allowed only with -e / --encrypt
    if (c0 === "sops") {
      const ok = args.some((a) => a === "-e" || a === "--encrypt" || a.startsWith("--encrypt="));
      if (!ok) return block("sops-decrypt", "sops without -e/--encrypt");
    }
    // Rule 1: environment dumps
    if (c0 === "printenv") return block("env-dump", "printenv");
    if (c0 === "env" && !args.some((a) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(a))) {
      return block("env-dump", "bare env");
    }
    if (c0 === "export" && args.some((a) => a === "-p" || a === "--show-declared-values")) return block("env-dump", "export -p");
    if (c0 === "declare" && args.some((a) => a === "-x" || a === "-p")) return block("env-dump", "declare -x/-p");
    if (c0 === "set" && args.filter((a) => a !== "--").length === 0) return block("env-dump", "set with no arguments");
    // Rule 1: ps / pgrep printing full command lines (GUL-206)
    if (c0 === "ps") {
      for (let i = 0; i < args.length; i++) {
        const a = args[i];
        if (a === "aux" || a === "auxww" || a === "-aux" || a === "-ef" || a === "-fe" || a === "-fw" || /^-[a-z]*ef[a-z]*$/i.test(a)) {
          return block("ps-full-cmdline", `ps ${a}`);
        }
        if (a === "-o" || a === "-O" || a === "--format" || (a.startsWith("-o") && a.length > 2)) {
          const val = a.startsWith("-o") && a.length > 2 ? a.slice(2) : args[i + 1];
          if (val && /command|args/.test(val)) return block("ps-full-cmdline", `ps ${a} ${val}`);
        }
      }
    }
    if (c0 === "pgrep" && args.some((a) => /^-[a-zA-Z]*[laf]/.test(a) && !a.startsWith("--"))) {
      return block("ps-full-cmdline", "pgrep with command-line output flags");
    }

    // Rule 2: git / gh
    if (c0 === "git") {
      const g = gitSubcommand(argv);
      if (g) {
        if (g.args.includes("--no-verify")) return block("git-no-verify", `git ${g.sub} --no-verify`);
        if (g.sub === "commit" && !role.allowCommit) return block("role-no-commit", "commit not allowed for role");
        if (g.sub === "push") {
          if (!role.allowPush) return block("role-no-push", "push not allowed for role");
          if (g.args.some((a) => a === "--force" || a === "-f" || a.startsWith("--force-with-lease") || a === "--force-if-includes")) {
            return block("git-force-push", "force push");
          }
          for (const a of g.args.filter((x) => !x.startsWith("-"))) {
            if (a.startsWith("+") || a.includes(":main") || a.includes(":master") || a === "main" || a === "master") {
              return block("git-main-push", `push refspec ${a}`);
            }
          }
        }
        if (g.sub === "restore" || g.sub === "rm") {
          for (const f of g.args.filter((a) => !a.startsWith("-") && a !== "--")) {
            const d = decideWritePathMaybeNoRole(role, f, state, home);
            if (d && (d.ruleId === "protected-file" || d.ruleId === "secrets-path" || d.ruleId === "no-role")) return d;
            if (d && isProtectedPath(expandHome(f, home), home)) return d;
          }
        }
        if (g.sub === "checkout") {
          const dd = g.args.indexOf("--");
          if (dd !== -1) {
            for (const f of g.args.slice(dd + 1)) {
              if (isProtectedPath(expandHome(f, home), home)) return block("protected-file", `git checkout -- ${f}`);
              if (isSecretPath(expandHome(f, home), home)) return block("secrets-path", `git checkout -- ${f}`);
            }
          }
        }
      }
    }
    if (c0 === "gh") {
      const pos = args.filter((a) => !a.startsWith("-"));
      const joined = pos.join(" ");
      if (/^pr\s+merge/.test(joined)) return block("gh-pr-merge", "gh pr merge");
      if (/^repo\s+delete/.test(joined)) return block("gh-repo-delete", "gh repo delete");
      if (pos[0] === "api" && (args.includes("-X") || args.includes("--method"))) {
        const mi = Math.max(args.indexOf("-X"), args.indexOf("--method"));
        if (mi !== -1 && (args[mi + 1] || "").toUpperCase() === "DELETE") return block("gh-api-delete", "gh api DELETE");
      }
    }

    // Rule 3: new dependencies
    if (c0 === "npm") {
      const subIdx = args.findIndex((a) => !a.startsWith("-"));
      const sub = subIdx === -1 ? "" : args[subIdx];
      if (sub === "install" || sub === "i" || sub === "add") {
        const pkg = args.slice(subIdx + 1).find((a) => !a.startsWith("-"));
        if (pkg) return block("new-dependency", `npm ${sub} ${pkg}`);
      }
    }
    if ((c0 === "pnpm" || c0 === "yarn" || c0 === "bun")) {
      const sub = args.find((a) => !a.startsWith("-"));
      if (sub === "add") return block("new-dependency", `${c0} add`);
    }
    if ((c0 === "pip" || c0 === "pip3") && args.includes("install")) return block("new-dependency", `${c0} install`);
    if (c0 === "uv") {
      if (args[0] === "add") return block("new-dependency", "uv add");
      if (args[0] === "pip" && args[1] === "install") return block("new-dependency", "uv pip install");
    }
    if ((c0 === "brew" || c0 === "cargo" || c0 === "go") && args.includes("install")) return block("new-dependency", `${c0} install`);
    if (c0 === "npx" && args.some((a) => a === "-y" || a === "--yes" || /^-[a-z]*y[a-z]*$/.test(a) && !a.startsWith("--"))) {
      // bare `npx pkg` runs a download: block only with -y/--yes per spec
      return block("new-dependency", "npx -y");
    }

    // Rule 4: disk-wide scans
    if (c0 === "find" || c0 === "fd") {
      const paths = args.filter((a) => !a.startsWith("-"));
      const hit = paths.find((p) => isRootPath(p, home));
      if (hit) return block("disk-scan", `${c0} over ${expandHome(hit, home)}`);
    }
    if (c0 === "grep") {
      const recursive = args.some((a) => /^-[a-zA-Z]{1,3}$/.test(a) && /[rR]/.test(a)) || args.includes("--recursive");
      if (recursive) {
        const paths = args.filter((a) => !a.startsWith("-"));
        const hit = paths.find((p) => isRootPath(p, home));
        if (hit) return block("disk-scan", `grep -r over ${expandHome(hit, home)}`);
      }
    }
    if (c0 === "rg" || c0 === "du") {
      const paths = args.filter((a) => !a.startsWith("-"));
      const hit = paths.find((p) => isRootPath(p, home));
      if (hit) return block("disk-scan", `${c0} over ${expandHome(hit, home)}`);
    }
    if (c0 === "ls") {
      const recurse = args.some((a) => /^-[a-zA-Z]{1,3}$/.test(a) && /[Rr]/.test(a));
      if (recurse) {
        const paths = args.filter((a) => !a.startsWith("-"));
        const hit = paths.find((p) => isRootPath(p, home));
        if (hit) return block("disk-scan", `ls -R over ${expandHome(hit, home)}`);
      }
    }

    // Rule 5 + role scope for writers: `>` targets and writer commands
    const targets = [...cmd.writeTargets, ...writerTargets(c0, args)];
    for (const t of targets) {
      const d = decideWritePathMaybeNoRole(role, t, state, home);
      if (d) return d;
    }

    // readonly role: bash only from the read-only allowlist
    if (role.writeScope === "none") {
      if (!readonlyBashAllowed(c0, args)) {
        return block("readonly-allowlist", `${c0} is not on the read-only allowlist`);
      }
    }
  }
  return undefined;
}

function readonlyBashAllowed(c0: string, args: string[]): boolean {
  if (READONLY_CMDS.has(c0)) return true; // scan/writer rules already rejected the bad ones
  if (c0 === "git") {
    const g = gitSubcommand(["git", ...args]);
    return !!g && ["log", "show", "diff", "status", "blame"].includes(g.sub);
  }
  if (c0 === "bash" || c0 === "sh" || SHELLS.has(c0)) {
    const script = args.find((a) => !a.startsWith("-"));
    if (!script) return false;
    return /(^|\/)tests\/[^\/]+-check\.sh$/.test(script) || /(^|\/)scripts\/check\.sh$/.test(script);
  }
  return false;
}

// ---------- entry points ----------

/**
 * Decide one tool call. `role` is the resolved role profile — pass undefined
 * for a missing/unknown --factory-role, which fails closed for writes and bash.
 * Returns undefined to allow, or { block, reason, ruleId }.
 */
export function decideToolCall(
  role: RoleProfile | undefined,
  toolName: string,
  input: unknown,
  state: GuardState,
  home: string,
): Decision {
  const gated = WRITE_TOOLS.has(toolName) || BASH_TOOLS.has(toolName);
  if (!role) {
    if (gated) return { block: true, reason: ROLE_NO_REASON, ruleId: "no-role" };
    return undefined;
  }

  if (WRITE_TOOLS.has(toolName)) {
    if (input === null || typeof input !== "object" || Array.isArray(input)) {
      return block("malformed-input", `${toolName} input is not an object`);
    }
    const path = (input as Record<string, unknown>).path;
    if (typeof path !== "string" || path.length === 0) {
      return block("malformed-input", `${toolName} input.path is not a string`);
    }
    return decideWritePath(role, path, state, home);
  }

  if (READ_TOOLS.has(toolName) || SEARCH_TOOLS.has(toolName)) {
    if (input === null || typeof input !== "object") return undefined; // let Pi's own validation run
    for (const v of Object.values(input as Record<string, unknown>)) {
      if (typeof v !== "string") continue;
      if (isSecretPath(v, home)) return block("secrets-path", `read access to ${v}`);
      if (SEARCH_TOOLS.has(toolName) && isRootPath(v, home)) {
        return block("disk-scan", `${toolName} over root path ${v}`);
      }
    }
    return undefined;
  }

  if (BASH_TOOLS.has(toolName)) {
    if (input === null || typeof input !== "object" || Array.isArray(input)) {
      return block("malformed-input", "bash input is not an object");
    }
    const command = (input as Record<string, unknown>).command;
    if (typeof command !== "string") return block("malformed-input", "bash input.command is not a string");
    return decideBash(command, role, state, home);
  }

  // unknown / custom tools: not gated in phase 1
  return undefined;
}

/** Fail-closed wrapper: any exception inside the rules becomes a block. */
export function decideToolCallSafe(
  role: RoleProfile | undefined,
  toolName: string,
  input: unknown,
  state: GuardState,
  home: string,
): Decision {
  try {
    return decideToolCall(role, toolName, input, state, home);
  } catch {
    return block("internal-error-fail-closed", "guard could not decide");
  }
}

/** Turn-cap block reason, verbatim from the plan. */
export function turnCapReason(cap: number): string {
  return `factory-guard: turn cap ${cap} reached. Post a short comment with what is done and what is left, end it with "RESULT: stalled", and stop.`;
}
