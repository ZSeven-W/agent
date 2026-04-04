// napi/src/bridge.zig
//! Node-API (NAPI) bridge — wraps agent C ABI as a Node.js native addon.
//!
//! Uses the Node-API stable ABI (NAPI_VERSION >= 6).
//!
//! JS signatures (see ../ts/index.d.ts):
//!   agentVersion() → string
//!   createAnthropicProvider(apiKey, model, baseUrl?) → handle
//!   createOpenAICompatProvider(apiKey, baseUrl, model) → handle
//!   destroyProvider(handle) → void
//!   createToolRegistry() → handle
//!   registerToolSchema(registry, name, schemaJson) → void
//!   destroyToolRegistry(handle) → void
//!   createQueryEngine({ provider, tools, systemPrompt, maxTurns, cwd }) → handle
//!   submitMessage(engine, prompt) → Promise<iterHandle>
//!   nextEvent(iter) → Promise<string | null>
//!   seedMessages(engine, jsonArray) → void
//!   abortEngine(engine) → void
//!   resolveToolResult(engine, toolUseId, resultJson) → void
//!   pushToolProgress(engine, toolUseId, progressJson) → void
//!   destroyQueryEngine(handle) → void
//!   destroyIterator(handle) → void
//!   createSubAgent(provider, tools, systemPrompt, maxTurns) → handle
//!   subAgentRun(agent, prompt) → Promise<iterHandle>
//!   abortSubAgent(agent) → void
//!   destroySubAgent(handle) → void
//!   createTeam(leadProvider, leadTools, leadSystemPrompt, leadMaxTurns) → handle
//!   runTeam(team, prompt) → Promise<iterHandle>
//!   resolveTeamToolResult(team, toolUseId, resultJson) → void
//!   abortTeam(team) → void
//!   destroyTeam(handle) → void

const std = @import("std");

// ─── Node-API type declarations ───────────────────────────────────────────────

const napi_env = *anyopaque;
const napi_value = *anyopaque;
const napi_callback_info = *anyopaque;
const napi_callback = *const fn (napi_env, napi_callback_info) callconv(.c) napi_value;
const napi_finalize = *const fn (napi_env, ?*anyopaque, ?*anyopaque) callconv(.c) void;

const napi_status = enum(c_int) {
    ok = 0,
    _,
};

extern fn napi_create_function(env: napi_env, utf8name: [*:0]const u8, length: usize, cb: napi_callback, data: ?*anyopaque, result: *napi_value) napi_status;
extern fn napi_set_named_property(env: napi_env, object: napi_value, utf8name: [*:0]const u8, value: napi_value) napi_status;
extern fn napi_get_cb_info(env: napi_env, cbinfo: napi_callback_info, argc: *usize, argv: ?[*]napi_value, this_arg: ?*napi_value, data: ?*?*anyopaque) napi_status;
extern fn napi_get_value_string_utf8(env: napi_env, value: napi_value, buf: ?[*]u8, bufsize: usize, result: *usize) napi_status;
extern fn napi_create_string_utf8(env: napi_env, str: [*]const u8, length: usize, result: *napi_value) napi_status;
extern fn napi_create_external(env: napi_env, data: ?*anyopaque, finalize_cb: ?napi_finalize, finalize_hint: ?*anyopaque, result: *napi_value) napi_status;
extern fn napi_get_value_external(env: napi_env, value: napi_value, result: *?*anyopaque) napi_status;
extern fn napi_get_null(env: napi_env, result: *napi_value) napi_status;
extern fn napi_get_undefined(env: napi_env, result: *napi_value) napi_status;
extern fn napi_get_value_int32(env: napi_env, value: napi_value, result: *i32) napi_status;
extern fn napi_create_int32(env: napi_env, value: i32, result: *napi_value) napi_status;
extern fn napi_throw_error(env: napi_env, code: ?[*:0]const u8, msg: [*:0]const u8) napi_status;
extern fn napi_is_null(env: napi_env, value: napi_value, result: *bool) napi_status;
extern fn napi_is_undefined(env: napi_env, value: napi_value, result: *bool) napi_status;

const napi_async_work = *anyopaque;
const napi_deferred = *anyopaque;

