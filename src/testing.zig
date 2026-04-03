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
