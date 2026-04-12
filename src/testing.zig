// src/testing.zig
//! Test helpers: mock provider, fake tools.
const std = @import("std");
const providers_types = @import("providers/types.zig");
const streaming_events = @import("streaming/events.zig");
const tool_mod = @import("tool.zig");
const json_mod = @import("json.zig");

const MockStreamState = struct {
    deltas: []const streaming_events.StreamDelta,
    index: usize,

    fn next(ctx: *anyopaque) ?streaming_events.StreamDelta {
        const self: *MockStreamState = @ptrCast(@alignCast(ctx));
        if (self.index >= self.deltas.len) return null;
        const d = self.deltas[self.index];
        self.index += 1;
        return d;
    }
};

/// A mock provider that returns a sequence of scripted StreamDeltas.
/// Stores stream states inline (no heap allocation) so no cleanup is needed.
/// The MockProvider instance must remain valid for the lifetime of all iterators it produces.
pub const MockProvider = struct {
    responses: []const ScriptedResponse,
    response_index: usize = 0,
    allocator: std.mem.Allocator,
    /// Inline storage for stream states (max 16 concurrent streams).
    states: [16]MockStreamState = undefined,

    pub const ScriptedResponse = struct {
        deltas: []const streaming_events.StreamDelta,
    };

    pub fn init(allocator: std.mem.Allocator, responses: []const ScriptedResponse) MockProvider {
        return .{ .responses = responses, .response_index = 0, .allocator = allocator };
    }

    pub fn provider(self: *MockProvider) providers_types.Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = providers_types.Provider.VTable{
        .id = "mock",
        .max_context_tokens = 100_000,
        .supports_thinking = false,
        .supports_tool_use = true,
        .stream_text = streamText,
    };

    fn streamText(
        ptr: *anyopaque,
        _: []const providers_types.ApiMessage,
        _: ?[]const providers_types.ToolSchema,
        _: providers_types.StreamConfig,
    ) providers_types.StreamError!providers_types.StreamIterator {
        const self: *MockProvider = @ptrCast(@alignCast(ptr));
        if (self.response_index >= self.responses.len) return error.ServerError;
        const idx = self.response_index;
        self.states[idx] = .{
            .deltas = self.responses[idx].deltas,
            .index = 0,
        };
        self.response_index += 1;
        return .{
            .context = @ptrCast(&self.states[idx]),
            .nextFn = MockStreamState.next,
        };
    }
};

/// A fake tool that records calls and returns a fixed result.
pub const FakeTool = struct {
    call_count: u32 = 0,
    return_value: json_mod.JsonValue = .null,

    pub const name = "FakeTool";
    pub const input_schema = json_mod.JsonSchema{ .@"type" = "object" };

    pub fn call(self: *FakeTool, _: json_mod.JsonValue, _: *tool_mod.ToolUseContext) tool_mod.ToolCallError!tool_mod.ToolResult {
        self.call_count += 1;
        return .{ .data = self.return_value };
    }

    pub fn isReadOnly(_: *FakeTool, _: json_mod.JsonValue) bool {
        return false;
    }
};

// ─── Tests ───

const tool_builder = @import("tool.zig");

test "MockProvider returns scripted deltas" {
    const allocator = std.testing.allocator;
    const deltas = [_]streaming_events.StreamDelta{
        .{ .@"type" = .text_delta, .text = "hello" },
        .{ .@"type" = .text_delta, .text = " world" },
        .{ .@"type" = .message_stop },
    };
    var mock = MockProvider.init(allocator, &.{.{ .deltas = &deltas }});
    var p = mock.provider();

    var iter = try p.vtable.stream_text(p.ptr, &.{}, null, .{});
    const d1 = iter.next().?;
    try std.testing.expectEqualStrings("hello", d1.text.?);
    const d2 = iter.next().?;
    try std.testing.expectEqualStrings(" world", d2.text.?);
    const d3 = iter.next().?;
    try std.testing.expect(d3.@"type" == .message_stop);
    try std.testing.expectEqual(@as(?streaming_events.StreamDelta, null), iter.next());
}

test "MockProvider returns error when responses exhausted" {
    const allocator = std.testing.allocator;
    var mock = MockProvider.init(allocator, &.{});
    var p = mock.provider();

    try std.testing.expectError(error.ServerError, p.vtable.stream_text(p.ptr, &.{}, null, .{}));
}

test "MockProvider serves multiple scripted responses" {
    const allocator = std.testing.allocator;
    const resp1 = [_]streaming_events.StreamDelta{.{ .@"type" = .text_delta, .text = "first" }};
    const resp2 = [_]streaming_events.StreamDelta{.{ .@"type" = .text_delta, .text = "second" }};
    var mock = MockProvider.init(allocator, &.{
        .{ .deltas = &resp1 },
        .{ .deltas = &resp2 },
    });
    var p = mock.provider();

    // First call
    var iter1 = try p.vtable.stream_text(p.ptr, &.{}, null, .{});
    try std.testing.expectEqualStrings("first", iter1.next().?.text.?);

    // Second call
    var iter2 = try p.vtable.stream_text(p.ptr, &.{}, null, .{});
    try std.testing.expectEqualStrings("second", iter2.next().?.text.?);
}

test "MockProvider vtable metadata" {
    const allocator = std.testing.allocator;
    var mock = MockProvider.init(allocator, &.{});
    const p = mock.provider();

    try std.testing.expectEqualStrings("mock", p.getId());
    try std.testing.expectEqual(@as(u32, 100_000), p.getMaxContextTokens());
    try std.testing.expect(!p.supportsThinking());
}

test "FakeTool records calls and returns configured value" {
    var ft = FakeTool{ .return_value = .{ .string = "ok" } };
    const tool = tool_builder.buildTool(FakeTool, &ft);

    try std.testing.expectEqualStrings("FakeTool", tool.getName());
    try std.testing.expect(!tool.isReadOnly(.null));
    try std.testing.expectEqual(@as(u32, 0), ft.call_count);
}

test "FakeTool call increments count" {
    var ft = FakeTool{};
    var abort = @import("abort.zig").AbortController{};
    var cache = @import("file_cache.zig").FileStateCache.init(std.testing.allocator, 10, 1024);
    defer cache.deinit();
    var msgs = @import("message.zig").MessageStore.init(std.testing.allocator);
    defer msgs.deinit();
    var perm_ctx = @import("permission.zig").PermissionContext{};
    var hooks = @import("hook.zig").HookRunner.init(std.testing.allocator);
    defer hooks.deinit();

    var ctx = tool_builder.ToolUseContext{
        .allocator = std.testing.allocator,
        .cwd = "/tmp",
        .abort_controller = &abort,
        .file_cache = &cache,
        .messages = &msgs,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hooks,
    };

    const tool = tool_builder.buildTool(FakeTool, &ft);
    _ = try tool.call(.null, &ctx);
    _ = try tool.call(.null, &ctx);
    try std.testing.expectEqual(@as(u32, 2), ft.call_count);
}