extern fn napi_create_promise(env: napi_env, deferred: *napi_deferred, promise: *napi_value) napi_status;
extern fn napi_resolve_deferred(env: napi_env, deferred: napi_deferred, resolution: napi_value) napi_status;
extern fn napi_reject_deferred(env: napi_env, deferred: napi_deferred, rejection: napi_value) napi_status;
extern fn napi_create_async_work(env: napi_env, async_resource: ?napi_value, async_resource_name: napi_value, execute: *const fn (?napi_env, ?*anyopaque) callconv(.c) void, complete: *const fn (napi_env, napi_status, ?*anyopaque) callconv(.c) void, data: ?*anyopaque, result: *napi_async_work) napi_status;
extern fn napi_queue_async_work(env: napi_env, work: napi_async_work) napi_status;
extern fn napi_delete_async_work(env: napi_env, work: napi_async_work) napi_status;
extern fn napi_get_named_property(env: napi_env, object: napi_value, utf8name: [*:0]const u8, result: *napi_value) napi_status;

// ─── C ABI imports from agent ─────────────────────────────────────────────────

const Handle = ?*anyopaque;

extern fn agent_version() [*:0]const u8;
extern fn agent_create_anthropic_provider(api_key_ptr: [*]const u8, api_key_len: usize, model_ptr: [*]const u8, model_len: usize, base_url_ptr: ?[*]const u8, base_url_len: usize) Handle;
extern fn agent_create_openai_compat_provider(api_key_ptr: [*]const u8, api_key_len: usize, base_url_ptr: [*]const u8, base_url_len: usize, model_ptr: [*]const u8, model_len: usize) Handle;
extern fn agent_destroy_provider(handle: Handle) void;
extern fn agent_create_engine(provider: Handle, tools: Handle, system_prompt_ptr: ?[*]const u8, system_prompt_len: usize, max_turns: u32) Handle;
extern fn agent_destroy_engine(handle: Handle) void;
extern fn agent_submit_message(engine: Handle, prompt_ptr: [*]const u8, prompt_len: usize) Handle;
extern fn agent_destroy_iterator(handle: Handle) void;
extern fn agent_event_to_json(iter: Handle, out_len: *usize) ?[*]u8;
extern fn agent_free_string(ptr: [*]u8, len: usize) void;
extern fn agent_resolve_tool_result(engine: Handle, id_ptr: [*]const u8, id_len: usize, res_ptr: [*]const u8, res_len: usize) void;
extern fn agent_push_tool_progress(engine: Handle, id_ptr: [*]const u8, id_len: usize, prog_ptr: [*]const u8, prog_len: usize) void;
extern fn agent_create_tool_registry() Handle;
extern fn agent_register_tool_schema(registry: Handle, name_ptr: [*]const u8, name_len: usize, schema_ptr: [*]const u8, schema_len: usize) void;
extern fn agent_destroy_tool_registry(handle: Handle) void;
extern fn agent_seed_messages(engine: Handle, json_ptr: [*]const u8, json_len: usize) void;
extern fn agent_abort_engine(engine: Handle) void;
extern fn agent_create_sub_agent(provider: Handle, tools: Handle, sp_ptr: ?[*]const u8, sp_len: usize, max_turns: u32) Handle;
extern fn agent_sub_agent_run(handle: Handle, prompt_ptr: [*]const u8, prompt_len: usize) Handle;
extern fn agent_abort_sub_agent(handle: Handle) void;
extern fn agent_destroy_sub_agent(handle: Handle) void;
extern fn agent_create_team(lead_provider: Handle, lead_tools: Handle, sp_ptr: ?[*]const u8, sp_len: usize, max_turns: u32) Handle;
extern fn agent_team_add_member(team_handle: Handle, member_id_ptr: [*]const u8, member_id_len: usize, provider_handle: Handle, tools_handle: Handle, system_prompt_ptr: ?[*]const u8, system_prompt_len: usize, max_turns: u32) bool;
extern fn agent_team_run(handle: Handle, prompt_ptr: [*]const u8, prompt_len: usize) Handle;
extern fn agent_resolve_team_tool_result(handle: Handle, id_ptr: [*]const u8, id_len: usize, res_ptr: [*]const u8, res_len: usize) void;
extern fn agent_abort_team(handle: Handle) void;
extern fn agent_destroy_team(handle: Handle) void;

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// Read a JS string argument at argv[idx] into a stack buffer.
/// Returns a slice of the buffer — valid only as long as buf is in scope.
fn jsStr(env: napi_env, argv: [*]napi_value, idx: usize, buf: []u8) []u8 {
    var len: usize = 0;
    _ = napi_get_value_string_utf8(env, argv[idx], buf.ptr, buf.len, &len);
    return buf[0..len];
}

