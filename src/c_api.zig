// src/c_api.zig
//! C ABI exports for non-Zig consumers.
//! Exposes QueryEngine lifecycle, Provider creation, and Event polling.

const std = @import("std");
const query_engine_mod = @import("query_engine.zig");
const providers_mod = @import("providers.zig");
const providers_types = @import("providers/types.zig");
const streaming_mod = @import("streaming.zig");
const perm = @import("permission.zig");
const hook_mod = @import("hook.zig");
const tools_reg = @import("tools/registry.zig");
const context_mod = @import("context.zig");
const json_mod = @import("json.zig");

const QueryEngine = query_engine_mod.QueryEngine;

// ─── Opaque handle types ───

pub const AgentEngineHandle = ?*anyopaque;
pub const AgentEventIterHandle = ?*anyopaque;
pub const AgentProviderHandle = ?*anyopaque;

// ─── Version ───

export fn agent_version() [*:0]const u8 {
    return "0.1.0";
}

// ─── Provider creation ───

export fn agent_create_anthropic_provider(
    api_key_ptr: [*]const u8,
    api_key_len: usize,
    model_ptr: [*]const u8,
    model_len: usize,
    base_url_ptr: ?[*]const u8,
    base_url_len: usize,
) AgentProviderHandle {
    const allocator = std.heap.c_allocator;
    // Heap-duplicate all strings — caller's buffers are on the stack.
    const api_key = allocator.dupe(u8, api_key_ptr[0..api_key_len]) catch return null;
    const model = allocator.dupe(u8, model_ptr[0..model_len]) catch return null;
    const base_url: ?[]const u8 = if (base_url_ptr) |p|
        (allocator.dupe(u8, p[0..base_url_len]) catch return null)
    else
        null;
    const impl = allocator.create(providers_mod.AnthropicProvider) catch return null;
    impl.* = providers_mod.AnthropicProvider.init(allocator, .{
        .id = "anthropic",
        .api_key = api_key,
        .model = model,
        .base_url = base_url,
    });
    // Heap-allocate vtable — Zig 0.15 may place `&vtable` (comptime const) on the
    // stack as a temporary, making it a dangling pointer after provider() returns.
    const vtable_ptr = allocator.create(providers_types.Provider.VTable) catch return null;
    vtable_ptr.* = .{
        .id = "anthropic",
        .max_context_tokens = 200_000,
        .supports_thinking = true,
        .supports_tool_use = true,
        .stream_text = providers_mod.AnthropicProvider.streamTextFn(),
    };
    const iface = allocator.create(providers_types.Provider) catch return null;
    iface.* = .{
        .ptr = @ptrCast(impl),
        .vtable = vtable_ptr,
    };
    return @ptrCast(iface);
}

// ─── QueryEngine lifecycle ───

export fn agent_create_engine(
    provider_handle: AgentProviderHandle,
    tools_handle: ?*anyopaque,
    system_prompt_ptr: ?[*]const u8,
    system_prompt_len: usize,
    max_turns: u32,
) AgentEngineHandle {
    if (provider_handle == null) return null;
    const allocator = std.heap.c_allocator;

    const provider_ptr: *providers_types.Provider = @ptrCast(@alignCast(provider_handle.?));

    const perm_ctx = allocator.create(perm.PermissionContext) catch return null;
    perm_ctx.* = .{};
    const hook_runner = allocator.create(hook_mod.HookRunner) catch return null;
    hook_runner.* = hook_mod.HookRunner.init(allocator);

    // Use provided tool registry or create an empty one
    const reg: *tools_reg.ToolRegistry = if (tools_handle) |th|
        @ptrCast(@alignCast(th))
    else blk: {
        const new_reg = allocator.create(tools_reg.ToolRegistry) catch return null;
        new_reg.* = tools_reg.ToolRegistry.init(allocator);
        break :blk new_reg;
    };

    const sw = allocator.create(context_mod.SlidingWindowStrategy) catch return null;
    sw.* = context_mod.SlidingWindowStrategy.init(20);
    const strategy_ptr = allocator.create(context_mod.ContextStrategy) catch return null;
    strategy_ptr.* = sw.strategy();

    // Heap-duplicate system_prompt — the caller's buffer is on the stack and will be freed.
    const system_prompt: ?[]const u8 = if (system_prompt_ptr) |p|
        (allocator.dupe(u8, p[0..system_prompt_len]) catch return null)
    else
        null;

    const engine = allocator.create(QueryEngine) catch return null;
    engine.* = QueryEngine.init(.{
        .allocator = allocator,
        .provider = provider_ptr,
        .tools = reg,
        .permission_ctx = perm_ctx,
        .hook_runner = hook_runner,
        .context_strategy = strategy_ptr,
        .system_prompt = system_prompt,
        .max_turns = if (max_turns > 0) max_turns else 50,
    });
    return @ptrCast(engine);
}

