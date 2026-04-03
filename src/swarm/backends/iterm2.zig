//! iTerm2 teammate backend (stub).
//!
//! Future implementation will use iTerm2's proprietary escape sequences
//! to create split panes and send commands.

const std = @import("std");

pub const ITerm2Backend = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ITerm2Backend {
        return .{ .allocator = allocator };
    }

    /// Create a new iTerm2 split pane running `command`.
    pub fn createPane(_: *ITerm2Backend, _: []const u8) ![]const u8 {
        return error.NotImplemented;
    }

    /// Send a command string to an iTerm2 pane.
    pub fn sendCommand(_: *ITerm2Backend, _: []const u8, _: []const u8) !void {
        return error.NotImplemented;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ITerm2Backend init" {
    const backend = ITerm2Backend.init(std.testing.allocator);
    _ = backend;
}

test "ITerm2Backend createPane returns NotImplemented" {
    var backend = ITerm2Backend.init(std.testing.allocator);
    const result = backend.createPane("echo hello");
    try std.testing.expectError(error.NotImplemented, result);
}

test "ITerm2Backend sendCommand returns NotImplemented" {
    var backend = ITerm2Backend.init(std.testing.allocator);
    const result = backend.sendCommand("pane-1", "ls");
    try std.testing.expectError(error.NotImplemented, result);
}