fn jsInt32(env: napi_env, argv: [*]napi_value, idx: usize) i32 {
    var val: i32 = 0;
    _ = napi_get_value_int32(env, argv[idx], &val);
    return val;
}

fn nullVal(env: napi_env) napi_value {
    var v: napi_value = undefined;
    _ = napi_get_null(env, &v);
    return v;
}

fn undefinedVal(env: napi_env) napi_value {
    var v: napi_value = undefined;
    _ = napi_get_undefined(env, &v);
    return v;
}

fn wrapHandle(env: napi_env, handle: Handle) napi_value {
    if (handle == null) return nullVal(env);
    var v: napi_value = undefined;
    _ = napi_create_external(env, handle, null, null, &v);
    return v;
}

fn unwrapHandle(env: napi_env, val: napi_value) Handle {
    var ptr: ?*anyopaque = null;
    _ = napi_get_value_external(env, val, &ptr);
    return ptr;
}

fn jsString(env: napi_env, s: []const u8) napi_value {
    var v: napi_value = undefined;
    _ = napi_create_string_utf8(env, s.ptr, s.len, &v);
    return v;
}

fn isNullOrUndefined(env: napi_env, val: napi_value) bool {
    var is_null: bool = false;
    var is_undef: bool = false;
    _ = napi_is_null(env, val, &is_null);
    _ = napi_is_undefined(env, val, &is_undef);
    return is_null or is_undef;
}

fn jsStrFromVal(env: napi_env, val: napi_value, buf: []u8) []u8 {
    var len: usize = 0;
    _ = napi_get_value_string_utf8(env, val, buf.ptr, buf.len, &len);
    return buf[0..len];
}

// ─── JS function implementations ──────────────────────────────────────────────

fn js_agentVersion(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    _ = info;
    const ver = agent_version();
    const s = std.mem.span(ver);
    return jsString(env, s);
}

fn js_createAnthropicProvider(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 3;
    var argv: [3]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 2) return nullVal(env);

    var api_key_buf: [512]u8 = undefined;
    var model_buf: [256]u8 = undefined;
    const api_key = jsStr(env, &argv, 0, &api_key_buf);
    const model = jsStr(env, &argv, 1, &model_buf);

    // Read optional baseUrl — skip isNullOrUndefined (Bun napi_is_null crashes).
    // napi_get_value_string_utf8 on null/undefined returns len=0, which is safe.
    var base_url_buf: [1024]u8 = undefined;
    var base_url_ptr: ?[*]const u8 = null;
    var base_url_len: usize = 0;
    if (argc >= 3) {
        const base_url = jsStr(env, &argv, 2, &base_url_buf);
        if (base_url.len > 0) {
            base_url_ptr = base_url.ptr;
            base_url_len = base_url.len;
        }
    }

    const handle = agent_create_anthropic_provider(api_key.ptr, api_key.len, model.ptr, model.len, base_url_ptr, base_url_len);
    return wrapHandle(env, handle);
}

fn js_createOpenAICompatProvider(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 3;
    var argv: [3]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 3) return nullVal(env);

    var api_key_buf: [512]u8 = undefined;
    var base_url_buf: [1024]u8 = undefined;
    var model_buf: [256]u8 = undefined;
    const api_key = jsStr(env, &argv, 0, &api_key_buf);
    const base_url = jsStr(env, &argv, 1, &base_url_buf);
    const model = jsStr(env, &argv, 2, &model_buf);

    const handle = agent_create_openai_compat_provider(api_key.ptr, api_key.len, base_url.ptr, base_url.len, model.ptr, model.len);
    return wrapHandle(env, handle);
}

