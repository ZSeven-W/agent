// src/providers/openai_compat.zig
const std = @import("std");
const types = @import("types.zig");
const http_client = @import("../http/client.zig");
const sse_parser_mod = @import("../http/sse_parser.zig");
const json_mod = @import("../json.zig");

pub const Quirks = struct {
    patch_tool_call_args: bool = false,
    supports_stream_options: bool = true,
    azure_deployment: bool = false,
    api_version: ?[]const u8 = null,
    supports_reasoning: bool = false,
    explicit_content_type: bool = false,
};

pub const OpenAICompatConfig = struct {
    base: types.ProviderConfig,
    quirks: Quirks = .{},
};

pub const OpenAICompatProvider = struct {
    config: OpenAICompatConfig,
    allocator: std.mem.Allocator,
    /// Inline buffer for the most recent HTTP error body. Reused across
    /// errors to avoid heap churn; previous content is overwritten.
    last_error_buf: [2048]u8 = undefined,
    last_error_len: usize = 0,
    last_error_status: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, config: OpenAICompatConfig) OpenAICompatProvider {
        return .{ .config = config, .allocator = allocator };
    }

    fn lastError(ptr: *anyopaque) ?[]const u8 {
        const self: *OpenAICompatProvider = @ptrCast(@alignCast(ptr));
        if (self.last_error_len == 0) return null;
        return self.last_error_buf[0..self.last_error_len];
    }

    pub fn provider(self: *OpenAICompatProvider) types.Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .id = self.config.base.id,
                .max_context_tokens = self.config.base.max_context_tokens orelse 128_000,
                .supports_thinking = self.config.quirks.supports_reasoning,
                .supports_tool_use = true,
                .stream_text = streamText,
                .last_error = lastError,
            },
        };
    }

    /// Return function pointer at runtime (workaround for Zig 0.15 stack vtable issue).
    pub fn streamTextFn() *const fn (
        *anyopaque,
        []const types.ApiMessage,
        ?[]const types.ToolSchema,
        types.StreamConfig,
    ) types.StreamError!types.StreamIterator {
        return streamText;
    }

    fn streamText(
        ptr: *anyopaque,
        messages: []const types.ApiMessage,
        tools: ?[]const types.ToolSchema,
        config: types.StreamConfig,
    ) types.StreamError!types.StreamIterator {
        const self: *OpenAICompatProvider = @ptrCast(@alignCast(ptr));

        const body = buildRequestBody(self.allocator, self.config, messages, tools, config) catch
            return error.InvalidRequest;

        const base_url = self.config.base.base_url orelse "https://api.openai.com";
        const url = if (self.config.quirks.azure_deployment) blk: {
            const api_ver = self.config.quirks.api_version orelse "2024-02-01";
            break :blk std.fmt.allocPrint(
                self.allocator,
                "{s}/openai/deployments/{s}/chat/completions?api-version={s}",
                .{ base_url, self.config.base.model, api_ver },
            ) catch return error.InvalidRequest;
        } else if (types.urlEndsWithVersion(base_url))
            std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{base_url}) catch
                return error.InvalidRequest
        else
            std.fmt.allocPrint(self.allocator, "{s}/v1/chat/completions", .{base_url}) catch
                return error.InvalidRequest;

        const auth_header = std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{self.config.base.api_key orelse ""},
        ) catch return error.InvalidRequest;

        var http = http_client.HttpClient.init(self.allocator);
        var response = http.streamRequest(.{
            .url = url,
            .body = body,
            .headers = &.{
                .{ .name = "Authorization", .value = auth_header },
                .{ .name = "content-type", .value = "application/json" },
            },
        }) catch return error.ConnectionFailed;

        if (response.status != .ok) {
            // See anthropic.zig for the rationale: skipping body read avoids
            // a hard panic in std.http.Reader when the upstream uses chunked
            // transfer-encoding for error responses.
            const status_code: u16 = @intFromEnum(response.status);
            self.last_error_status = status_code;
            const message: []const u8 = switch (status_code) {
                401 => "Authentication failed (HTTP 401): check API key",
                402 => "Insufficient credits (HTTP 402): top up your provider account",
                429 => "Rate limited (HTTP 429): provider throttled the request",
                // StepFun / Zhipu and some Chinese providers use 451 for their
                // content-safety filter. This is not a transient error — the
                // request body or expected completion contains content the
                // provider refuses to process. Retrying the same prompt will
                // hit the same filter, so surface a specific message here.
                451 => "Content blocked by provider safety filter (HTTP 451): rephrase the prompt or switch model",
                400 => "Invalid request (HTTP 400): the provider rejected the request shape",
                else => "Upstream error from openai_compat provider",
            };
            const formatted = std.fmt.bufPrint(
                &self.last_error_buf,
                "{s} [HTTP {d}]",
                .{ message, status_code },
            ) catch self.last_error_buf[0..0];
            self.last_error_len = formatted.len;
            std.debug.print("[http] API error {d}: {s}\n", .{ status_code, message });
            response.close();
            return switch (status_code) {
                401 => error.AuthenticationFailed,
                402 => error.InsufficientCredits,
                429 => error.RateLimited,
                400, 451 => error.InvalidRequest,
                else => error.ServerError,
            };
        }
        self.last_error_len = 0;
        self.last_error_status = 0;

        const state = self.allocator.create(OpenAIStreamState) catch return error.ConnectionFailed;
        state.* = .{
            .http = http,
            .response = response,
            .parser = sse_parser_mod.SseParser.init(self.allocator),
            .allocator = self.allocator,
            .read_buf = undefined,
        };

        return .{
            .context = @ptrCast(state),
            .nextFn = OpenAIStreamState.nextDelta,
        };
    }

    pub fn buildRequestBody(
        allocator: std.mem.Allocator,
        config: OpenAICompatConfig,
        messages: []const types.ApiMessage,
        tools: ?[]const types.ToolSchema,
        stream_config: types.StreamConfig,
    ) ![]const u8 {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("model", .{ .string = config.base.model });
        try obj.put("stream", .{ .bool = true });
        try obj.put("max_tokens", .{ .integer = @intCast(stream_config.max_tokens) });

        if (config.quirks.supports_stream_options) {
            var opts = std.json.ObjectMap.init(allocator);
            try opts.put("include_usage", .{ .bool = true });
            try obj.put("stream_options", .{ .object = opts });
        }

        var msgs_arr = std.json.Array.init(allocator);

        // Inject system prompt as the first message if the caller supplied one.
        if (stream_config.system_prompt) |sys| {
            if (sys.len > 0) {
                var sys_obj = std.json.ObjectMap.init(allocator);
                try sys_obj.put("role", .{ .string = "system" });
                try sys_obj.put("content", .{ .string = sys });
                try msgs_arr.append(.{ .object = sys_obj });
            }
        }

        // The shared MessageStore always produces Anthropic-style content
        // blocks (`[{"type":"text",...},{"type":"tool_use",...}]` for
        // assistants and `[{"type":"tool_result",...}]` on tool returns).
        // OpenAI-compatible endpoints reject those shapes outright — they
        // want `tool_calls` on the assistant message and a separate
        // `{role:"tool",tool_call_id,content}` for the result. Translate here.
        for (messages) |msg| {
            try appendMessageAsOpenAI(allocator, &msgs_arr, msg);
        }
        try obj.put("messages", .{ .array = msgs_arr });

        if (tools) |t| {
            var tools_arr = std.json.Array.init(allocator);
            for (t) |tool_schema| {
                var tool_obj = std.json.ObjectMap.init(allocator);
                var fn_obj = std.json.ObjectMap.init(allocator);
                try fn_obj.put("name", .{ .string = tool_schema.name });
                try fn_obj.put("description", .{ .string = tool_schema.description });
                try fn_obj.put("parameters", tool_schema.input_schema);
                try tool_obj.put("type", .{ .string = "function" });
                try tool_obj.put("function", .{ .object = fn_obj });
                try tools_arr.append(.{ .object = tool_obj });
            }
            try obj.put("tools", .{ .array = tools_arr });
        }

        return json_mod.stringify(allocator, .{ .object = obj });
    }
};

