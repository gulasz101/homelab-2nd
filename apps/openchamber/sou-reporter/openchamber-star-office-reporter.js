// openchamber-star-office-reporter — OpenCode/OpenChamber reporter plugin for
// the Star Office UI dashboard (SOU-71, ADR-035 event schema v1).
//
// One self-contained ESM file, no runtime dependencies, no OpenCode imports:
// OpenCode 2.x auto-loads direct .js files under .opencode/plugins/ (project
// or global), and the same file is unit-testable with `node --test`.
//
//   Hook layer (adapter):  ctx.tool.hook("execute.before"/"execute.after"),
//                          ctx.event.subscribe()  ->  six event types below.
//   Pure layer (core):     loadConfig / buildEnvelope / redactPayload /
//                          classifyTool / createReporter — exported for tests.
//
// Event types reported (issue SOU-71 AC3):
//   session_start      plugin setup (OpenChamber/OpenCode server came up)
//   tool_call          every tool execution, after it finishes
//   file_edit          write/edit/patch-class tools
//   command_run        bash/shell-class tools, output truncated
//   code_completion    session.idle after the session edited files
//   session_end        session.deleted, plugin cleanup, or SIGINT/SIGTERM
//
// Configuration (AC4), precedence env > config file > defaults:
//   SOU_DASHBOARD_URL      default http://127.0.0.1:19000
//   SOU_AGENT_NAME         default openchamber (use opencode behind OpenChamber)
//   SOU_REPORTER_ENABLED   0/false/no/off disables every POST
//   SOU_TIMEOUT_MS         default 5000, clamped to [200, 30000]
//   SOU_TOKEN              ingest token -> Authorization: Bearer (SOU-223,
//                          config key `token`; required once the dashboard
//                          runs with SOU_INGEST_TOKENS, P13-B)
//   SOU_REPORTER_CONFIG    path to a JSON file; otherwise standard locations
//   (see README.md).
//
// Privacy (AC5): secret-shaped values and secret-named keys are redacted,
// long strings truncated, and the whole payload kept under the dashboard's
// 65536-byte cap. Non-blocking (AC2): hooks never await the network; send
// failures are one stderr line and a counter. SOU-223: with SOU_TOKEN set
// every POST carries `Authorization: Bearer` (P13-B door), and the plaintext
// token is scrubbed from log lines and payloads alike.