fn js_destroyProvider(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc >= 1) agent_destroy_provider(unwrapHandle(env, argv[0]));
    return undefinedVal(env);
}

fn js_createToolRegistry(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    _ = info;
    return wrapHandle(env, agent_create_tool_registry());
}

fn js_registerToolSchema(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 3;
    var argv: [3]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 3) return undefinedVal(env);

    const registry = unwrapHandle(env, argv[0]);
    var name_buf: [256]u8 = undefined;
    var schema_buf: [65536]u8 = undefined;
    const name = jsStr(env, &argv, 1, &name_buf);
    const schema = jsStr(env, &argv, 2, &schema_buf);

    agent_register_tool_schema(registry, name.ptr, name.len, schema.ptr, schema.len);
    return undefinedVal(env);
}

fn js_destroyToolRegistry(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc >= 1) agent_destroy_tool_registry(unwrapHandle(env, argv[0]));
    return undefinedVal(env);
}

/// createQueryEngine(provider, tools, systemPrompt, maxTurns, cwd)
fn js_createQueryEngine(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    // Flat positional args: provider, tools, systemPrompt, maxTurns, cwd
    // No isNullOrUndefined calls — Bun 1.x crashes when napi_is_null is called on externals.
    // JS wrapper guarantees: argv[0]=external, argv[1]=external|null, argv[2]=string, argv[3]=number.
    var argc: usize = 5;
    var argv: [5]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 4) return nullVal(env);

    const provider = unwrapHandle(env, argv[0]);
    const tools = unwrapHandle(env, argv[1]);

    var sp_buf: [8192]u8 = undefined;
    const system_prompt = jsStrFromVal(env, argv[2], &sp_buf);
    const max_turns: u32 = @intCast(@max(0, jsInt32(env, &argv, 3)));

    const sp_ptr: ?[*]const u8 = if (system_prompt.len > 0) system_prompt.ptr else null;
    const handle = agent_create_engine(provider, tools, sp_ptr, system_prompt.len, max_turns);
    return wrapHandle(env, handle);
}

/// submitMessage(engine, prompt) → iterHandle (synchronous for Bun compat)
fn js_submitMessage(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 2;
    var argv: [2]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 2) return nullVal(env);
    const engine = unwrapHandle(env, argv[0]);
    var prompt_buf: [65536]u8 = undefined;
    const prompt = jsStr(env, &argv, 1, &prompt_buf);
    const iter = agent_submit_message(engine, prompt.ptr, prompt.len);
    return wrapHandle(env, iter);
}

/// nextEvent(iterator) → Promise<string | null>
const NextEventData = struct {
    iter_handle: Handle,
    deferred: napi_deferred,
    work: napi_async_work = undefined,
    result_ptr: ?[*]u8 = null,
    result_len: usize = 0,
};

fn nextEventExecute(_: ?napi_env, data: ?*anyopaque) callconv(.c) void {
    const d: *NextEventData = @ptrCast(@alignCast(data.?));
    d.result_ptr = agent_event_to_json(d.iter_handle, &d.result_len);
}

fn nextEventComplete(env: napi_env, _: napi_status, data: ?*anyopaque) callconv(.c) void {
    const d: *NextEventData = @ptrCast(@alignCast(data.?));
    defer {
        _ = napi_delete_async_work(env, d.work);
        std.heap.c_allocator.destroy(d);
    }
    if (d.result_ptr == null or d.result_len == 0) {
        _ = napi_resolve_deferred(env, d.deferred, nullVal(env));
        return;
    }
    const json_bytes = d.result_ptr.?[0..d.result_len];
    const result = jsString(env, json_bytes);
    agent_free_string(d.result_ptr.?, d.result_len);
    _ = napi_resolve_deferred(env, d.deferred, result);
}

fn js_nextEvent(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 1) return nullVal(env);
    const iter = unwrapHandle(env, argv[0]);

    var deferred: napi_deferred = undefined;
    var promise: napi_value = undefined;
    _ = napi_create_promise(env, &deferred, &promise);

    const data = std.heap.c_allocator.create(NextEventData) catch return nullVal(env);
    data.* = .{ .iter_handle = iter, .deferred = deferred };

    const resource_name = jsString(env, "agent_nextEvent");
    _ = napi_create_async_work(env, null, resource_name, nextEventExecute, nextEventComplete, data, &data.work);
    _ = napi_queue_async_work(env, data.work);
    return promise;
}