/// Append a single `ApiMessage` to `msgs_arr` after translating Anthropic-style
/// content blocks into the OpenAI chat format:
///   - user text blocks → `{role:"user", content:"..."}`
///   - user tool_result blocks → `{role:"tool", tool_call_id, content}`
///   - assistant text + tool_use blocks → `{role:"assistant", content, tool_calls:[...]}`
///   - assistant thinking blocks → dropped (OpenAI endpoints reject them)
fn appendMessageAsOpenAI(
    allocator: std.mem.Allocator,
    msgs_arr: *std.json.Array,
    msg: types.ApiMessage,
) !void {
    // Plain string content is already OpenAI-compatible.
    if (msg.content == .string) {
        var m = std.json.ObjectMap.init(allocator);
        try m.put("role", .{ .string = msg.role });
        try m.put("content", msg.content);
        try msgs_arr.append(.{ .object = m });
        return;
    }

    if (msg.content != .array) {
        // Unknown shape — pass through unchanged so we don't silently drop it.
        var m = std.json.ObjectMap.init(allocator);
        try m.put("role", .{ .string = msg.role });
        try m.put("content", msg.content);
        try msgs_arr.append(.{ .object = m });
        return;
    }

    const blocks = msg.content.array.items;
    const is_assistant = std.mem.eql(u8, msg.role, "assistant");

    if (is_assistant) {
        var text_buf: std.ArrayList(u8) = .{};
        defer text_buf.deinit(allocator);
        var tool_calls = std.json.Array.init(allocator);

        for (blocks) |block| {
            if (block != .object) continue;
            const btype = json_mod.getString(block, "type") orelse continue;

            if (std.mem.eql(u8, btype, "text")) {
                if (json_mod.getString(block, "text")) |t| {
                    try text_buf.appendSlice(allocator, t);
                }
            } else if (std.mem.eql(u8, btype, "tool_use")) {
                const id = json_mod.getString(block, "id") orelse "";
                const name = json_mod.getString(block, "name") orelse "";
                const input_val = block.object.get("input") orelse json_mod.JsonValue{ .object = std.json.ObjectMap.init(allocator) };
                // OpenAI's function.arguments is a JSON-encoded string.
                const args_str = json_mod.stringify(allocator, input_val) catch "{}";

                var fn_obj = std.json.ObjectMap.init(allocator);
                try fn_obj.put("name", .{ .string = name });
                try fn_obj.put("arguments", .{ .string = args_str });

                var tc_obj = std.json.ObjectMap.init(allocator);
                try tc_obj.put("id", .{ .string = id });
                try tc_obj.put("type", .{ .string = "function" });
                try tc_obj.put("function", .{ .object = fn_obj });

                try tool_calls.append(.{ .object = tc_obj });
            }
            // thinking / unknown block types intentionally dropped.
        }

        var m = std.json.ObjectMap.init(allocator);
        try m.put("role", .{ .string = "assistant" });

        const content_str = try allocator.dupe(u8, text_buf.items);
        try m.put("content", .{ .string = content_str });

        if (tool_calls.items.len > 0) {
            try m.put("tool_calls", .{ .array = tool_calls });
        }

        try msgs_arr.append(.{ .object = m });
        return;
    }

    // User role — tool_result blocks become standalone role="tool" messages;
    // text blocks get merged into a single trailing user message.
    var text_buf: std.ArrayList(u8) = .{};
    defer text_buf.deinit(allocator);

    for (blocks) |block| {
        if (block != .object) continue;
        const btype = json_mod.getString(block, "type") orelse continue;

        if (std.mem.eql(u8, btype, "text")) {
            if (json_mod.getString(block, "text")) |t| {
                if (text_buf.items.len > 0) try text_buf.appendSlice(allocator, "\n");
                try text_buf.appendSlice(allocator, t);
            }
        } else if (std.mem.eql(u8, btype, "tool_result")) {
            const tool_use_id = json_mod.getString(block, "tool_use_id") orelse "";
            const content_val = block.object.get("content") orelse json_mod.JsonValue{ .string = "" };
            const content_str: []const u8 = switch (content_val) {
                .string => |s| s,
                else => json_mod.stringify(allocator, content_val) catch "",
            };

            var m = std.json.ObjectMap.init(allocator);
            try m.put("role", .{ .string = "tool" });
            try m.put("tool_call_id", .{ .string = tool_use_id });
            try m.put("content", .{ .string = content_str });
            try msgs_arr.append(.{ .object = m });
        }
    }

    if (text_buf.items.len > 0) {
        const content_str = try allocator.dupe(u8, text_buf.items);
        var m = std.json.ObjectMap.init(allocator);
        try m.put("role", .{ .string = "user" });
        try m.put("content", .{ .string = content_str });
        try msgs_arr.append(.{ .object = m });
    }
}

