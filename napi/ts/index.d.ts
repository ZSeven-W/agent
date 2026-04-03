// Auto-generated TypeScript types for @zseven-w/agent-native
// Node-API addon — Zig agent SDK bindings (stable ABI, NAPI v8)

export type ProviderHandle = object & { readonly __brand: "ProviderHandle" };
export type ToolRegistryHandle = object & { readonly __brand: "ToolRegistryHandle" };
export type QueryEngineHandle = object & { readonly __brand: "QueryEngineHandle" };
export type IteratorHandle = object & { readonly __brand: "IteratorHandle" };

export interface AnthropicConfig {
  apiKey: string;
  model: string;
}

export interface OpenAICompatConfig {
  apiKey: string;
  baseUrl: string;
  model: string;
}

export interface QueryEngineConfig {
  provider: ProviderHandle;
  tools: ToolRegistryHandle;
  systemPrompt?: string;
  maxTurns?: number;
  cwd: string;
}

export interface ToolSchema {
  name: string;
  description: string;
  parameters: Record<string, unknown>; // JSON Schema
}

export interface AgentEvent {
  type: string;
  [key: string]: unknown;
}

// ─── Provider lifecycle ───
export declare function createAnthropicProvider(apiKey: string, model: string): ProviderHandle;
export declare function createOpenAICompatProvider(apiKey: string, baseUrl: string, model: string): ProviderHandle;
export declare function destroyProvider(handle: ProviderHandle): void;

// ─── Tool registry ───
export declare function createToolRegistry(): ToolRegistryHandle;
export declare function registerToolSchema(registry: ToolRegistryHandle, name: string, schemaJson: string): void;
export declare function destroyToolRegistry(handle: ToolRegistryHandle): void;

// ─── Query engine lifecycle ───
export declare function createQueryEngine(config: QueryEngineConfig): QueryEngineHandle;
export declare function submitMessage(engine: QueryEngineHandle, prompt: string): IteratorHandle;

// nextEvent returns the next event as a JSON string, or null when the
// iterator is exhausted. Parse with JSON.parse() on the JS side.
export declare function nextEvent(iterator: IteratorHandle): string | null;
export declare function resolveToolResult(engine: QueryEngineHandle, toolUseId: string, resultJson: string): void;
export declare function pushToolProgress(engine: QueryEngineHandle, toolUseId: string, progressJson: string): void;
export declare function destroyQueryEngine(handle: QueryEngineHandle): void;
export declare function destroyIterator(handle: IteratorHandle): void;

// ─── Utility ───
export declare function agentVersion(): string;