fn js_seedMessages(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 2;
    var argv: [2]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 2) return undefinedVal(env);
    const engine = unwrapHandle(env, argv[0]);
    var json_buf: [131072]u8 = undefined; // 128KB for message history
    const json = jsStr(env, &argv, 1, &json_buf);
    agent_seed_messages(engine, json.ptr, json.len);
    return undefinedVal(env);
}

fn js_abortEngine(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc >= 1) agent_abort_engine(unwrapHandle(env, argv[0]));
    return undefinedVal(env);
}

fn js_resolveToolResult(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 3;
    var argv: [3]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 3) return undefinedVal(env);

    const engine = unwrapHandle(env, argv[0]);
    var id_buf: [256]u8 = undefined;
    var res_buf: [65536]u8 = undefined;
    const id = jsStr(env, &argv, 1, &id_buf);
    const result = jsStr(env, &argv, 2, &res_buf);

    agent_resolve_tool_result(engine, id.ptr, id.len, result.ptr, result.len);
    return undefinedVal(env);
}

fn js_pushToolProgress(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 3;
    var argv: [3]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 3) return undefinedVal(env);

    const engine = unwrapHandle(env, argv[0]);
    var id_buf: [256]u8 = undefined;
    var prog_buf: [65536]u8 = undefined;
    const id = jsStr(env, &argv, 1, &id_buf);
    const progress = jsStr(env, &argv, 2, &prog_buf);

    agent_push_tool_progress(engine, id.ptr, id.len, progress.ptr, progress.len);
    return undefinedVal(env);
}

fn js_destroyQueryEngine(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc >= 1) agent_destroy_engine(unwrapHandle(env, argv[0]));
    return undefinedVal(env);
}

fn js_destroyIterator(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc >= 1) agent_destroy_iterator(unwrapHandle(env, argv[0]));
    return undefinedVal(env);
}

// ─── SubAgent wrappers ───────────────────────────────────────────────────────

fn js_createSubAgent(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 4;
    var argv: [4]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 2) return nullVal(env);

    const provider = unwrapHandle(env, argv[0]);
    const tools: Handle = if (argc >= 2) unwrapHandle(env, argv[1]) else null;

    var sp_buf: [8192]u8 = undefined;
    const sp = if (argc >= 3) jsStr(env, &argv, 2, &sp_buf) else @as([]u8, &.{});
    const max_turns: u32 = if (argc >= 4) @intCast(@max(0, jsInt32(env, &argv, 3))) else 50;

    const sp_ptr: ?[*]const u8 = if (sp.len > 0) sp.ptr else null;
    return wrapHandle(env, agent_create_sub_agent(provider, tools, sp_ptr, sp.len, max_turns));
}

fn js_destroySubAgent(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc >= 1) agent_destroy_sub_agent(unwrapHandle(env, argv[0]));
    return undefinedVal(env);
}

fn js_abortSubAgent(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc >= 1) agent_abort_sub_agent(unwrapHandle(env, argv[0]));
    return undefinedVal(env);
}

const SubAgentRunData = struct {
    handle: Handle,
    prompt: []const u8,
    deferred: napi_deferred,
    env: napi_env,
    work: napi_async_work = undefined,
    result_handle: Handle = null,
};

fn subAgentRunExecute(_: ?napi_env, data: ?*anyopaque) callconv(.c) void {
    const d: *SubAgentRunData = @ptrCast(@alignCast(data.?));
    d.result_handle = agent_sub_agent_run(d.handle, d.prompt.ptr, d.prompt.len);
}

fn subAgentRunComplete(env: napi_env, _: napi_status, data: ?*anyopaque) callconv(.c) void {
    const d: *SubAgentRunData = @ptrCast(@alignCast(data.?));
    defer {
        _ = napi_delete_async_work(env, d.work);
        std.heap.c_allocator.free(d.prompt);
        std.heap.c_allocator.destroy(d);
    }
    _ = napi_resolve_deferred(env, d.deferred, wrapHandle(env, d.result_handle));
}

