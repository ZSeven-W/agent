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

    pub fn init(allocator: std.mem.Allocator, config: OpenAICompatConfig) OpenAICompatProvider {
        return .{ .config = config, .allocator = allocator };
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
        } else std.fmt.allocPrint(self.allocator, "{s}/v1/chat/completions", .{base_url}) catch
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
            response.close();
            return switch (@intFromEnum(response.status)) {
                401 => error.AuthenticationFailed,
                429 => error.RateLimited,
                else => error.ServerError,
            };
        }

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
        for (messages) |msg| {
            var msg_obj = std.json.ObjectMap.init(allocator);
            try msg_obj.put("role", .{ .string = msg.role });
            try msg_obj.put("content", msg.content);
            try msgs_arr.append(.{ .object = msg_obj });
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

const OpenAIStreamState = struct {
    http: http_client.HttpClient,
    response: http_client.StreamingResponse,
    parser: sse_parser_mod.SseParser,
    allocator: std.mem.Allocator,
    read_buf: [8192]u8,
    done: bool = false,

    fn nextDelta(ctx: *anyopaque) ?types.StreamDelta {
        const self: *OpenAIStreamState = @ptrCast(@alignCast(ctx));
        if (self.done) {
            // Already cleaned up — do NOT touch self further.
            return null;
        }

        if (self.parser.next()) |sse_event| {
            return self.parseSseToStreamDelta(sse_event);
        }

        const n = self.response.readChunk(&self.read_buf) catch {
            self.cleanup();
            return null;
        };
        if (n == 0) {
            self.cleanup();
            return null;
        }

        self.parser.feed(self.read_buf[0..n]) catch {
            self.cleanup();
            return null;
        };
        if (self.parser.next()) |sse_event| {
            return self.parseSseToStreamDelta(sse_event);
        }
        return null;
    }

    fn parseSseToStreamDelta(self: *OpenAIStreamState, sse: sse_parser_mod.SseEvent) ?types.StreamDelta {
        // [DONE] signals end of stream — clean up immediately
        if (std.mem.eql(u8, sse.data, "[DONE]")) {
            self.cleanup();
            return null;
        }

        // Parse the JSON delta
        const parsed = json_mod.parse(std.heap.page_allocator, sse.data) catch return null;
        defer parsed.deinit();

        // choices[0].delta.content -> text_delta
        const choices = parsed.value.object.get("choices") orelse return null;
        if (choices.array.items.len == 0) return null;
        const delta = choices.array.items[0].object.get("delta") orelse return null;

        if (json_mod.getString(delta, "content")) |text| {
            return .{ .@"type" = .text_delta, .text = text };
        }

        // finish_reason means message_stop — clean up now so the next
        // nextDelta() call sees done=true and returns null safely.
        if (choices.array.items[0].object.get("finish_reason")) |_| {
            self.cleanup();
            return .{ .@"type" = .message_stop };
        }

        return null;
    }

    fn cleanup(self: *OpenAIStreamState) void {
        self.done = true;
        self.parser.deinit();
        self.response.close();
        self.http.deinit();
        self.allocator.destroy(self);
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
