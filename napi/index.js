// Runtime loader for @zseven-w/agent-native NAPI addon.
// Uses ESM + createRequire so Vite's module runner can process this file.
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const _require = createRequire(import.meta.url);

const candidates = [
  join(__dirname, "..", "zig-out", "napi", "agent_napi.node"),
  join(__dirname, "agent_napi.node"),
];

let addon;
for (const p of candidates) {
  if (existsSync(p)) {
    addon = _require(p);
    break;
  }
}

if (!addon) {
  throw new Error(
    `@zseven-w/agent-native: could not locate agent_napi.node.\n` +
    `Run \`zig build napi\` from the agent/ repo to build it.\n` +
    `Searched:\n${candidates.map((c) => `  ${c}`).join("\n")}`
  );
}

// Re-export bridge functions directly.
export const {
  agentVersion,
  createAnthropicProvider,
  createOpenAICompatProvider,
  destroyProvider,
  createToolRegistry,
  registerToolSchema,
  destroyToolRegistry,
  seedMessages,
  resolveToolResult,
  pushToolProgress,
  abortEngine,
  destroyQueryEngine,
  destroyIterator,
  createSubAgent,
  subAgentRun,
  abortSubAgent,
  destroySubAgent,
  createTeam,
  addTeamMember,
  runTeam,
  resolveTeamToolResult,
  abortTeam,
  destroyTeam,
  teamRegisterDelegate,
  runTeamMember,
  resolveMemberToolResult,
  seedTeamMessages,
} = addon;

// createQueryEngine: destructure config object → flat args for Bun NAPI compat.
const _createQueryEngine = addon.createQueryEngine;
export function createQueryEngine(config) {
  return _createQueryEngine(
    config.provider,
    config.tools ?? null,
    config.systemPrompt ?? "",
    config.maxTurns ?? 50,
    config.cwd ?? ".",
  );
}

// submitMessage: synchronous (just creates iterator, no HTTP).
export async function submitMessage(engine, prompt) {
  return addon.submitMessage(engine, prompt);
}

// nextEvent: returns native NAPI Promise (async work on background thread).
// Wrap with a 30s timeout — if no SSE event arrives within 30s, treat as stream end.
const _nextEvent = addon.nextEvent;
const NEXT_EVENT_TIMEOUT_MS = 30_000;
export function nextEvent(iter) {
  return Promise.race([
    _nextEvent(iter),
    new Promise((resolve) =>
      setTimeout(() => resolve(null), NEXT_EVENT_TIMEOUT_MS),
    ),
  ]);
}

export default addon;