import { readFileSync, mkdirSync, appendFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

export const PLUGIN_ID = "openchamber-star-office-reporter";

export const DEFAULTS = {
  dashboardUrl: "http://127.0.0.1:19000",
  agent: "openchamber",
  timeoutMs: 5000,
  enabled: true,
  minTimeoutMs: 200,
  maxTimeoutMs: 30000,
  maxFieldChars: 4000,
  maxPayloadBytes: 65536, // backend/event_schema.py PAYLOAD_MAX_BYTES
};

const OFF_WORDS = new Set(["0", "false", "no", "off"]);

// --- configuration ----------------------------------------------------------

function parseTimeoutMs(raw, fallback) {
  const n = Number.parseInt(String(raw), 10);
  if (!Number.isFinite(n) || n < DEFAULTS.minTimeoutMs) return fallback;
  return Math.min(n, DEFAULTS.maxTimeoutMs);
}

function configFileCandidates(env) {
  const out = [];
  if (env.SOU_REPORTER_CONFIG) out.push(env.SOU_REPORTER_CONFIG);
  if (env.OPENCODE_CONFIG_DIR) out.push(path.join(env.OPENCODE_CONFIG_DIR, "star-office-reporter.json"));
  const xdg = env.XDG_CONFIG_HOME;
  if (xdg) {
    out.push(path.join(xdg, "star-office-reporter.json"));
    out.push(path.join(xdg, "opencode", "star-office-reporter.json"));
  }
  const home = typeof env.HOME === "string" && env.HOME ? env.HOME : homedir();
  out.push(path.join(home, ".config", "opencode", "star-office-reporter.json"));
  return out;
}

function normalizeLayer(obj) {
  const layer = {};
  if (typeof obj.dashboardUrl === "string" && obj.dashboardUrl.trim()) {
    layer.dashboardUrl = obj.dashboardUrl.trim().replace(/\/+$/, "");
  }
  if (typeof obj.agent === "string" && obj.agent.trim()) layer.agent = obj.agent.trim();
  if (typeof obj.token === "string" && obj.token.trim()) layer.token = obj.token.trim();
  if (obj.enabled !== undefined) {
    layer.enabled = typeof obj.enabled === "boolean" ? obj.enabled : !OFF_WORDS.has(String(obj.enabled).trim().toLowerCase());
  }
  if (obj.debug !== undefined) {
    layer.debug = typeof obj.debug === "boolean" ? obj.debug : !OFF_WORDS.has(String(obj.debug).trim().toLowerCase());
  }
  if (obj.timeoutMs !== undefined) {
    const n = Number.parseInt(String(obj.timeoutMs), 10);
    layer.timeoutMs = Number.isFinite(n) ? n : undefined;
  }
  if (Array.isArray(obj.routes)) {
    layer.routes = obj.routes
      .filter((r) => r && typeof r.directory === "string" && r.directory.trim() && typeof r.agent === "string" && r.agent.trim())
      .map((r) => compact({
        directory: path.resolve(r.directory.trim()),
        agent: r.agent.trim(),
        token: typeof r.token === "string" && r.token.trim() ? r.token.trim() : undefined,
      }));
  }
  return layer;
}

/**
 * One OpenCode engine can serve several workspaces (the in-cluster OpenChamber runs
 * the SOU and the H2 itsaplan runners side by side). OpenCode sets a plugin up once per
 * project directory, so the reporter picks its identity there: the route whose
 * `directory` is the longest prefix of that directory wins, and its agent (and token,
 * when given) replace the defaults. No match keeps the top-level agent and token.
 */
export function resolveRoute(config, directory) {
  const routes = Array.isArray(config.routes) ? config.routes : [];
  if (!routes.length || typeof directory !== "string" || !directory) return config;
  const dir = path.resolve(directory);
  let best = null;
  for (const r of routes) {
    const inside = dir === r.directory || dir.startsWith(r.directory.endsWith(path.sep) ? r.directory : r.directory + path.sep);
    if (inside && (!best || r.directory.length > best.directory.length)) best = r;
  }
  if (!best) return config;
  return { ...config, agent: best.agent, token: best.token ?? config.token, route: best.directory };
}

/**
 * Load reporter configuration. `env` defaults to process.env; `opts.readFile`
 * is injectable for tests. Precedence: env vars > JSON config file > defaults.
 */
export function loadConfig(env = process.env, opts = {}) {
  const readFile = opts.readFile ?? safeReadFile;
  let merged = { dashboardUrl: DEFAULTS.dashboardUrl, agent: DEFAULTS.agent, timeoutMs: DEFAULTS.timeoutMs, enabled: DEFAULTS.enabled, debug: false };

  const candidates = opts.configPath ? [opts.configPath] : configFileCandidates(env);
  for (const file of candidates) {
    const text = readFile(file);
    if (text == null) continue;
    try {
      Object.assign(merged, normalizeLayer(JSON.parse(text)));
    } catch {
      // Malformed config file: ignore it, the plugin must not fight the host.
    }
    break;
  }

  const envLayer = normalizeLayer({
    dashboardUrl: env.SOU_DASHBOARD_URL,
    agent: env.SOU_AGENT_NAME,
    token: env.SOU_TOKEN,
    timeoutMs: env.SOU_TIMEOUT_MS,
    enabled: env.SOU_REPORTER_ENABLED === undefined ? undefined : !OFF_WORDS.has(String(env.SOU_REPORTER_ENABLED).trim().toLowerCase()),
    debug: env.SOU_DEBUG === undefined ? undefined : !OFF_WORDS.has(String(env.SOU_DEBUG).trim().toLowerCase()),
  });
  Object.assign(merged, envLayer);

  const timeoutMs = parseTimeoutMs(merged.timeoutMs, DEFAULTS.timeoutMs);
  const dashboardUrl = String(merged.dashboardUrl || DEFAULTS.dashboardUrl).trim().replace(/\/+$/, "");
  const stateHome = env.XDG_STATE_HOME || path.join(homedir(), ".local", "state");
  return {
    dashboardUrl,
    eventsUrl: `${dashboardUrl}/events`,
    agent: merged.agent || DEFAULTS.agent,
    token: merged.token || "",
    routes: merged.routes ?? [],
    enabled: merged.enabled !== false,
    debug: merged.debug === true,
    debugLogFile: env.SOU_REPORTER_LOG || path.join(stateHome, "sou-reporter", "reporter.log"),
    timeoutMs,
    maxFieldChars: DEFAULTS.maxFieldChars,
    maxPayloadBytes: DEFAULTS.maxPayloadBytes,
    minTimeoutMs: DEFAULTS.minTimeoutMs,
    maxTimeoutMs: DEFAULTS.maxTimeoutMs,
  };
}

function safeReadFile(file) {
  try {
    return readFileSync(file, "utf8");
  } catch {
    return null;
  }
}

// --- privacy ----------------------------------------------------------------

const SECRET_VALUE_PATTERNS = [
  [/\b(bearer|basic)\s+[A-Za-z0-9\-._~+/=]{4,}\b/gi, "$1 [redacted]"],
  [/\b(?:sk|rk|pk|key)-[A-Za-z0-9_\-]{12,}\b/g, "[redacted]"],
  [/\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,})\b/g, "[redacted]"],
  [/\bAKIA[0-9A-Z]{12,}\b/g, "[redacted]"],
  [/\bxox[abprs]-[A-Za-z0-9-]{10,}\b/g, "[redacted]"],
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b/g, "[redacted]"],
  // key: value / key=value with a secret-named key
  [/((?:api[_-]?key|access[_-]?key|secret|token|passw(?:or)?d|passwd|credential|authorization|auth[_-]?key)[\w-]*\s*[=:]\s*)(?:"[^"]{1,}"|'[^']{1,}'|(?!\[redacted\])[^\s;,']{4,})/gi, "$1[redacted]"],
];