export fn agent_destroy_engine(handle: AgentEngineHandle) void {
    if (handle == null) return;
    const engine: *QueryEngine = @ptrCast(@alignCast(handle.?));
    engine.deinit();
    std.heap.c_allocator.destroy(engine);
}

// ─── OpenAI-compat provider ───

export fn agent_create_openai_compat_provider(
    api_key_ptr: [*]const u8,
    api_key_len: usize,
    base_url_ptr: [*]const u8,
    base_url_len: usize,
    model_ptr: [*]const u8,
    model_len: usize,
) AgentProviderHandle {
    const allocator = std.heap.c_allocator;
    const api_key = allocator.dupe(u8, api_key_ptr[0..api_key_len]) catch return null;
    const base_url = allocator.dupe(u8, base_url_ptr[0..base_url_len]) catch return null;
    const model = allocator.dupe(u8, model_ptr[0..model_len]) catch return null;
    const impl = allocator.create(providers_mod.OpenAICompatProvider) catch return null;
    impl.* = providers_mod.OpenAICompatProvider.init(allocator, .{
        .base = .{
            .id = "openai_compat",
            .api_key = api_key,
            .base_url = base_url,
            .model = model,
        },
    });
    // Heap-allocate vtable (same Zig 0.15 workaround as anthropic provider)
    const vtable_ptr = allocator.create(providers_types.Provider.VTable) catch return null;
    vtable_ptr.* = .{
        .id = "openai_compat",
        .max_context_tokens = 128_000,
        .supports_thinking = false,
        .supports_tool_use = true,
        .stream_text = providers_mod.OpenAICompatProvider.streamTextFn(),
    };
    const iface = allocator.create(providers_types.Provider) catch return null;
    iface.* = .{
        .ptr = @ptrCast(impl),
        .vtable = vtable_ptr,
    };
    return @ptrCast(iface);
}

/// No-op: providers are freed on engine destroy. Stub for API completeness.
export fn agent_destroy_provider(_: AgentProviderHandle) void {}

// ─── Tool registry ───

export fn agent_create_tool_registry() ?*anyopaque {
    const allocator = std.heap.c_allocator;
    const reg = allocator.create(tools_reg.ToolRegistry) catch return null;
    reg.* = tools_reg.ToolRegistry.init(allocator);
    return @ptrCast(reg);
}

/// Register a schema-only tool (no execute fn). Records the name and schema for
/// permission checks and API requests; the actual call is expected to be resolved
/// externally (e.g. via NAPI resolveToolResult).
export fn agent_register_tool_schema(
    registry_handle: ?*anyopaque,
    name_ptr: [*]const u8,
    name_len: usize,
    schema_json_ptr: [*]const u8,
    schema_json_len: usize,
) void {
    if (registry_handle == null) return;
    const reg: *tools_reg.ToolRegistry = @ptrCast(@alignCast(registry_handle.?));
    const allocator = std.heap.c_allocator;

    // Parse JSON Schema
    const parsed = json_mod.parse(allocator, schema_json_ptr[0..schema_json_len]) catch return;
    // Note: we intentionally don't deinit parsed — ToolSchema references the parsed JSON values

    // Extract description from schema if present
    const desc = if (parsed.value == .object)
        if (parsed.value.object.get("description")) |d| switch (d) {
            .string => |s| s,
            else => "",
        } else ""
    else
        "";

    reg.registerSchema(.{
        .name = allocator.dupe(u8, name_ptr[0..name_len]) catch return,
        .description = allocator.dupe(u8, desc) catch return,
        .input_schema = parsed.value,
    }) catch {};
}

