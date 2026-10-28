// path-parity.ts — expose looksLikeTestPath for the python/TS parity test.
// Run: node agents/factory/tests/path-parity.ts paths.json
// (Node 22.6+/24 runs .ts directly, same way guard-check.sh runs policy.test.ts.)
import * as fs from "node:fs";
import { looksLikeTestPath } from "../../factory-guard/policy.ts";

const paths: string[] = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const out: Record<string, boolean> = {};
for (const p of paths) out[p] = looksLikeTestPath(p);
console.log(JSON.stringify(out));
