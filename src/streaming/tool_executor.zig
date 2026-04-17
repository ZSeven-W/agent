// src/streaming/tool_executor.zig
const std = @import("std");
const tool_mod = @import("../tool.zig");
const message_mod = @import("../message.zig");
const abort_mod = @import("../abort.zig");

pub const ToolStatus = enum { queued, executing, completed, yielded };

pub const TrackedTool = struct {
    block: message_mod.ToolUseBlock,
    assistant_msg_uuid: message_mod.Uuid,
    status: ToolStatus = .queued,
    result: ?tool_mod.ToolResult = null,
    error_message: ?[]const u8 = null,
};

pub const StreamingToolExecutor = struct {
    tracked: std.ArrayList(TrackedTool),
    sibling_abort: abort_mod.AbortController = .{},
    allocator: std.mem.Allocator,
    yield_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) StreamingToolExecutor {
        return .{
            .tracked = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StreamingToolExecutor) void {
        self.tracked.deinit(self.allocator);
    }

    /// Add a tool use block from streaming.
    pub fn addTool(self: *StreamingToolExecutor, block: message_mod.ToolUseBlock, assistant_uuid: message_mod.Uuid) !void {
        try self.tracked.append(self.allocator, .{
            .block = block,
            .assistant_msg_uuid = assistant_uuid,
        });
    }

    /// Mark a tracked tool as completed with result.
    pub fn complete(self: *StreamingToolExecutor, tool_use_id: []const u8, result: tool_mod.ToolResult) void {
        for (self.tracked.items) |*t| {
            if (std.mem.eql(u8, t.block.id, tool_use_id)) {
                t.status = .completed;
                t.result = result;
                return;
            }
        }
    }

    /// Mark a tracked tool as failed.
    pub fn fail(self: *StreamingToolExecutor, tool_use_id: []const u8, err: []const u8) void {
        for (self.tracked.items) |*t| {
            if (std.mem.eql(u8, t.block.id, tool_use_id)) {
                t.status = .completed;
                t.error_message = err;
                return;
            }
        }
    }

    /// Get next completed result in tool receipt order.
    pub fn nextCompleted(self: *StreamingToolExecutor) ?*TrackedTool {
        while (self.yield_index < self.tracked.items.len) {
            const t = &self.tracked.items[self.yield_index];
            if (t.status == .completed) {
                t.status = .yielded;
                self.yield_index += 1;
                return t;
            }
            // Not yet completed — wait (must preserve order)
            return null;
        }
        return null;
    }

    /// Count of tools not yet yielded.
    pub fn pendingCount(self: *const StreamingToolExecutor) usize {
        var count: usize = 0;
        for (self.tracked.items) |t| {
            if (t.status != .yielded) count += 1;
        }
        return count;
    }

    /// Abort all pending tools.
    pub fn discard(self: *StreamingToolExecutor) void {
        self.sibling_abort.abort("discarded");
    }
};

test "StreamingToolExecutor add and complete in order" {
    const allocator = std.testing.allocator;
    var exec = StreamingToolExecutor.init(allocator);
    defer exec.deinit();

    const uuid = @import("../uuid.zig").v4();

    try exec.addTool(.{ .id = "t1", .name = "Read", .input = .null }, uuid);
    try exec.addTool(.{ .id = "t2", .name = "Grep", .input = .null }, uuid);

    try std.testing.expectEqual(@as(usize, 2), exec.pendingCount());

    // Complete t2 first (out of order)
    exec.complete("t2", .{ .data = .null });

    // nextCompleted should wait for t1 (receipt order)
    try std.testing.expectEqual(@as(?*TrackedTool, null), exec.nextCompleted());

    // Complete t1
    exec.complete("t1", .{ .data = .null });

    // Now t1 should yield first
    const r1 = exec.nextCompleted().?;
    try std.testing.expectEqualStrings("t1", r1.block.id);

    // Then t2
    const r2 = exec.nextCompleted().?;
    try std.testing.expectEqualStrings("t2", r2.block.id);

    // No more
    try std.testing.expectEqual(@as(?*TrackedTool, null), exec.nextCompleted());
}

test "StreamingToolExecutor fail marks tool with error" {
    const allocator = std.testing.allocator;
    var exec = StreamingToolExecutor.init(allocator);
    defer exec.deinit();

    const uuid = @import("../uuid.zig").v4();
    try exec.addTool(.{ .id = "t1", .name = "BadTool", .input = .null }, uuid);

    exec.fail("t1", "permission denied");

    const completed = exec.nextCompleted().?;
    try std.testing.expectEqualStrings("t1", completed.block.id);
    try std.testing.expectEqual(@as(?tool_mod.ToolResult, null), completed.result);
    try std.testing.expectEqualStrings("permission denied", completed.error_message.?);
}

test "StreamingToolExecutor discard aborts sibling controller" {
    const allocator = std.testing.allocator;
    var exec = StreamingToolExecutor.init(allocator);
    defer exec.deinit();

    try std.testing.expect(!exec.sibling_abort.isAborted());
    exec.discard();
    try std.testing.expect(exec.sibling_abort.isAborted());
}

test "StreamingToolExecutor pendingCount tracks correctly" {
    const allocator = std.testing.allocator;
    var exec = StreamingToolExecutor.init(allocator);
    defer exec.deinit();

    const uuid = @import("../uuid.zig").v4();
    try std.testing.expectEqual(@as(usize, 0), exec.pendingCount());

    try exec.addTool(.{ .id = "a", .name = "A", .input = .null }, uuid);
    try exec.addTool(.{ .id = "b", .name = "B", .input = .null }, uuid);
    try std.testing.expectEqual(@as(usize, 2), exec.pendingCount());

    exec.complete("a", .{ .data = .null });
    // a is completed but not yet yielded
    try std.testing.expectEqual(@as(usize, 2), exec.pendingCount());

    _ = exec.nextCompleted(); // yield a
    try std.testing.expectEqual(@as(usize, 1), exec.pendingCount());

    exec.complete("b", .{ .data = .null });
    _ = exec.nextCompleted(); // yield b
    try std.testing.expectEqual(@as(usize, 0), exec.pendingCount());
}
