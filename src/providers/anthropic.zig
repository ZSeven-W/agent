// src/providers/anthropic.zig
const std = @import("std");
const types = @import("types.zig");
const streaming_events = @import("../streaming/events.zig");
const http_client = @import("../http/client.zig");
const sse_parser_mod = @import("../http/sse_parser.zig");
const json_mod = @import("../json.zig");

pub const AnthropicProvider = struct {
    config: types.ProviderConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: types.ProviderConfig) AnthropicProvider {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn provider(self: *AnthropicProvider) types.Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = types.Provider.VTable{
        .id = "anthropic",
        .max_context_tokens = 200_000,
        .supports_thinking = true,
        .supports_tool_use = true,
        .stream_text = streamText,
    };

    /// Return the stream_text function pointer at runtime (workaround for
    /// static-lib-to-dylib relocation issue where const vtable fn ptrs are 0).
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
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        // Build request body JSON
        const body = buildRequestBody(self.allocator, self.config.model, messages, tools, config) catch
            return error.InvalidRequest;

        const url = if (self.config.base_url) |bu|
            std.fmt.allocPrint(self.allocator, "{s}/v1/messages", .{bu}) catch return error.InvalidRequest
        else
            std.fmt.allocPrint(self.allocator, "https://api.anthropic.com/v1/messages", .{}) catch return error.InvalidRequest;

        var http = http_client.HttpClient.init(self.allocator);
        var response = http.streamRequest(.{
            .url = url,
            .body = body,
            .headers = &.{
                .{ .name = "x-api-key", .value = self.config.api_key orelse "" },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
                .{ .name = "content-type", .value = "application/json" },
            },
        }) catch return error.ConnectionFailed;

        if (response.status != .ok) {
            // Log status — skip reading error body because some providers
            // (e.g. Volcengine/Doubao) send error responses without proper
            // Content-Length / Transfer-Encoding, causing reader() to panic.
            std.debug.print("[http] API error {d}\n", .{@intFromEnum(response.status)});
            response.close();
            return switch (@intFromEnum(response.status)) {
                401 => error.AuthenticationFailed,
                429 => error.RateLimited,
                else => error.ServerError,
            };
        }

        const state = self.allocator.create(AnthropicStreamState) catch return error.ConnectionFailed;
        state.* = .{
            .http = http,
            .response = response,
            .parser = sse_parser_mod.SseParser.init(self.allocator),
            .allocator = self.allocator,
            .read_buf = undefined,
            .url = url,
            .body = body,
        };

        return .{
            .context = @ptrCast(state),
            .nextFn = AnthropicStreamState.nextDelta,
        };
    }

    pub fn buildRequestBody(
        allocator: std.mem.Allocator,
        model: []const u8,
        messages: []const types.ApiMessage,
        tools: ?[]const types.ToolSchema,
        config: types.StreamConfig,
    ) ![]const u8 {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("model", .{ .string = model });
        try obj.put("stream", .{ .bool = true });
        try obj.put("max_tokens", .{ .integer = @intCast(config.max_tokens) });

        // Messages array
        var msgs_arr = std.json.Array.init(allocator);
        for (messages) |msg| {
            var msg_obj = std.json.ObjectMap.init(allocator);
            try msg_obj.put("role", .{ .string = msg.role });
            try msg_obj.put("content", msg.content);
            try msgs_arr.append(.{ .object = msg_obj });
        }
        try obj.put("messages", .{ .array = msgs_arr });

        if (config.system_prompt) |sp| {
            try obj.put("system", .{ .string = sp });
        }

        if (tools) |t| {
            var tools_arr = std.json.Array.init(allocator);
            for (t) |tool_schema| {
                var tool_obj = std.json.ObjectMap.init(allocator);
                try tool_obj.put("name", .{ .string = tool_schema.name });
                try tool_obj.put("description", .{ .string = tool_schema.description });
                try tool_obj.put("input_schema", tool_schema.input_schema);
                try tools_arr.append(.{ .object = tool_obj });
            }
            try obj.put("tools", .{ .array = tools_arr });
        }

        return json_mod.stringify(allocator, .{ .object = obj });
    }
};