const OpenAIStreamState = struct {
    http: http_client.HttpClient,
    response: http_client.StreamingResponse,
    parser: sse_parser_mod.SseParser,
    allocator: std.mem.Allocator,
    read_buf: [8192]u8,
    done: bool = false,
    cleaned: bool = false,

    // A single SSE chunk can yield multiple StreamDeltas (e.g. content_block_start
    // + tool_use_delta, or content_block_stop + message_stop). We buffer them
    // here so nextDelta can hand them out one at a time while keeping its
    // simple pull-based contract.
    pending: [4]types.StreamDelta = undefined,
    pending_len: u8 = 0,
    pending_pos: u8 = 0,

    // Track the OpenAI-style tool_calls[i].index of the currently-open tool
    // content block so we can emit content_block_stop when the stream advances
    // to a new tool call.
    current_tool_index: i32 = -1,
    has_open_tool_block: bool = false,

    fn pushPending(self: *OpenAIStreamState, delta: types.StreamDelta) void {
        if (self.pending_len >= self.pending.len) return;
        self.pending[self.pending_len] = delta;
        self.pending_len += 1;
    }

    fn drainPending(self: *OpenAIStreamState) ?types.StreamDelta {
        if (self.pending_pos >= self.pending_len) {
            self.pending_pos = 0;
            self.pending_len = 0;
            return null;
        }
        const d = self.pending[self.pending_pos];
        self.pending_pos += 1;
        return d;
    }

    fn cleanup(self: *OpenAIStreamState) void {
        if (self.cleaned) return;
        self.cleaned = true;
        self.parser.deinit();
        self.response.close();
        self.http.deinit();
    }

    fn freeSseEvent(self: *OpenAIStreamState, sse: sse_parser_mod.SseEvent) void {
        self.allocator.free(sse.data);
        if (sse.event) |e| self.allocator.free(e);
        if (sse.id) |i| self.allocator.free(i);
    }

    fn closeOpenToolBlock(self: *OpenAIStreamState) void {
        if (self.has_open_tool_block) {
            self.pushPending(.{ .@"type" = .content_block_stop });
            self.has_open_tool_block = false;
            self.current_tool_index = -1;
        }
    }

    fn nextDelta(ctx: *anyopaque) ?types.StreamDelta {
        const self: *OpenAIStreamState = @ptrCast(@alignCast(ctx));

        while (true) {
            if (self.drainPending()) |d| return d;

            if (self.done) {
                self.cleanup();
                return null;
            }

            if (self.parser.next()) |sse_event| {
                self.ingestSseEvent(sse_event);
                self.freeSseEvent(sse_event);
                continue;
            }

            const n = self.response.readChunk(&self.read_buf) catch {
                self.done = true;
                continue;
            };
            if (n == 0) {
                self.done = true;
                continue;
            }

            self.parser.feed(self.read_buf[0..n]) catch {
                self.done = true;
                continue;
            };
        }
    }

    fn ingestSseEvent(self: *OpenAIStreamState, sse: sse_parser_mod.SseEvent) void {
        if (std.mem.eql(u8, sse.data, "[DONE]")) {
            self.closeOpenToolBlock();
            self.done = true;
            return;
        }

        const parsed = json_mod.parse(self.allocator, sse.data) catch return;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        const choices_val = root.object.get("choices") orelse return;
        if (choices_val != .array or choices_val.array.items.len == 0) return;
        const choice = choices_val.array.items[0];
        if (choice != .object) return;

        if (choice.object.get("delta")) |delta_val| {
            if (delta_val == .object) {
                // Tool-call deltas first: some providers bundle finish_reason
                // with the final tool_calls chunk, and we want the call's
                // content_block_stop to come before message_stop.
                if (delta_val.object.get("tool_calls")) |tc_val| {
                    if (tc_val == .array) {
                        for (tc_val.array.items) |tc_item| {
                            if (tc_item != .object) continue;
                            self.ingestToolCall(tc_item);
                        }
                    }
                }

                if (json_mod.getString(delta_val, "content")) |text| {
                    if (text.len > 0) {
                        const owned = self.allocator.dupe(u8, text) catch null;
                        self.pushPending(.{ .@"type" = .text_delta, .text = owned });
                    }
                }

                // Reasoning stream field — providers disagree on the name:
                //   DeepSeek / GLM / Qwen: `reasoning_content`
                //   StepFun step_plan:    `reasoning`
                //   OpenAI o1 (future):   `reasoning`
                // Accept either so the whole `reasoning` stream from StepFun
                // actually surfaces instead of being silently dropped (which
                // starves the client-side first-text watchdog and leads to an
                // abort → std.http panic cascade).
                if (json_mod.getString(delta_val, "reasoning_content")) |text| {
                    if (text.len > 0) {
                        const owned = self.allocator.dupe(u8, text) catch null;
                        self.pushPending(.{ .@"type" = .thinking_delta, .text = owned });
                    }
                } else if (json_mod.getString(delta_val, "reasoning")) |text| {
                    if (text.len > 0) {
                        const owned = self.allocator.dupe(u8, text) catch null;
                        self.pushPending(.{ .@"type" = .thinking_delta, .text = owned });
                    }
                }
            }
        }

        if (choice.object.get("finish_reason")) |fr| {
            if (fr != .null) {
                self.closeOpenToolBlock();
                self.pushPending(.{ .@"type" = .message_stop });
                self.done = true;
            }
        }
    }

    fn ingestToolCall(self: *OpenAIStreamState, tc: json_mod.JsonValue) void {
        const idx: i32 = if (tc.object.get("index")) |v| switch (v) {
            .integer => |i| @intCast(i),
            else => 0,
        } else 0;

        // Advance to a new tool block when the index changes.
        if (self.has_open_tool_block and idx != self.current_tool_index) {
            self.closeOpenToolBlock();
        }

        const fn_val = tc.object.get("function");

        if (!self.has_open_tool_block) {
            var tool_name: ?[]const u8 = null;
            var tool_id: ?[]const u8 = null;
            if (tc.object.get("id")) |idv| {
                if (idv == .string) tool_id = self.allocator.dupe(u8, idv.string) catch null;
            }
            if (fn_val) |f| {
                if (f == .object) {
                    if (f.object.get("name")) |nv| {
                        if (nv == .string) tool_name = self.allocator.dupe(u8, nv.string) catch null;
                    }
                }
            }
            // query.zig keys tool registration off tool_name — only open a
            // block once we actually have a name to hand it.
            if (tool_name != null) {
                self.pushPending(.{
                    .@"type" = .content_block_start,
                    .tool_use_id = tool_id,
                    .tool_name = tool_name,
                });
                self.has_open_tool_block = true;
                self.current_tool_index = idx;
            } else if (tool_id) |tid| {
                self.allocator.free(tid);
            }
        }

        if (fn_val) |f| {
            if (f == .object) {
                if (f.object.get("arguments")) |av| {
                    if (av == .string and av.string.len > 0) {
                        const owned = self.allocator.dupe(u8, av.string) catch null;
                        self.pushPending(.{
                            .@"type" = .tool_use_delta,
                            .partial_json = owned,
                        });
                    }
                }
            }
        }
    }
};

