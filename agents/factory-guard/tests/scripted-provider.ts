/**
 * Test-only scripted model provider for factory-guard's live test.
 *
 * Registers a provider whose "model" replays a fixed list of tool calls from
 * FACTORY_GUARD_SCRIPT (a JSON file), so the live test costs no tokens and
 * gives the same result every run. Built on pi-ai's faux provider, which
 * speaks Pi's full stream protocol; we only own the script and the wiring.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
// the pi-ai root resolves to the compat entrypoint inside extension loading
import {
  fauxAssistantMessage,
  fauxText,
  fauxToolCall,
  registerFauxProvider,
} from "@earendil-works/pi-ai";
import * as fs from "node:fs";

interface ScriptStep {
  text?: string;
  tools?: Array<{ name: string; arguments: Record<string, unknown> }>;
}

export default function (pi: ExtensionAPI): void {
  const scriptPath = process.env.FACTORY_GUARD_SCRIPT;
  if (!scriptPath) throw new Error("scripted-provider: FACTORY_GUARD_SCRIPT is not set");
  const steps = JSON.parse(fs.readFileSync(scriptPath, "utf8")) as ScriptStep[];

  const model = {
    id: "scripted",
    name: "Scripted (factory-guard live test)",
    reasoning: false,
    input: ["text"] as ("text" | "image")[],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 200000,
    maxTokens: 8192,
  };

  const faux = registerFauxProvider({ provider: "fgtest", api: "fgtest-faux", models: [model] });
  faux.setResponses(steps.map((s) => {
    const blocks: ReturnType<typeof fauxText>[] = [];
    if (s.text) blocks.push(fauxText(s.text));
    for (const t of s.tools ?? []) blocks.push(fauxToolCall(t.name, t.arguments) as never);
    return fauxAssistantMessage(blocks.length > 0 ? blocks : "ok");
  }));

  pi.registerProvider("fgtest", {
    baseUrl: "http://127.0.0.1:1",
    apiKey: "facto…key", // the faux provider never talks to a network
    api: "fgtest-faux",
    models: [model],
  });
}