const AnthropicStreamState = struct {
    http: http_client.HttpClient,
    response: http_client.StreamingResponse,
    parser: sse_parser_mod.SseParser,
    allocator: std.mem.Allocator,
    read_buf: [8192]u8,
    url: []const u8,
    body: []const u8,
    done: bool = false,
    cleaned: bool = false,

    fn nextDelta(ctx: *anyopaque) ?types.StreamDelta {
        const self: *AnthropicStreamState = @ptrCast(@alignCast(ctx));

        // Stream already ended — release resources on the FIRST post-done call,
        // then return null on all subsequent calls.
        if (self.done) {
            if (!self.cleaned) {
                // Save allocator on stack before any cleanup — self will be
                // freed by destroy() at the end of this block.
                const alloc = self.allocator;
                self.cleaned = true;
                self.parser.deinit();
                self.response.close();
                self.http.deinit();
                alloc.free(self.url);
                alloc.free(self.body);
                alloc.destroy(self);
            }
            return null;
        }

        // 1. Drain any buffered SSE events from previous reads
        if (self.drainParsedEvent()) |delta| return delta;

        // 2. Read ONE chunk from the HTTP response
        const n = self.response.readChunk(&self.read_buf) catch {
            self.done = true;
            return null;
        };
        if (n == 0) {
            self.done = true;
            return null;
        }

        // 3. Feed to parser and try to extract an event
        self.parser.feed(self.read_buf[0..n]) catch {
            self.done = true;
            return null;
        };

        return self.drainParsedEvent();
    }

    /// Try to pull the next recognized event from the SSE parser.
    /// Skips unrecognized events (e.g. "ping") automatically.
    /// Sets done=true on message_stop so we never block on readChunk again.
    fn drainParsedEvent(self: *AnthropicStreamState) ?types.StreamDelta {
        while (self.parser.next()) |sse_event| {
            defer self.allocator.free(sse_event.data);
            defer if (sse_event.event) |e| self.allocator.free(e);
            defer if (sse_event.id) |i| self.allocator.free(i);
            if (parseSseToStreamDelta(self.allocator, sse_event)) |delta| {
                if (delta.@"type" == .message_stop) {
                    self.done = true;
                }
                return delta;
            }
        }
        return null;
    }

    fn parseSseToStreamDelta(allocator: std.mem.Allocator, sse: sse_parser_mod.SseEvent) ?types.StreamDelta {
        const event_type = sse.event orelse return null;

        if (std.mem.eql(u8, event_type, "message_start")) {
            return .{ .@"type" = .message_start };
        } else if (std.mem.eql(u8, event_type, "content_block_start")) {
            // Parse content_block to detect tool_use blocks:
            // {"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_xxx","name":"generate_design","input":{}}}
            const block_info = parseContentBlockStart(allocator, sse.data);
            return .{
                .@"type" = .content_block_start,
                .tool_use_id = block_info.tool_use_id,
                .tool_name = block_info.tool_name,
            };
        } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
            // sse.data is JSON: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
            // or thinking: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"..."}}
            // or tool input: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"..."}}
            const delta_info = parseDeltaJson(allocator, sse.data);
            return .{ .@"type" = delta_info.delta_type, .text = delta_info.text, .partial_json = delta_info.partial_json };
        } else if (std.mem.eql(u8, event_type, "content_block_stop")) {
            return .{ .@"type" = .content_block_stop };
        } else if (std.mem.eql(u8, event_type, "message_delta")) {
            return .{ .@"type" = .message_delta };
        } else if (std.mem.eql(u8, event_type, "message_stop")) {
            return .{ .@"type" = .message_stop };
        }
        return null;
    }

    const DeltaInfo = struct {
        delta_type: streaming_events.DeltaType,
        text: ?[]const u8,
        partial_json: ?[]const u8 = null,
    };

    const ContentBlockInfo = struct {
        tool_use_id: ?[]const u8 = null,
        tool_name: ?[]const u8 = null,
    };

    /// Parse content_block_start data to extract tool_use metadata.
    /// Anthropic format: {"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_xxx","name":"generate_design","input":{}}}
    fn parseContentBlockStart(allocator: std.mem.Allocator, data: []const u8) ContentBlockInfo {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return .{};
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return .{};
        const block = root.object.get("content_block") orelse return .{};
        if (block != .object) return .{};

        // Check if this is a tool_use block
        const block_type = block.object.get("type") orelse return .{};
        if (block_type != .string) return .{};
        if (!std.mem.eql(u8, block_type.string, "tool_use")) return .{};

        // Extract id and name
        var info = ContentBlockInfo{};
        if (block.object.get("id")) |id_val| {
            if (id_val == .string) info.tool_use_id = allocator.dupe(u8, id_val.string) catch null;
        }
        if (block.object.get("name")) |name_val| {
            if (name_val == .string) info.tool_name = allocator.dupe(u8, name_val.string) catch null;
        }
        return info;
    }

    /// Parse JSON data from a content_block_delta event.
    /// Extracts delta.text for text_delta, delta.thinking for thinking_delta.
    fn parseDeltaJson(allocator: std.mem.Allocator, data: []const u8) DeltaInfo {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
            return .{ .delta_type = .text_delta, .text = null };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return .{ .delta_type = .text_delta, .text = null };
        const delta_obj = root.object.get("delta") orelse return .{ .delta_type = .text_delta, .text = null };
        if (delta_obj != .object) return .{ .delta_type = .text_delta, .text = null };

        // Check delta type
        const dtype = delta_obj.object.get("type") orelse return .{ .delta_type = .text_delta, .text = null };
        if (dtype != .string) return .{ .delta_type = .text_delta, .text = null };

        if (std.mem.eql(u8, dtype.string, "thinking_delta")) {
            const val = delta_obj.object.get("thinking") orelse return .{ .delta_type = .thinking_delta, .text = null };
            if (val != .string) return .{ .delta_type = .thinking_delta, .text = null };
            return .{ .delta_type = .thinking_delta, .text = allocator.dupe(u8, val.string) catch null };
        }

        // input_json_delta: tool call argument streaming
        // {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"..."}}
        if (std.mem.eql(u8, dtype.string, "input_json_delta")) {
            const val = delta_obj.object.get("partial_json") orelse return .{ .delta_type = .tool_use_delta, .text = null, .partial_json = null };
            if (val != .string) return .{ .delta_type = .tool_use_delta, .text = null, .partial_json = null };
            return .{ .delta_type = .tool_use_delta, .text = null, .partial_json = allocator.dupe(u8, val.string) catch null };
        }

        // text_delta
        const val = delta_obj.object.get("text") orelse return .{ .delta_type = .text_delta, .text = null };
        if (val != .string) return .{ .delta_type = .text_delta, .text = null };
        return .{ .delta_type = .text_delta, .text = allocator.dupe(u8, val.string) catch null };
    }
};

test "AnthropicProvider creates valid Provider" {
    var ap = AnthropicProvider.init(std.testing.allocator, .{
        .id = "anthropic",
        .model = "claude-sonnet-4-6",
        .api_key = "test-key",
    });
    const p = ap.provider();
    try std.testing.expectEqualStrings("anthropic", p.getId());
    try std.testing.expectEqual(@as(u32, 200_000), p.getMaxContextTokens());
    try std.testing.expect(p.supportsThinking());
}

test "buildRequestBody produces valid JSON" {
    const allocator = std.testing.allocator;
    const body = try AnthropicProvider.buildRequestBody(
        allocator,
        "claude-sonnet-4-6",
        &.{.{ .role = "user", .content = .{ .string = "hello" } }},
        null,
        .{ .max_tokens = 1024 },
    );
    defer allocator.free(body);
    const parsed = try json_mod.parse(allocator, body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("claude-sonnet-4-6", json_mod.getString(parsed.value, "model").?);
    try std.testing.expectEqual(true, json_mod.getBool(parsed.value, "stream").?);
}
