//! Thread-safe queue for external tool result resolution.
//!
//! JS calls `push()` from the main thread to deposit a tool result.
//! The Zig query loop calls `waitFor()` from a worker thread, blocking
//! until the matching result is available.

const std = @import("std");
const json_mod = @import("json.zig");

pub const ExternalToolResult = struct {
    tool_use_id: []const u8,
    result_json: []const u8,
    is_error: bool = false,
};

pub const ExternalToolQueue = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    results: std.ArrayList(ExternalToolResult),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExternalToolQueue {
        return .{
            .results = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ExternalToolQueue) void {
        for (self.results.items) |r| {
            self.allocator.free(r.tool_use_id);
            self.allocator.free(r.result_json);
        }
        self.results.deinit(self.allocator);
    }

    /// Push a tool result from the JS main thread. Wakes any blocked waitFor().
    pub fn push(self: *ExternalToolQueue, tool_use_id: []const u8, result_json: []const u8, is_error: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id_dupe = try self.allocator.dupe(u8, tool_use_id);
        const json_dupe = try self.allocator.dupe(u8, result_json);

        try self.results.append(self.allocator, .{
            .tool_use_id = id_dupe,
            .result_json = json_dupe,
            .is_error = is_error,
        });
        self.cond.signal();
    }

    /// Block until a result for `tool_use_id` is available, or abort is signaled.
    /// Returns null if aborted.
    pub fn waitFor(
        self: *ExternalToolQueue,
        tool_use_id: []const u8,
        abort: *const std.atomic.Value(bool),
    ) ?ExternalToolResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (abort.load(.acquire)) return null;

            for (self.results.items, 0..) |r, i| {
                if (std.mem.eql(u8, r.tool_use_id, tool_use_id)) {
                    _ = self.results.swapRemove(i);
                    return r;
                }
            }

            self.cond.timedWait(&self.mutex, 100 * std.time.ns_per_ms) catch {};
        }
    }
};

test "ExternalToolQueue push and waitFor" {
    const allocator = std.testing.allocator;
    var queue = ExternalToolQueue.init(allocator);
    defer queue.deinit();
    var abort_flag = std.atomic.Value(bool).init(false);

    try queue.push("tool-1", "{\"success\":true}", false);

    const result = queue.waitFor("tool-1", &abort_flag);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("tool-1", result.?.tool_use_id);
    try std.testing.expectEqualStrings("{\"success\":true}", result.?.result_json);

    allocator.free(result.?.tool_use_id);
    allocator.free(result.?.result_json);
}

test "ExternalToolQueue waitFor returns null on abort" {
    const allocator = std.testing.allocator;
    var queue = ExternalToolQueue.init(allocator);
    defer queue.deinit();
    var abort_flag = std.atomic.Value(bool).init(true);

    const result = queue.waitFor("tool-x", &abort_flag);
    try std.testing.expectEqual(@as(?ExternalToolResult, null), result);
}
