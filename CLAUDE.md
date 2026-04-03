# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Zig SDK for building agentic LLM applications. Three build targets:

1. **Zig module** (`src/root.zig`) — for `@import("agent")` consumers
2. **C ABI shared library** (`src/c_api.zig`) — `libagent.so`/`.dylib` for FFI
3. **NAPI addon** (`napi/src/bridge.zig`) — `agent_napi.node` for Node.js

Zero external dependencies — Zig standard library only.

## Commands

```bash
zig build              # Build all (lib + shared lib)
zig build test         # Run all tests (unit via root.zig + e2e smoke test)
zig build napi         # Build NAPI addon → zig-out/napi/agent_napi.node
```

Minimum Zig version: **0.14.0**

## Architecture

### Core Loop

`QueryEngine` → `QueryLoop` → `Provider.stream_text()` → `EventIterator`

The agentic loop lives in `src/query.zig`. `QueryLoopIterator` drives phases: **start → streaming → tool_dispatch → tool_collecting → yielding_result → done**. `QueryEngine` (`src/query_engine.zig`) is the high-level API that owns the message store, session, and drives the loop.

### Key Design Patterns

- **VTable polymorphism**: `Tool`, `Provider`, and `ContextStrategy` all use type-erased `ptr` + function table for runtime dispatch. `buildTool(T, impl)` generates VTables at comptime from struct declarations.
- **Dependency injection**: `ToolUseContext` carries all context (allocator, cwd, abort, file_cache, permissions, hooks) — tools receive it, never reach for globals.
- **Pull-based streaming**: `EventIterator` with `next()` callback for lazy evaluation.
- **DAG-linked messages**: Every `Message` carries a `Header` with `uuid` and `parent_uuid`, enabling branching conversations and undo.
- **Receipt-order tool yielding**: `StreamingToolExecutor` yields tool results in the order they were requested, not completion order.
- **Atomic cancellation**: `AbortController` with acquire/release semantics.

### Module Map

| Module | Role |
|--------|------|
| `query_engine` | High-level API: owns messages, session, drives query loop |
| `query` | Agentic loop iterator with phase transitions (tool_use, compact, escalate) |
| `providers/` | LLM backends — `anthropic`, `openai_compat`, `ollama` via `Provider` VTable |
| `streaming/events` | `Event` tagged union (text_delta, tool_use, thinking, result, etc.) + `EventIterator` |
| `streaming/tool_executor` | Tracks concurrent tool invocations, yields in receipt order |
| `tool` | `Tool` VTable + `ToolUseContext` DI container + `buildTool()` comptime helper |
| `tools/registry` | `ToolRegistry` — StringHashMap of Tool by name |
| `message` | `Message` tagged union (User/Assistant/System/Progress/Tombstone) with `Header` DAG |
| `permission` | 7-step evaluation chain: deny rules → ask rules → tool callback → bypass → allow rules → default ask → dont_ask deny |
| `hook` | `HookRunner` with 24+ event types; exit 0=ok, 2=block, other=warn |
| `context/` | Context trimming — `SlidingWindowStrategy` keeps last N logical turns |
| `session` | Transcript persistence to disk with retry-flush |
| `file_cache` | LRU `FileStateCache` with max_entries + max_size_bytes eviction |
| `compact` | Token estimation (4 chars ≈ 1 token), compaction boundary markers |
| `http/` | `HttpClient` + `SseParser` for streaming API calls |
| `json` | Thin wrappers around `std.json` + `JsonSchema` type |
| `c_api` | C ABI surface: opaque handles for Engine/Provider/Iterator/ToolRegistry |
| `testing` | `MockProvider` (scripted responses) + `FakeTool` (records calls) |

### FFI Layering

```
Node.js  →  napi/src/bridge.zig  →  src/c_api.zig  →  src/query_engine.zig
                                                    →  src/providers/*.zig
```

The NAPI bridge (`napi/src/bridge.zig`) wraps C API functions with Node-API calling conventions. `napi/index.js` loads the `.node` addon (tries `zig-out/napi/` first, then bundled). TypeScript types are in `napi/ts/index.d.ts`.

### Testing

Unit tests are discovered through `src/root.zig` (which re-exports all modules). The E2E smoke test (`tests/e2e_smoke_test.zig`) demonstrates the standard usage pattern:

1. Create `MockProvider` with scripted responses
2. Register `FakeTool` in a `ToolRegistry`
3. Create `QueryEngine` with bypass permissions
4. `submitMessage()` → consume `EventIterator` → verify events and tool calls
