// Runtime loader for @zseven-w/agent-native NAPI addon.
// Tries zig-out/napi/ first (development), then the package-bundled .node.
const path = require("path");
const fs = require("fs");

const candidates = [
  // Built by `zig build napi` from repo root
  path.join(__dirname, "..", "zig-out", "napi", "agent_napi.node"),
  // Bundled in npm package
  path.join(__dirname, "agent_napi.node"),
];

let addon;
for (const p of candidates) {
  if (fs.existsSync(p)) {
    addon = require(p);
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

module.exports = addon;