fn js_subAgentRun(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 2;
    var argv: [2]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 2) return nullVal(env);

    const handle = unwrapHandle(env, argv[0]);
    var prompt_buf: [65536]u8 = undefined;
    const prompt_slice = jsStr(env, &argv, 1, &prompt_buf);
    const prompt_dupe = std.heap.c_allocator.dupe(u8, prompt_slice) catch return nullVal(env);

    var deferred: napi_deferred = undefined;
    var promise: napi_value = undefined;
    _ = napi_create_promise(env, &deferred, &promise);

    const data = std.heap.c_allocator.create(SubAgentRunData) catch {
        std.heap.c_allocator.free(prompt_dupe);
        return nullVal(env);
    };
    data.* = .{ .handle = handle, .prompt = prompt_dupe, .deferred = deferred, .env = env };

    const resource_name = jsString(env, "agent_subAgentRun");
    _ = napi_create_async_work(env, null, resource_name, subAgentRunExecute, subAgentRunComplete, data, &data.work);
    _ = napi_queue_async_work(env, data.work);
    return promise;
}

// ─── Team wrappers ───────────────────────────────────────────────────────────

fn js_createTeam(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 4;
    var argv: [4]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 2) return nullVal(env);

    const lead_provider = unwrapHandle(env, argv[0]);
    const lead_tools: Handle = if (argc >= 2) unwrapHandle(env, argv[1]) else null;

    var sp_buf: [8192]u8 = undefined;
    const sp = if (argc >= 3) jsStr(env, &argv, 2, &sp_buf) else @as([]u8, &.{});
    const max_turns: u32 = if (argc >= 4) @intCast(@max(0, jsInt32(env, &argv, 3))) else 20;

    const sp_ptr: ?[*]const u8 = if (sp.len > 0) sp.ptr else null;
    return wrapHandle(env, agent_create_team(lead_provider, lead_tools, sp_ptr, sp.len, max_turns));
}

fn js_addTeamMember(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 6;
    var argv: [6]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 4) return nullVal(env);

    const team = unwrapHandle(env, argv[0]);
    var id_buf: [256]u8 = undefined;
    const member_id = jsStr(env, &argv, 1, &id_buf);
    const member_provider = unwrapHandle(env, argv[2]);
    const member_tools = unwrapHandle(env, argv[3]);
    var sp_buf: [8192]u8 = undefined;
    const sp = if (argc >= 5) jsStr(env, &argv, 4, &sp_buf) else @as([]u8, &.{});
    const max_turns: u32 = if (argc >= 6) @intCast(@max(0, jsInt32(env, &argv, 5))) else 20;

    const sp_ptr: ?[*]const u8 = if (sp.len > 0) sp.ptr else null;
    const ok = agent_team_add_member(team, member_id.ptr, member_id.len, member_provider, member_tools, sp_ptr, sp.len, max_turns);
    return if (ok) undefinedVal(env) else nullVal(env);
}

const TeamRunData = struct {
    handle: Handle,
    prompt: []const u8,
    deferred: napi_deferred,
    env: napi_env,
    work: napi_async_work = undefined,
    result_handle: Handle = null,
};

fn teamRunExecute(_: ?napi_env, data: ?*anyopaque) callconv(.c) void {
    const d: *TeamRunData = @ptrCast(@alignCast(data.?));
    d.result_handle = agent_team_run(d.handle, d.prompt.ptr, d.prompt.len);
}

fn teamRunComplete(env: napi_env, _: napi_status, data: ?*anyopaque) callconv(.c) void {
    const d: *TeamRunData = @ptrCast(@alignCast(data.?));
    defer {
        _ = napi_delete_async_work(env, d.work);
        std.heap.c_allocator.free(d.prompt);
        std.heap.c_allocator.destroy(d);
    }
    _ = napi_resolve_deferred(env, d.deferred, wrapHandle(env, d.result_handle));
}