const SECRET_KEY_NAME = /(api[_-]?key|access[_-]?key|secret|token|passw(?:or)?d|credential|authorization|auth[_-]?key|private[_-]?key|cookie)/i;

function scrubString(str, maxFieldChars) {
  let out = str;
  if (out.length > maxFieldChars) {
    out = `${out.slice(0, maxFieldChars)}…[truncated ${out.length - maxFieldChars} chars]`;
  }
  for (const [re, repl] of SECRET_VALUE_PATTERNS) out = out.replace(re, repl);
  return out;
}

function redactWalk(node, maxFieldChars, depth) {
  if (node === null || node === undefined) return node;
  if (typeof node === "string") return scrubString(node, maxFieldChars);
  if (typeof node === "number" || typeof node === "boolean") return node;
  if (depth > 8) return "[depth-limited]";
  if (Array.isArray(node)) {
    return node.slice(0, 200).map((item) => redactWalk(item, maxFieldChars, depth + 1));
  }
  if (typeof node === "object") {
    const out = {};
    for (const [key, value] of Object.entries(node).slice(0, 200)) {
      out[key] = SECRET_KEY_NAME.test(key) ? "[redacted]" : redactWalk(value, maxFieldChars, depth + 1);
    }
    return out;
  }
  return scrubString(String(node), maxFieldChars);
}

/**
 * Privacy pass (AC5): redact secret-shaped values and secret-named keys,
 * truncate long strings, and keep the serialized payload within
 * config.maxPayloadBytes so POST /events never 400s on size.
 */