/// Convenience presets for common providers.
pub const presets = struct {
    pub fn deepseek(api_key: []const u8, model: []const u8) OpenAICompatConfig {
        return .{
            .base = .{ .id = "deepseek", .base_url = "https://api.deepseek.com", .api_key = api_key, .model = model, .max_context_tokens = 65536 },
            .quirks = .{ .supports_reasoning = true },
        };
    }

    pub fn groq(api_key: []const u8, model: []const u8) OpenAICompatConfig {
        return .{
            .base = .{ .id = "groq", .base_url = "https://api.groq.com/openai", .api_key = api_key, .model = model, .max_context_tokens = 131072 },
        };
    }

    pub fn azure(api_key: []const u8, base_url: []const u8, model: []const u8, api_version: []const u8) OpenAICompatConfig {
        return .{
            .base = .{ .id = "azure", .base_url = base_url, .api_key = api_key, .model = model },
            .quirks = .{ .azure_deployment = true, .api_version = api_version },
        };
    }

    pub fn openai(api_key: []const u8, model: []const u8) OpenAICompatConfig {
        return .{
            .base = .{ .id = "openai", .base_url = "https://api.openai.com", .api_key = api_key, .model = model, .max_context_tokens = 128_000 },
        };
    }

    pub fn mistral(api_key: []const u8, model: []const u8) OpenAICompatConfig {
        return .{
            .base = .{ .id = "mistral", .base_url = "https://api.mistral.ai", .api_key = api_key, .model = model, .max_context_tokens = 128_000 },
        };
    }
};