fn js_runTeam(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 2;
    var argv: [2]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 2) return nullVal(env);

    const handle = unwrapHandle(env, argv[0]);
    var prompt_buf: [65536]u8 = undefined;
    const prompt_slice = jsStr(env, &argv, 1, &prompt_buf);
    const prompt_dupe = std.heap.c_allocator.dupe(u8, prompt_slice) catch return nullVal(env);

    var deferred: napi_deferred = undefined;
    var promise: napi_value = undefined;
    _ = napi_create_promise(env, &deferred, &promise);

    const data = std.heap.c_allocator.create(TeamRunData) catch {
        std.heap.c_allocator.free(prompt_dupe);
        return nullVal(env);
    };
    data.* = .{ .handle = handle, .prompt = prompt_dupe, .deferred = deferred, .env = env };

    const resource_name = jsString(env, "agent_runTeam");
    _ = napi_create_async_work(env, null, resource_name, teamRunExecute, teamRunComplete, data, &data.work);
    _ = napi_queue_async_work(env, data.work);
    return promise;
}

fn js_resolveTeamToolResult(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 3;
    var argv: [3]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 3) return undefinedVal(env);

    const team = unwrapHandle(env, argv[0]);
    var id_buf: [256]u8 = undefined;
    var res_buf: [65536]u8 = undefined;
    const id = jsStr(env, &argv, 1, &id_buf);
    const result = jsStr(env, &argv, 2, &res_buf);

    agent_resolve_team_tool_result(team, id.ptr, id.len, result.ptr, result.len);
    return undefinedVal(env);
}

fn js_abortTeam(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc >= 1) agent_abort_team(unwrapHandle(env, argv[0]));
    return undefinedVal(env);
}

fn js_destroyTeam(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc >= 1) agent_destroy_team(unwrapHandle(env, argv[0]));
    return undefinedVal(env);
}

// ─── Module registration ──────────────────────────────────────────────────────

fn registerFn(env: napi_env, exports: napi_value, name: [*:0]const u8, cb: napi_callback) void {
    var fn_val: napi_value = undefined;
    _ = napi_create_function(env, name, std.mem.len(name), cb, null, &fn_val);
    _ = napi_set_named_property(env, exports, name, fn_val);
}

export fn napi_register_module_v1(env: napi_env, exports: napi_value) napi_value {
    registerFn(env, exports, "agentVersion", js_agentVersion);
    registerFn(env, exports, "createAnthropicProvider", js_createAnthropicProvider);
    registerFn(env, exports, "createOpenAICompatProvider", js_createOpenAICompatProvider);
    registerFn(env, exports, "destroyProvider", js_destroyProvider);
    registerFn(env, exports, "createToolRegistry", js_createToolRegistry);
    registerFn(env, exports, "registerToolSchema", js_registerToolSchema);
    registerFn(env, exports, "destroyToolRegistry", js_destroyToolRegistry);
    registerFn(env, exports, "createQueryEngine", js_createQueryEngine);
    registerFn(env, exports, "submitMessage", js_submitMessage);
    registerFn(env, exports, "nextEvent", js_nextEvent);
    registerFn(env, exports, "seedMessages", js_seedMessages);
    registerFn(env, exports, "abortEngine", js_abortEngine);
    registerFn(env, exports, "resolveToolResult", js_resolveToolResult);
    registerFn(env, exports, "pushToolProgress", js_pushToolProgress);
    registerFn(env, exports, "destroyQueryEngine", js_destroyQueryEngine);
    registerFn(env, exports, "destroyIterator", js_destroyIterator);
    registerFn(env, exports, "createSubAgent", js_createSubAgent);
    registerFn(env, exports, "subAgentRun", js_subAgentRun);
    registerFn(env, exports, "abortSubAgent", js_abortSubAgent);
    registerFn(env, exports, "destroySubAgent", js_destroySubAgent);
    registerFn(env, exports, "createTeam", js_createTeam);
    registerFn(env, exports, "addTeamMember", js_addTeamMember);
    registerFn(env, exports, "runTeam", js_runTeam);
    registerFn(env, exports, "resolveTeamToolResult", js_resolveTeamToolResult);
    registerFn(env, exports, "abortTeam", js_abortTeam);
    registerFn(env, exports, "destroyTeam", js_destroyTeam);
    return exports;
}