export function redactPayload(payload, config = loadConfig(process.env)) {
  const maxField = config.maxFieldChars ?? DEFAULTS.maxFieldChars;
  const cap = config.maxPayloadBytes ?? DEFAULTS.maxPayloadBytes;
  let out = redactWalk(payload && typeof payload === "object" ? payload : { detail: payload ?? {} }, maxField, 0);

  // Size cap: halve the longest string fields until the payload fits.
  let guard = 0;
  while (Buffer.byteLength(JSON.stringify(out), "utf8") > cap && guard < 8) {
    const limit = Math.max(64, Math.floor(maxField / 2 ** (guard + 1)));
    out = shrinkStrings(out, limit);
    guard += 1;
  }
  if (Buffer.byteLength(JSON.stringify(out), "utf8") > cap) {
    out = { truncated: true, note: "payload exceeded reporter size cap" };
  }
  return scrubTokenDeep(out, config.token);
}

function shrinkStrings(node, limit) {
  if (typeof node === "string") return node.length > limit ? `${node.slice(0, limit)}…[truncated ${node.length - limit} chars]` : node;
  if (Array.isArray(node)) return node.map((item) => shrinkStrings(item, limit));
  if (node && typeof node === "object") {
    const out = {};
    for (const [key, value] of Object.entries(node)) out[key] = shrinkStrings(value, limit);
    return out;
  }
  return node;
}

// --- classification -----------------------------------------------------------

/** Token → "[redacted]" scrubber for log lines (SOU-223); identity when unset. */
function makeTokenRedactor(token) {
  const t = typeof token === "string" ? token.trim() : "";
  if (!t) return (value) => String(value);
  return (value) => String(value).split(t).join("[redacted]");
}

/**
 * Remove every occurrence of the configured ingest token from a JSON-safe
 * tree (SOU-223 ruling: an agent echoing $SOU_TOKEN in command output must
 * not land it in the feed). Tokens are URL-safe base64, so they survive
 * JSON.stringify unescaped and a substring replace cannot corrupt the JSON.
 */
function scrubTokenDeep(value, token) {
  const t = typeof token === "string" ? token.trim() : "";
  if (!t) return value;
  try {
    const s = JSON.stringify(value);
    return s.includes(t) ? JSON.parse(s.split(t).join("[redacted]")) : value;
  } catch {
    return value;
  }
}

// --- classification (tool names) ----------------------------------------------

const FILE_EDIT_TOOL = /^(?:[\w.-]+_)?(write|edit|patch|apply_patch|multi[_-]?edit|create[_-]?file|str[_-]?replace|search[_-]?replace|replace[_-]?in[_-]?file)$/i;
const COMMAND_TOOL = /^(?:[\w.-]+_)?(bash|shell|terminal|exec|execute|run[_-]?command|command|cmd)$/i;

/** Map a tool name to the extra event types it implies (AC3). */
export function classifyTool(name) {
  const tool = typeof name === "string" ? name.trim().toLowerCase() : "";
  return { fileEdit: FILE_EDIT_TOOL.test(tool), command: COMMAND_TOOL.test(tool) };
}

// --- envelope -----------------------------------------------------------------

/** Build an ADR-035 event schema v1 envelope. Throws on an unusable shape. */
export function buildEnvelope(config, eventType, payload, now = new Date()) {
  const event = typeof eventType === "string" ? eventType.trim() : "";
  if (!event || /\s/.test(event) || event.length > 100) {
    throw new TypeError(`event_type: must be 1-100 non-whitespace chars, got ${JSON.stringify(eventType)}`);
  }
  const agent = typeof config.agent === "string" ? config.agent.trim() : "";
  if (!agent || /\s/.test(agent) || agent.length > 255) {
    throw new TypeError(`agent: must be a single token of 1-255 chars, got ${JSON.stringify(config.agent)}`);
  }
  return {
    version: 1,
    agent,
    event_type: event,
    timestamp: now.toISOString(),
    payload: redactPayload(payload ?? {}, config),
  };
}

// --- transport ----------------------------------------------------------------

/**
 * Fire-and-forget reporter. report() never blocks on the network (AC2):
 * it starts the POST and hands back a promise the caller may ignore.
 * Every failure path ends in one log line plus a counter — the plugin
 * must not slow OpenChamber down or crash it when the dashboard is off.
 */