export fn agent_destroy_tool_registry(handle: ?*anyopaque) void {
    if (handle == null) return;
    const reg: *tools_reg.ToolRegistry = @ptrCast(@alignCast(handle.?));
    reg.deinit();
    std.heap.c_allocator.destroy(reg);
}

// ─── Event polling ───

export fn agent_next_event(iter_handle: AgentEventIterHandle) i32 {
    if (iter_handle == null) return -1;
    const iter: *streaming_mod.EventIterator = @ptrCast(@alignCast(iter_handle.?));
    if (iter.next()) |_| {
        return 1; // has event
    }
    return 0; // done
}

// ─── Submit message + iterator lifecycle ───

export fn agent_submit_message(
    engine_handle: AgentEngineHandle,
    prompt_ptr: [*]const u8,
    prompt_len: usize,
) AgentEventIterHandle {
    if (engine_handle == null) return null;
    const engine: *QueryEngine = @ptrCast(@alignCast(engine_handle.?));
    const allocator = std.heap.c_allocator;
    // Heap-duplicate prompt — the caller's buffer is on the stack and will be freed.
    const prompt = allocator.dupe(u8, prompt_ptr[0..prompt_len]) catch return null;
    const iter_ptr = allocator.create(streaming_mod.EventIterator) catch return null;
    iter_ptr.* = engine.submitMessage(prompt);
    return @ptrCast(iter_ptr);
}

export fn agent_destroy_iterator(iter_handle: AgentEventIterHandle) void {
    if (iter_handle == null) return;
    const iter: *streaming_mod.EventIterator = @ptrCast(@alignCast(iter_handle.?));
    std.heap.c_allocator.destroy(iter);
}

// ─── Event → JSON ───

/// Returns next event serialized as JSON, or null if the iterator is done.
/// The returned pointer is heap-allocated; caller must free via agent_free_string.
export fn agent_event_to_json(
    iter_handle: AgentEventIterHandle,
    out_len: *usize,
) ?[*]u8 {
    if (iter_handle == null) return null;
    const iter: *streaming_mod.EventIterator = @ptrCast(@alignCast(iter_handle.?));
    const event = iter.next() orelse {
        out_len.* = 0;
        return null;
    };
    const allocator = std.heap.c_allocator;
    const json_str = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(event, .{})}) catch return null;
    out_len.* = json_str.len;
    return @ptrCast(json_str.ptr);
}

export fn agent_free_string(ptr: [*]u8, len: usize) void {
    std.heap.c_allocator.free(ptr[0..len]);
}

// ─── Tool result resolution ───

export fn agent_resolve_tool_result(
    engine_handle: AgentEngineHandle,
    tool_use_id_ptr: [*]const u8,
    tool_use_id_len: usize,
    result_json_ptr: [*]const u8,
    result_json_len: usize,
) void {
    if (engine_handle == null) return;
    const engine: *QueryEngine = @ptrCast(@alignCast(engine_handle.?));
    engine.resolveToolResult(
        tool_use_id_ptr[0..tool_use_id_len],
        result_json_ptr[0..result_json_len],
    );
}

export fn agent_push_tool_progress(
    engine_handle: AgentEngineHandle,
    tool_use_id_ptr: [*]const u8,
    tool_use_id_len: usize,
    progress_json_ptr: [*]const u8,
    progress_json_len: usize,
) void {
    if (engine_handle == null) return;
    const engine: *QueryEngine = @ptrCast(@alignCast(engine_handle.?));
    engine.pushToolProgress(
        tool_use_id_ptr[0..tool_use_id_len],
        progress_json_ptr[0..progress_json_len],
    );
}

// ─── Seed messages + abort ───

export fn agent_seed_messages(
    engine_handle: AgentEngineHandle,
    json_ptr: [*]const u8,
    json_len: usize,
) void {
    if (engine_handle == null) return;
    const engine: *QueryEngine = @ptrCast(@alignCast(engine_handle.?));
    engine.seedMessages(json_ptr[0..json_len]) catch {};
}

export fn agent_abort_engine(engine_handle: AgentEngineHandle) void {
    if (engine_handle == null) return;
    const engine: *QueryEngine = @ptrCast(@alignCast(engine_handle.?));
    engine.abortQuery(null);
}

// ─── SubAgent ───

const sub_agent_mod = @import("sub_agent.zig");