test "presets create valid configs" {
    const ds = presets.deepseek("key", "deepseek-chat");
    try std.testing.expectEqualStrings("deepseek", ds.base.id);
    try std.testing.expect(ds.quirks.supports_reasoning);
    try std.testing.expectEqual(@as(?u32, 65536), ds.base.max_context_tokens);

    const gr = presets.groq("key", "llama-3");
    try std.testing.expectEqualStrings("groq", gr.base.id);

    const az = presets.azure("key", "https://myendpoint.openai.azure.com", "gpt-4o", "2024-02-01");
    try std.testing.expect(az.quirks.azure_deployment);
    try std.testing.expectEqualStrings("2024-02-01", az.quirks.api_version.?);
}

test "presets openai and mistral" {
    const oi = presets.openai("key", "gpt-4o");
    try std.testing.expectEqualStrings("openai", oi.base.id);
    try std.testing.expectEqualStrings("gpt-4o", oi.base.model);
    try std.testing.expectEqual(@as(?u32, 128_000), oi.base.max_context_tokens);

    const mi = presets.mistral("key", "mistral-large");
    try std.testing.expectEqualStrings("mistral", mi.base.id);
    try std.testing.expectEqualStrings("mistral-large", mi.base.model);
}

test "OpenAICompatProvider creates valid Provider" {
    var op = OpenAICompatProvider.init(std.testing.allocator, presets.openai("test-key", "gpt-4o"));
    const p = op.provider();
    try std.testing.expectEqualStrings("openai", p.getId());
    try std.testing.expectEqual(@as(u32, 128_000), p.getMaxContextTokens());
    try std.testing.expect(!p.supportsThinking());
}