export function createReporter(config, deps = {}) {
  const doFetch = deps.fetch ?? globalThis.fetch;
  const logger = deps.logger ?? ((msg) => { try { console.error(`[sou-reporter] ${msg}`); } catch { /* ignore */ } });
  // SOU-223: no log line may carry the plaintext ingest token, wherever it
  // comes from (fetch diagnostics, future lines). Redact at the one funnel.
  const redactToken = makeTokenRedactor(config.token);
  const log = (msg) => logger(redactToken(msg));
  const stats = { sent: 0, failed: 0, dropped: 0 };
  const enabled = config.enabled !== false;
  const inflight = new Set();

  async function send(envelope) {
    try {
      if (typeof doFetch !== "function") throw new Error("no fetch implementation");
      const headers = { "content-type": "application/json", "user-agent": `${PLUGIN_ID}/1.2.0 (${config.agent})` };
      if (config.token) headers.Authorization = `Bearer ${config.token}`; // SOU-223 (P13-F)
      const res = await doFetch(config.eventsUrl, {
        method: "POST",
        headers,
        body: JSON.stringify(envelope),
        signal: AbortSignal.timeout(config.timeoutMs),
      });
      if (res && res.ok) {
        stats.sent += 1;
        return true;
      }
      stats.failed += 1;
      if (res && res.status === 401) {
        log(`dashboard rejected ${envelope.event_type}: HTTP 401 ${config.token ? "(ingest token unknown to this dashboard)" : "(set SOU_TOKEN - this dashboard requires a Bearer ingest token)"}`);
      } else {
        log(`dashboard rejected ${envelope.event_type}: HTTP ${res ? res.status : "?"}`);
      }
      return false;
    } catch (err) {
      stats.failed += 1;
      log(`dashboard unreachable, dropped ${envelope.event_type}: ${(err && err.message) || err}`);
      return false;
    }
  }

  function report(eventType, payload) {
    if (!enabled) return Promise.resolve(false);
    let envelope;
    try {
      envelope = buildEnvelope(config, eventType, payload ?? {});
    } catch (err) {
      stats.dropped += 1;
      log(`invalid event ${eventType}: ${err.message}`);
      return Promise.resolve(false);
    }
    const p = send(envelope).finally(() => inflight.delete(p));
    inflight.add(p);
    return p;
  }

  async function flush(boundMs = config.timeoutMs) {
    const all = Promise.allSettled([...inflight]);
    if (boundMs > 0) {
      await Promise.race([all, new Promise((resolve) => setTimeout(resolve, boundMs))]);
    } else {
      await all;
    }
  }

  return { report, flush, stats: () => ({ ...stats }), enabled };
}

// --- OpenCode adapter --------------------------------------------------------

function compact(obj) {
  const out = {};
  for (const [key, value] of Object.entries(obj)) {
    if (value !== undefined && value !== null) out[key] = value;
  }
  return out;
}

function eventKey(ev) {
  return ev.callID ?? ev.callId ?? `${ev.sessionID ?? ev.session_id ?? ""}:${ev.tool ?? ""}`;
}

function pickPath(input) {
  if (!input || typeof input !== "object") return undefined;
  return input.filePath ?? input.file_path ?? input.path ?? input.file ?? undefined;
}

function extractText(result) {
  if (result == null) return undefined;
  if (typeof result === "string") return result;
  // OpenCode tool results arrive as { output, content: [{ type:"text", text }], metadata }.
  const out = result.output;
  if (typeof out === "string") return out;
  if (out && typeof out === "object" && typeof out.output === "string") return out.output;
  if (typeof result.text === "string") return result.text;
  if (Array.isArray(result.content)) {
    const texts = result.content.filter((c) => c && typeof c.text === "string").map((c) => c.text);
    if (texts.length) return texts.join("\n");
  }
  if (out && typeof out === "object") {
    try {
      return JSON.stringify(out).slice(0, 2000);
    } catch {
      return undefined;
    }
  }
  try {
    return JSON.stringify(result).slice(0, 2000);
  } catch {
    return undefined;
  }
}