export fn agent_create_sub_agent(
    provider_handle: AgentProviderHandle,
    tools_handle: ?*anyopaque,
    system_prompt_ptr: ?[*]const u8,
    system_prompt_len: usize,
    max_turns: u32,
) ?*anyopaque {
    if (provider_handle == null) return null;
    const allocator = std.heap.c_allocator;
    const provider_ptr: *providers_types.Provider = @ptrCast(@alignCast(provider_handle.?));
    const tools = if (tools_handle) |h| @as(*tools_reg.ToolRegistry, @ptrCast(@alignCast(h))) else blk: {
        const r = allocator.create(tools_reg.ToolRegistry) catch return null;
        r.* = tools_reg.ToolRegistry.init(allocator);
        break :blk r;
    };

    const sa = allocator.create(sub_agent_mod.SubAgent) catch return null;
    sa.* = sub_agent_mod.SubAgent.init(.{
        .allocator = allocator,
        .provider = provider_ptr,
        .tools = tools,
        .system_prompt = if (system_prompt_ptr) |p| p[0..system_prompt_len] else null,
        .max_turns = if (max_turns > 0) max_turns else 50,
    }) catch return null;
    return @ptrCast(sa);
}

export fn agent_sub_agent_run(handle: ?*anyopaque, prompt_ptr: [*]const u8, prompt_len: usize) AgentEventIterHandle {
    if (handle == null) return null;
    const sa: *sub_agent_mod.SubAgent = @ptrCast(@alignCast(handle.?));
    const allocator = std.heap.c_allocator;
    const iter_ptr = allocator.create(streaming_mod.EventIterator) catch return null;
    iter_ptr.* = sa.run(prompt_ptr[0..prompt_len]);
    return @ptrCast(iter_ptr);
}

export fn agent_abort_sub_agent(handle: ?*anyopaque) void {
    if (handle == null) return;
    const sa: *sub_agent_mod.SubAgent = @ptrCast(@alignCast(handle.?));
    sa.abort();
}

export fn agent_destroy_sub_agent(handle: ?*anyopaque) void {
    if (handle == null) return;
    const sa: *sub_agent_mod.SubAgent = @ptrCast(@alignCast(handle.?));
    sa.deinit();
    std.heap.c_allocator.destroy(sa);
}

// ─── Team ───

const team_mod = @import("team.zig");

export fn agent_create_team(
    lead_provider: AgentProviderHandle,
    lead_tools: ?*anyopaque,
    lead_system_prompt_ptr: ?[*]const u8,
    lead_system_prompt_len: usize,
    lead_max_turns: u32,
) ?*anyopaque {
    if (lead_provider == null) return null;
    const allocator = std.heap.c_allocator;
    const provider_ptr: *providers_types.Provider = @ptrCast(@alignCast(lead_provider.?));
    const tools = if (lead_tools) |h| @as(*tools_reg.ToolRegistry, @ptrCast(@alignCast(h))) else blk: {
        const r = allocator.create(tools_reg.ToolRegistry) catch return null;
        r.* = tools_reg.ToolRegistry.init(allocator);
        break :blk r;
    };

    // Heap-duplicate system_prompt — the caller's buffer is on the stack and will be freed.
    const lead_system_prompt: ?[]const u8 = if (lead_system_prompt_ptr) |p|
        (allocator.dupe(u8, p[0..lead_system_prompt_len]) catch return null)
    else
        null;

    const t = allocator.create(team_mod.Team) catch return null;
    t.* = team_mod.Team.init(.{
        .allocator = allocator,
        .lead_provider = provider_ptr,
        .lead_tools = tools,
        .lead_system_prompt = lead_system_prompt,
        .lead_max_turns = if (lead_max_turns > 0) lead_max_turns else 20,
        .members = &.{},
    }) catch return null;
    return @ptrCast(t);
}