test "OpenAICompatProvider deepseek supports thinking" {
    var op = OpenAICompatProvider.init(std.testing.allocator, presets.deepseek("key", "deepseek-r1"));
    const p = op.provider();
    try std.testing.expect(p.supportsThinking());
    try std.testing.expectEqual(@as(u32, 65536), p.getMaxContextTokens());
}

test "buildRequestBody produces valid OpenAI JSON" {
    const allocator = std.testing.allocator;
    const config = presets.openai("key", "gpt-4o");
    const body = try OpenAICompatProvider.buildRequestBody(
        allocator,
        config,
        &.{.{ .role = "user", .content = .{ .string = "hello" } }},
        null,
        .{ .max_tokens = 2048 },
    );
    defer allocator.free(body);
    const parsed = try json_mod.parse(allocator, body);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("gpt-4o", json_mod.getString(parsed.value, "model").?);
    try std.testing.expectEqual(true, json_mod.getBool(parsed.value, "stream").?);
    // stream_options should be present (openai preset supports it)
    try std.testing.expect(parsed.value.object.get("stream_options") != null);
}

test "buildRequestBody includes tools in OpenAI function format" {
    const allocator = std.testing.allocator;
    const config = presets.openai("key", "gpt-4o");
    const tools = [_]types.ToolSchema{
        .{
            .name = "search",
            .description = "Search the web",
            .input_schema = .{ .string = "{}" },
        },
    };
    const body = try OpenAICompatProvider.buildRequestBody(
        allocator,
        config,
        &.{},
        &tools,
        .{ .max_tokens = 1024 },
    );
    defer allocator.free(body);
    const parsed = try json_mod.parse(allocator, body);
    defer parsed.deinit();

    const tools_arr = parsed.value.object.get("tools").?;
    try std.testing.expectEqual(@as(usize, 1), tools_arr.array.items.len);
    const tool_obj = tools_arr.array.items[0];
    try std.testing.expectEqualStrings("function", json_mod.getString(tool_obj, "type").?);
}

test "OpenAICompatProvider streamTextFn returns non-null function" {
    const fn_ptr = OpenAICompatProvider.streamTextFn();
    try std.testing.expect(@intFromPtr(fn_ptr) != 0);
}