function extractExitCode(result, status) {
  if (result && typeof result === "object") {
    const v = result.exit_code ?? result.exitCode ?? result.exit ?? result.metadata?.exit_code ?? result.metadata?.exitCode;
    if (typeof v === "number") return v;
  }
  return status === "completed" ? 0 : 1;
}

/**
 * Build the plugin object. `inject` overrides the config / transport and
 * exists so the adapter is unit-testable without OpenCode or a network.
 * The default export is the plain plugin OpenCode's loader reads
 * (id + async setup(ctx)); do not import OpenCode packages here — the
 * installed 2.0.22 runtime resolves plugin files without them.
 */
export function createPlugin(inject = {}) {
  return {
    id: PLUGIN_ID,
    async setup(ctx = {}) {
      let cleanup = async () => {};
      try {
        cleanup = await setupInner(ctx, inject);
      } catch (err) {
        try { console.error(`[sou-reporter] setup failed: ${err && err.message}`); } catch { /* ignore */ }
      }
      return cleanup;
    },
  };
}

async function setupInner(ctx, inject) {
  const config = resolveRoute(inject.config ?? loadConfig(), ctx.location?.directory ?? safeCwd());
  const redactToken = makeTokenRedactor(config.token);
  const loggerSink =
    inject.logger ??
    ((msg, level = "warn") => {
      const line = redactToken(`[sou-reporter] ${msg}`);
      try {
        console.error(line);
      } catch {
        /* ignore */
      }
      // Mirror into OpenCode's structured log when the host exposes app.log.
      try {
        ctx?.app?.log?.({ level, message: line, service: PLUGIN_ID });
      } catch {
        /* shape varies */
      }
      try {
        ctx?.app?.log?.({ body: { level, message: line, service: PLUGIN_ID } });
      } catch {
        /* best effort */
      }
      // SOU_DEBUG=1: append to a file too — plugin console output is often
      // swallowed by the embedding server, and troubleshooting needs evidence.
      if (config.debug) {
        try {
          const file = config.debugLogFile;
          mkdirSync(path.dirname(file), { recursive: true });
          appendFileSync(file, `${new Date().toISOString()} ${level.toUpperCase()} ${line}\n`, "utf8");
        } catch {
          /* ignore */
        }
      }
    });
  const reporter = inject.reporter ?? createReporter(config, { fetch: inject.fetch, logger: loggerSink });
  const startedAt = Date.now();
  const editSessions = new Map(); // sessionID -> Set(files)
  const startTimes = new Map(); // hook key -> t0

  const elapsedSeconds = () => Math.max(0, Math.round((Date.now() - startedAt) / 1000));
  const loggedSoFar = () => {
    const s = reporter.stats();
    return s.sent + s.failed + s.dropped;
  };

  // Emit a code_completion for every edit still unreported (agent stopped
  // working on those files); used by session.idle, session.deleted and exit.
  const flushCompletions = () => {
    for (const [sessionID, files] of editSessions) {
      if (!files.size) continue;
      void reporter.report("code_completion", compact({ session_id: sessionID, files_touched: [...files].slice(0, 50), edits: files.size }));
      files.clear();
    }
  };

  let processEndReported = false;
  const reportProcessEnd = (reason) => {
    if (processEndReported) return;
    processEndReported = true;
    flushCompletions();
    void reporter.report("session_end", compact({ reason, duration_seconds: elapsedSeconds(), events_logged: loggedSoFar() }));
    void reporter.flush(Math.min(config.timeoutMs, 2000));
  };

  // never let a hook throw into OpenCode's tool pipeline
  const safe = (fn) => (ev) => {
    try {
      const r = fn(ev ?? {});
      if (r && typeof r.catch === "function") r.catch(() => {});
    } catch { /* reporting must not break the host */ }
  };

  void reporter.report("session_start", compact({
    directory: ctx.location?.directory ?? safeCwd(),
    engine: "opencode",
    engine_version: ctx.app?.version,
    plugin: PLUGIN_ID,
    pid: process.pid,
  }));

  const beforeReg = await ctx.tool?.hook?.("execute.before", safe((ev) => {
    if (startTimes.size > 500) startTimes.delete(startTimes.keys().next().value);
    startTimes.set(eventKey(ev), { t0: Date.now(), input: ev.input });
  }));

  const afterReg = await ctx.tool?.hook?.("execute.after", safe(async (ev) => {
    const key = eventKey(ev);
    const start = startTimes.get(key);
    startTimes.delete(key);
    const durationMs = start?.t0 ? Date.now() - start.t0 : undefined;
    const input = ev.input ?? start?.input;
    const tool = typeof ev.tool === "string" ? ev.tool : String(ev.tool ?? "unknown");
    const status = ev.status === "completed" ? "completed" : ev.status === "error" ? "error" : "unknown";
    const sessionID = ev.sessionID ?? ev.session_id;
    const cls = classifyTool(tool);

    void reporter.report("tool_call", compact({
      tool,
      status,
      session_id: sessionID,
      duration_ms: durationMs,
      error: status === "error" ? (ev.error?.message ?? String(ev.error ?? "tool failed")) : undefined,
    }));

    if (cls.fileEdit) {
      const file = pickPath(input);
      if (sessionID && file) {
        if (!editSessions.has(sessionID)) editSessions.set(sessionID, new Set());
        editSessions.get(sessionID).add(String(file));
      }
      void reporter.report("file_edit", compact({
        tool,
        file,
        session_id: sessionID,
        status,
        duration_ms: durationMs,
      }));
    }

    if (cls.command) {
      void reporter.report("command_run", compact({
        command: input?.command ?? input?.cmd ?? undefined,
        cwd: input?.cwd,
        session_id: sessionID,
        status,
        exit_code: extractExitCode(ev.result, status),
        duration_ms: durationMs,
        output: extractText(ev.result),
      }));
    }
  }));

  const controller = new AbortController();
  void (async () => {
    try {
      if (!ctx.event?.subscribe) return;
      for await (const ev of ctx.event.subscribe({ signal: controller.signal })) {
        try {
          handleBusEvent(ev);
        } catch { /* ignore one bad event */ }
      }
    } catch { /* subscription ended */ }
  })();

  function handleBusEvent(ev) {
    const type = typeof ev?.type === "string" ? ev.type : "";
    const props = ev?.properties ?? ev?.payload ?? ev?.data ?? {};
    const sessionID = props.sessionID ?? props.session_id;
    if (type === "session.idle") {
      const files = sessionID ? editSessions.get(sessionID) : undefined;
      if (files && files.size) {
        void reporter.report("code_completion", compact({
          session_id: sessionID,
          files_touched: [...files].slice(0, 50),
          edits: files.size,
        }));
        editSessions.set(sessionID, new Set());
      }
    } else if (type === "session.deleted") {
      void reporter.report("session_end", compact({
        session_id: sessionID,
        reason: "session_deleted",
        duration_seconds: elapsedSeconds(),
        events_logged: loggedSoFar(),
      }));
      if (sessionID) editSessions.delete(sessionID);
    }
  }

  const signalFns = [];
  for (const name of ["SIGINT", "SIGTERM"]) {
    const fn = () => {
      try {
        reportProcessEnd(name.toLowerCase());
      } catch {
        /* exiting */
      }
    };
    try {
      process.on(name, fn);
      signalFns.push([name, fn]);
    } catch { /* no process signal access */ }
  }

  return async function cleanup() {
    try { controller.abort(); } catch { /* ignore */ }
    for (const [name, fn] of signalFns) {
      try { process.off(name, fn); } catch { /* ignore */ }
    }
    try { await beforeReg?.dispose?.(); } catch { /* ignore */ }
    try { await afterReg?.dispose?.(); } catch { /* ignore */ }
    reportProcessEnd("plugin_unload");
    await reporter.flush(Math.min(config.timeoutMs, 2000));
  };
}

function safeCwd() {
  try {
    return process.cwd();
  } catch {
    return undefined;
  }
}

const plugin = createPlugin();
export default plugin;