export fn agent_team_add_member(
    team_handle: ?*anyopaque,
    member_id_ptr: [*]const u8,
    member_id_len: usize,
    provider_handle: AgentProviderHandle,
    tools_handle: ?*anyopaque,
    system_prompt_ptr: ?[*]const u8,
    system_prompt_len: usize,
    max_turns: u32,
) bool {
    if (team_handle == null or provider_handle == null or tools_handle == null) return false;
    const allocator = std.heap.c_allocator;
    const t: *team_mod.Team = @ptrCast(@alignCast(team_handle.?));
    const provider_ptr: *providers_types.Provider = @ptrCast(@alignCast(provider_handle.?));
    const tools: *tools_reg.ToolRegistry = @ptrCast(@alignCast(tools_handle.?));

    // Heap-duplicate strings — caller's buffers are on the stack and will be freed.
    const id = allocator.dupe(u8, member_id_ptr[0..member_id_len]) catch return false;
    const system_prompt: ?[]const u8 = if (system_prompt_ptr) |p|
        (allocator.dupe(u8, p[0..system_prompt_len]) catch return false)
    else
        null;

    t.addMember(.{
        .id = id,
        .provider = provider_ptr,
        .tools = tools,
        .system_prompt = system_prompt,
        .max_turns = if (max_turns > 0) max_turns else 20,
    }) catch return false;

    return true;
}

export fn agent_team_run(handle: ?*anyopaque, prompt_ptr: [*]const u8, prompt_len: usize) AgentEventIterHandle {
    if (handle == null) return null;
    const t: *team_mod.Team = @ptrCast(@alignCast(handle.?));
    const allocator = std.heap.c_allocator;
    const iter_ptr = allocator.create(streaming_mod.EventIterator) catch return null;
    iter_ptr.* = t.run(prompt_ptr[0..prompt_len]);
    return @ptrCast(iter_ptr);
}

export fn agent_resolve_team_tool_result(handle: ?*anyopaque, id_ptr: [*]const u8, id_len: usize, res_ptr: [*]const u8, res_len: usize) void {
    if (handle == null) return;
    const t: *team_mod.Team = @ptrCast(@alignCast(handle.?));
    t.resolveTeamToolResult(id_ptr[0..id_len], res_ptr[0..res_len]);
}

export fn agent_abort_team(handle: ?*anyopaque) void {
    if (handle == null) return;
    const t: *team_mod.Team = @ptrCast(@alignCast(handle.?));
    t.abortTeam();
}

export fn agent_team_register_delegate(team_handle: ?*anyopaque) bool {
    if (team_handle == null) return false;
    const t: *team_mod.Team = @ptrCast(@alignCast(team_handle.?));
    t.registerDelegateTool() catch return false;
    return true;
}

export fn agent_team_run_member(
    team_handle: ?*anyopaque,
    member_id_ptr: [*]const u8,
    member_id_len: usize,
    task_ptr: [*]const u8,
    task_len: usize,
) AgentEventIterHandle {
    if (team_handle == null) return null;
    const allocator = std.heap.c_allocator;
    const t: *team_mod.Team = @ptrCast(@alignCast(team_handle.?));
    const member = t.getMember(member_id_ptr[0..member_id_len]) orelse return null;

    // Heap-duplicate task string
    const task = allocator.dupe(u8, task_ptr[0..task_len]) catch return null;

    const iter_ptr = allocator.create(streaming_mod.EventIterator) catch return null;
    iter_ptr.* = member.submitMessage(task);
    return @ptrCast(iter_ptr);
}

export fn agent_destroy_team(handle: ?*anyopaque) void {
    if (handle == null) return;
    const t: *team_mod.Team = @ptrCast(@alignCast(handle.?));
    t.deinit();
    std.heap.c_allocator.destroy(t);
}

export fn agent_resolve_member_tool_result(
    team_handle: ?*anyopaque,
    member_id_ptr: [*]const u8,
    member_id_len: usize,
    tool_use_id_ptr: [*]const u8,
    tool_use_id_len: usize,
    result_json_ptr: [*]const u8,
    result_json_len: usize,
) void {
    if (team_handle == null) return;
    const t: *team_mod.Team = @ptrCast(@alignCast(team_handle.?));
    const member = t.getMember(member_id_ptr[0..member_id_len]) orelse return;
    member.resolveToolResult(
        tool_use_id_ptr[0..tool_use_id_len],
        result_json_ptr[0..result_json_len],
    );
}

export fn agent_team_seed_messages(
    team_handle: ?*anyopaque,
    json_ptr: [*]const u8,
    json_len: usize,
) void {
    if (team_handle == null) return;
    const t: *team_mod.Team = @ptrCast(@alignCast(team_handle.?));
    t.seedMessages(json_ptr[0..json_len]) catch {};
}
