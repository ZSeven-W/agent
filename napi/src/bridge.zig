// napi/src/bridge.zig
//! Node-API (NAPI) bridge — wraps agent C ABI as a Node.js native addon.
//!
//! Uses the Node-API stable ABI (NAPI_VERSION >= 6).
//! All exported JS functions use flat string/number arguments for simplicity:
//! no napi_get_named_property needed.
//!
//! JS signatures (see ../ts/index.d.ts):
//!   agentVersion() → string
//!   createAnthropicProvider(apiKey, model) → handle
//!   createOpenAICompatProvider(apiKey, baseUrl, model) → handle
//!   destroyProvider(handle) → void
//!   createToolRegistry() → handle
//!   registerToolSchema(registry, name, schemaJson) → void
//!   destroyToolRegistry(handle) → void
//!   createQueryEngine(provider, tools, systemPrompt, maxTurns, cwd) → handle
//!   submitMessage(engine, prompt) → iterHandle
//!   nextEvent(iter) → string | null
//!   resolveToolResult(engine, toolUseId, resultJson) → void
//!   pushToolProgress(engine, toolUseId, progressJson) → void
//!   destroyQueryEngine(handle) → void
//!   destroyIterator(handle) → void

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

// ─── C ABI imports from agent ─────────────────────────────────────────────────

const Handle = ?*anyopaque;

extern fn agent_version() [*:0]const u8;
extern fn agent_create_anthropic_provider(api_key_ptr: [*]const u8, api_key_len: usize, model_ptr: [*]const u8, model_len: usize) Handle;
extern fn agent_create_openai_compat_provider(api_key_ptr: [*]const u8, api_key_len: usize, base_url_ptr: [*]const u8, base_url_len: usize, model_ptr: [*]const u8, model_len: usize) Handle;
extern fn agent_destroy_provider(handle: Handle) void;
extern fn agent_create_engine(provider: Handle, system_prompt_ptr: ?[*]const u8, system_prompt_len: usize, max_turns: u32) Handle;
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

// ─── JS function implementations ──────────────────────────────────────────────

fn js_agentVersion(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    _ = info;
    const ver = agent_version();
    const s = std.mem.span(ver);
    return jsString(env, s);
}

fn js_createAnthropicProvider(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 2;
    var argv: [2]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 2) return nullVal(env);

    var api_key_buf: [512]u8 = undefined;
    var model_buf: [256]u8 = undefined;
    const api_key = jsStr(env, &argv, 0, &api_key_buf);
    const model = jsStr(env, &argv, 1, &model_buf);

    const handle = agent_create_anthropic_provider(api_key.ptr, api_key.len, model.ptr, model.len);
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
    var argc: usize = 5;
    var argv: [5]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 5) return nullVal(env);

    const provider = unwrapHandle(env, argv[0]);
    // argv[1] is tools registry handle — passed for future use; engine currently
    // creates its own registry internally. Stored for API completeness.
    _ = unwrapHandle(env, argv[1]);

    var sp_buf: [8192]u8 = undefined;
    const system_prompt = jsStr(env, &argv, 2, &sp_buf);
    const max_turns: u32 = @intCast(@max(0, jsInt32(env, &argv, 3)));
    // cwd is unused in this version but accepted for API compatibility
    var cwd_buf: [4096]u8 = undefined;
    _ = jsStr(env, &argv, 4, &cwd_buf);

    const sp_ptr: ?[*]const u8 = if (system_prompt.len > 0) system_prompt.ptr else null;
    const handle = agent_create_engine(provider, sp_ptr, system_prompt.len, max_turns);
    return wrapHandle(env, handle);
}

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

/// nextEvent(iterator) → string | null
fn js_nextEvent(env: napi_env, info: napi_callback_info) callconv(.c) napi_value {
    var argc: usize = 1;
    var argv: [1]napi_value = undefined;
    _ = napi_get_cb_info(env, info, &argc, &argv, null, null);
    if (argc < 1) return nullVal(env);

    const iter = unwrapHandle(env, argv[0]);
    var out_len: usize = 0;
    const ptr = agent_event_to_json(iter, &out_len);
    if (ptr == null or out_len == 0) return nullVal(env);

    const json_bytes = ptr.?[0..out_len];
    const result = jsString(env, json_bytes);
    agent_free_string(ptr.?, out_len);
    return result;
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
    registerFn(env, exports, "resolveToolResult", js_resolveToolResult);
    registerFn(env, exports, "pushToolProgress", js_pushToolProgress);
    registerFn(env, exports, "destroyQueryEngine", js_destroyQueryEngine);
    registerFn(env, exports, "destroyIterator", js_destroyIterator);
    return exports;
}
