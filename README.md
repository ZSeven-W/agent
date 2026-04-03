# agent

Zig SDK for building agentic LLM applications.

[![Zig](https://img.shields.io/badge/Zig-%E2%89%A5%200.14.0-f7a41d?logo=zig)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A zero-dependency agent framework written in Zig that provides a complete runtime for multi-turn LLM conversations with tool execution, agent teams, and streaming event delivery. Ships as a Zig module, a C ABI shared library for FFI, and a Node-API addon for Node.js and Bun.

## Features

- **Zero external dependencies** -- Zig standard library only
- **Three build targets** -- Zig module, C shared library (`libagent`), NAPI addon (`agent_napi.node`)
- **Async NAPI bridge** -- Promise-based `submitMessage` / `nextEvent` for Node.js and Bun
- **Pull-based streaming** -- `EventIterator` with lazy `next()` evaluation
- **VTable polymorphism** -- `Tool`, `Provider`, and `ContextStrategy` use type-erased vtables for runtime dispatch
- **External tool execution** -- JS-side tool dispatch with `resolveToolResult` callback
- **Agent Teams** -- Leader + member delegation with file-based mailbox messaging
- **SubAgent** -- Single-task child agents for focused subtasks
- **Provider backends** -- Anthropic, OpenAI-compatible, and Ollama via a unified `Provider` interface
- **Permission system** -- 7-step evaluation chain (deny/ask/bypass/allow rules)
- **Hook runner** -- 24+ lifecycle event types with exit-code based control flow
- **Task lifecycle management** -- Structured task tracking across agents
- **Thread-safe ExternalToolQueue** -- Mutex + condvar for cross-thread tool result passing
- **DAG-linked messages** -- UUID-based parent linking for branching conversations and undo
- **Context trimming** -- Sliding window strategy to keep conversations within token limits
- **Atomic cancellation** -- `AbortController` with acquire/release semantics

## Quick Start

### Install Zig

Requires Zig **0.14.0** or later. Install from [ziglang.org/download](https://ziglang.org/download/).

### Build

```bash
zig build              # Build library + shared lib
zig build test         # Run all tests (unit + e2e)
zig build napi         # Build NAPI addon -> zig-out/napi/agent_napi.node
```

### Zig Usage

Add as a dependency in your `build.zig.zon`, then import the module:

```zig
const agent = @import("agent");

// Create a provider
var provider = agent.providers.AnthropicProvider.init(allocator, .{
    .id = "anthropic",
    .api_key = api_key,
    .model = "claude-sonnet-4-20250514",
});

// Register tools
var registry = agent.tools.ToolRegistry.init(allocator);
defer registry.deinit();

// Create engine and submit a message
var engine = agent.QueryEngine.init(.{
    .allocator = allocator,
    .provider = &provider.provider(),
    .tools = &registry,
    .system_prompt = "You are a helpful assistant.",
    .max_turns = 10,
});
defer engine.deinit();

var iter = engine.submitMessage("Hello, world!");
while (iter.next()) |event| {
    // Process streaming events
}
```

### Node.js / Bun Usage

Build the NAPI addon first, then use via npm:

```bash
zig build napi -Doptimize=ReleaseFast
```

```js
const {
  createAnthropicProvider,
  createQueryEngine,
  submitMessage,
  nextEvent,
  destroyIterator,
  destroyQueryEngine,
  destroyProvider,
} = require('@zseven-w/agent-native');

const provider = createAnthropicProvider(apiKey, 'claude-sonnet-4-20250514');
const engine = createQueryEngine({
  provider,
  systemPrompt: 'You are a helpful assistant.',
  maxTurns: 10,
  cwd: '.',
});

const iter = await submitMessage(engine, 'Hello');
while (true) {
  const event = await nextEvent(iter);
  if (!event) break;
  console.log(JSON.parse(event));
}

destroyIterator(iter);
destroyQueryEngine(engine);
destroyProvider(provider);
```

## Architecture

### Core Loop

```
QueryEngine -> QueryLoop -> Provider.stream_text() -> EventIterator
```

The agentic loop lives in `query.zig`. `QueryLoopIterator` drives phases: **start -> streaming -> tool_dispatch -> tool_collecting -> yielding_result -> done**. `QueryEngine` is the high-level API that owns the message store, session, and drives the loop.

### FFI Layering

```
Node.js  ->  napi/src/bridge.zig  ->  src/c_api.zig  ->  src/query_engine.zig
                                                      ->  src/providers/*.zig
```

The NAPI bridge wraps C API functions with Node-API calling conventions. `napi/index.js` loads the `.node` addon. TypeScript types are in `napi/ts/index.d.ts`.

### Module Map

| Module | Role |
|--------|------|
| `query_engine` | High-level API: owns messages, session, drives query loop |
| `query` | Agentic loop iterator with phase transitions |
| `providers/` | LLM backends -- Anthropic, OpenAI-compat, Ollama via `Provider` vtable |
| `streaming/events` | `Event` tagged union + `EventIterator` |
| `streaming/tool_executor` | Tracks concurrent tool invocations, yields in receipt order |
| `tool` | `Tool` vtable + `ToolUseContext` DI container + `buildTool()` comptime helper |
| `tools/registry` | `ToolRegistry` -- HashMap of tools by name |
| `message` | `Message` tagged union with `Header` DAG (UUID parent linking) |
| `permission` | 7-step evaluation chain |
| `hook` | `HookRunner` with 24+ event types |
| `context/` | Context trimming -- `SlidingWindowStrategy` |
| `session` | Transcript persistence to disk |
| `file_cache` | LRU `FileStateCache` with eviction |
| `compact` | Token estimation, compaction boundary markers |
| `http/` | `HttpClient` + `SseParser` for streaming API calls |
| `json` | Thin wrappers around `std.json` + `JsonSchema` type |
| `c_api` | C ABI surface: opaque handles for Engine/Provider/Iterator |
| `sub_agent` | Single-task child agent |
| `team` | Leader + member delegation, mailbox messaging |
| `swarm` | Backend registry (in-process, tmux, iTerm2) |
| `task` | Task lifecycle management |
| `external_tool_queue` | Thread-safe queue for JS-side tool dispatch |
| `testing` | `MockProvider` + `FakeTool` for tests |

## NAPI API Reference

All exports from `@zseven-w/agent-native`:

| Function | Signature | Description |
|----------|-----------|-------------|
| `agentVersion` | `() => string` | Returns SDK version |
| `createAnthropicProvider` | `(apiKey, model, baseUrl?) => ProviderHandle` | Create Anthropic provider |
| `createOpenAICompatProvider` | `(apiKey, baseUrl, model) => ProviderHandle` | Create OpenAI-compatible provider |
| `destroyProvider` | `(handle) => void` | Release provider |
| `createToolRegistry` | `() => ToolRegistryHandle` | Create empty tool registry |
| `registerToolSchema` | `(registry, name, schemaJson) => void` | Register a tool schema |
| `destroyToolRegistry` | `(handle) => void` | Release tool registry |
| `createQueryEngine` | `(config) => QueryEngineHandle` | Create query engine |
| `seedMessages` | `(engine, messagesJson) => void` | Seed conversation history |
| `submitMessage` | `(engine, prompt) => Promise<IteratorHandle>` | Submit user message, get event iterator |
| `nextEvent` | `(iterator) => Promise<string \| null>` | Pull next event as JSON (null = done) |
| `resolveToolResult` | `(engine, toolUseId, resultJson) => void` | Resolve external tool call |
| `pushToolProgress` | `(engine, toolUseId, progressJson) => void` | Push tool progress update |
| `abortEngine` | `(engine) => void` | Cancel running query |
| `destroyQueryEngine` | `(handle) => void` | Release engine |
| `destroyIterator` | `(handle) => void` | Release iterator |
| `createSubAgent` | `(provider, tools, systemPrompt, maxTurns) => SubAgentHandle` | Create single-task child agent |
| `subAgentRun` | `(agent, prompt) => Promise<IteratorHandle>` | Run sub-agent |
| `abortSubAgent` | `(agent) => void` | Cancel sub-agent |
| `destroySubAgent` | `(handle) => void` | Release sub-agent |
| `createTeam` | `(provider, tools, systemPrompt, maxTurns) => TeamHandle` | Create agent team |
| `runTeam` | `(team, prompt) => Promise<IteratorHandle>` | Run team |
| `resolveTeamToolResult` | `(team, toolUseId, resultJson) => void` | Resolve team tool call |
| `abortTeam` | `(team) => void` | Cancel team |
| `destroyTeam` | `(handle) => void` | Release team |

## Testing

```bash
zig build test
```

Tests include:
- **Unit tests** -- Discovered through `src/root.zig`, covering all modules
- **E2E smoke test** -- `tests/e2e_smoke_test.zig` demonstrates the full usage pattern: create `MockProvider` with scripted responses, register `FakeTool`, create `QueryEngine`, submit a message, and verify events

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feat/my-feature`)
3. Make your changes and add tests
4. Run `zig build test` to verify
5. Commit using [Conventional Commits](https://www.conventionalcommits.org/) format
6. Open a pull request

## License

[MIT](LICENSE) -- Copyright 2026 ZSeven-W
