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
) AgentProviderHandle {
    const allocator = std.heap.c_allocator;
    const provider = allocator.create(providers_mod.AnthropicProvider) catch return null;
    provider.* = providers_mod.AnthropicProvider.init(allocator, .{
        .id = "anthropic",
        .api_key = api_key_ptr[0..api_key_len],
        .model = model_ptr[0..model_len],
    });
    return @ptrCast(provider);
}

// ─── QueryEngine lifecycle ───

export fn agent_create_engine(
    provider_handle: AgentProviderHandle,
    system_prompt_ptr: ?[*]const u8,
    system_prompt_len: usize,
    max_turns: u32,
) AgentEngineHandle {
    if (provider_handle == null) return null;
    const allocator = std.heap.c_allocator;

    const provider_impl: *providers_mod.AnthropicProvider = @ptrCast(@alignCast(provider_handle.?));

    // Heap-allocate the Provider interface so its lifetime outlives this function.
    const provider_iface_ptr = allocator.create(providers_types.Provider) catch return null;
    provider_iface_ptr.* = provider_impl.provider();

    const perm_ctx = allocator.create(perm.PermissionContext) catch return null;
    perm_ctx.* = .{};
    const hook_runner = allocator.create(hook_mod.HookRunner) catch return null;
    hook_runner.* = hook_mod.HookRunner.init(allocator);
    const reg = allocator.create(tools_reg.ToolRegistry) catch return null;
    reg.* = tools_reg.ToolRegistry.init(allocator);
    const sw = allocator.create(context_mod.SlidingWindowStrategy) catch return null;
    sw.* = context_mod.SlidingWindowStrategy.init(20);
    const strategy_ptr = allocator.create(context_mod.ContextStrategy) catch return null;
    strategy_ptr.* = sw.strategy();

    const system_prompt: ?[]const u8 = if (system_prompt_ptr) |p| p[0..system_prompt_len] else null;

    const engine = allocator.create(QueryEngine) catch return null;
    engine.* = QueryEngine.init(.{
        .allocator = allocator,
        .provider = provider_iface_ptr,
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
    const provider = allocator.create(providers_mod.OpenAICompatProvider) catch return null;
    provider.* = providers_mod.OpenAICompatProvider.init(allocator, .{
        .base = .{
            .id = "openai_compat",
            .api_key = api_key_ptr[0..api_key_len],
            .base_url = base_url_ptr[0..base_url_len],
            .model = model_ptr[0..model_len],
        },
    });
    return @ptrCast(provider);
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

/// Stub: schema-only tool registration (no execute fn). Records the name for
/// permission checks; the actual call is expected to be resolved externally
/// (e.g. via NAPI resolveToolResult).
export fn agent_register_tool_schema(
    registry_handle: ?*anyopaque,
    _: [*]const u8, // name_ptr (unused in stub)
    _: usize,       // name_len
    _: [*]const u8, // schema_json_ptr (unused in stub)
    _: usize,       // schema_json_len
) void {
    _ = registry_handle; // stub — will wire up in a later task
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
    const iter_ptr = allocator.create(streaming_mod.EventIterator) catch return null;
    iter_ptr.* = engine.submitMessage(prompt_ptr[0..prompt_len]);
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

// ─── Tool result resolution (stubs — full impl in query_engine future task) ───

export fn agent_resolve_tool_result(
    engine_handle: AgentEngineHandle,
    _: [*]const u8, // tool_use_id_ptr
    _: usize,       // tool_use_id_len
    _: [*]const u8, // result_json_ptr
    _: usize,       // result_json_len
) void {
    _ = engine_handle; // stub until QueryEngine gains resolveToolResult
}

export fn agent_push_tool_progress(
    engine_handle: AgentEngineHandle,
    _: [*]const u8, // tool_use_id_ptr
    _: usize,       // tool_use_id_len
    _: [*]const u8, // progress_json_ptr
    _: usize,       // progress_json_len
) void {
    _ = engine_handle; // stub until QueryEngine gains pushToolProgress
}
