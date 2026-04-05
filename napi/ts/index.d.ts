// Auto-generated TypeScript types for @zseven-w/agent-native
// Node-API addon — Zig agent SDK bindings (stable ABI, NAPI v8)

export type ProviderHandle = object & { readonly __brand: "ProviderHandle" };
export type ToolRegistryHandle = object & { readonly __brand: "ToolRegistryHandle" };
export type QueryEngineHandle = object & { readonly __brand: "QueryEngineHandle" };
export type IteratorHandle = object & { readonly __brand: "IteratorHandle" };

export interface AgentEvent {
  type: string;
  [key: string]: unknown;
}

// ─── Provider lifecycle ───
export declare function createAnthropicProvider(apiKey: string, model: string, baseUrl?: string, maxContextTokens?: number): ProviderHandle;
export declare function createOpenAICompatProvider(apiKey: string, baseUrl: string, model: string, maxContextTokens?: number): ProviderHandle;
export declare function destroyProvider(handle: ProviderHandle): void;

// ─── Tool registry ───
export declare function createToolRegistry(): ToolRegistryHandle;
export declare function registerToolSchema(registry: ToolRegistryHandle, name: string, schemaJson: string): void;
export declare function destroyToolRegistry(handle: ToolRegistryHandle): void;

// ─── Query engine lifecycle ───
export declare function createQueryEngine(config: {
  provider: ProviderHandle;
  tools?: ToolRegistryHandle;
  systemPrompt?: string;
  maxTurns?: number;
  maxOutputTokens?: number;
  cwd: string;
}): QueryEngineHandle;
export declare function seedMessages(engine: QueryEngineHandle, messagesJson: string): void;
export declare function submitMessage(engine: QueryEngineHandle, prompt: string): Promise<IteratorHandle>;
export declare function nextEvent(iterator: IteratorHandle): Promise<string | null>;
export declare function resolveToolResult(engine: QueryEngineHandle, toolUseId: string, resultJson: string): void;
export declare function pushToolProgress(engine: QueryEngineHandle, toolUseId: string, progressJson: string): void;
export declare function abortEngine(engine: QueryEngineHandle): void;
export declare function destroyQueryEngine(handle: QueryEngineHandle): void;
export declare function destroyIterator(handle: IteratorHandle): void;

// ─── Utility ───
export declare function agentVersion(): string;

// ─── SubAgent ───
export type SubAgentHandle = object & { readonly __brand: "SubAgentHandle" };
export declare function createSubAgent(provider: ProviderHandle, tools: ToolRegistryHandle | null, systemPrompt: string, maxTurns: number): SubAgentHandle;
export declare function subAgentRun(agent: SubAgentHandle, prompt: string): Promise<IteratorHandle>;
export declare function abortSubAgent(agent: SubAgentHandle): void;
export declare function destroySubAgent(handle: SubAgentHandle): void;

// ─── Team ───
export type TeamHandle = object & { readonly __brand: "TeamHandle" };
export declare function createTeam(leadProvider: ProviderHandle, leadTools: ToolRegistryHandle | null, leadSystemPrompt: string, leadMaxTurns: number, leadMaxOutputTokens?: number): TeamHandle;
export declare function addTeamMember(
  team: TeamHandle,
  memberId: string,
  provider: ProviderHandle,
  tools: ToolRegistryHandle,
  systemPrompt: string,
  maxTurns: number,
): void;
export declare function runTeam(team: TeamHandle, prompt: string): Promise<IteratorHandle>;
export declare function resolveTeamToolResult(team: TeamHandle, toolUseId: string, resultJson: string): void;
export declare function abortTeam(team: TeamHandle): void;
export declare function destroyTeam(handle: TeamHandle): void;
export declare function teamRegisterDelegate(team: TeamHandle): void;
export declare function runTeamMember(team: TeamHandle, memberId: string, task: string): Promise<IteratorHandle>;
export declare function resolveMemberToolResult(
  team: TeamHandle, memberId: string, toolUseId: string, resultJson: string
): void;
export declare function seedTeamMessages(team: TeamHandle, messagesJson: string): void;
