//! Tmux teammate backend — shell command wrappers.
//!
//! Creates and manages tmux panes for running teammate processes.

const std = @import("std");
const uuid_mod = @import("../../uuid.zig");

pub const TmuxBackend = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TmuxBackend {
        return .{ .allocator = allocator };
    }

    /// Split the current window and run `command`, returning the new pane ID.
    /// Caller owns the returned slice.
    pub fn createPane(self: *TmuxBackend, command: []const u8) ![]const u8 {
        const io = uuid_mod.defaultIo();
        const res = try std.process.run(self.allocator, io, .{
            .argv = &.{ "tmux", "split-window", "-h", "-P", "-F", "#{pane_id}", command },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        defer self.allocator.free(res.stderr);
        errdefer self.allocator.free(res.stdout);

        switch (res.term) {
            .exited => |code| if (code != 0) return error.TmuxCommandFailed,
            else => return error.TmuxCommandFailed,
        }

        // Trim trailing newline from pane ID.
        const trimmed_len = std.mem.trimRight(u8, res.stdout, "\n\r").len;
        if (trimmed_len < res.stdout.len) {
            // Shrink in-place — we own the allocation.
            return res.stdout[0..trimmed_len];
        }
        return res.stdout;
    }

    /// Send keystrokes to a pane.
    pub fn sendKeys(self: *TmuxBackend, pane_id: []const u8, keys: []const u8) !void {
        const io = uuid_mod.defaultIo();
        const res = try std.process.run(self.allocator, io, .{
            .argv = &.{ "tmux", "send-keys", "-t", pane_id, keys, "Enter" },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        defer self.allocator.free(res.stdout);
        defer self.allocator.free(res.stderr);

        switch (res.term) {
            .exited => |code| if (code != 0) return error.TmuxCommandFailed,
            else => return error.TmuxCommandFailed,
        }
    }

    /// Kill a pane by ID.
    pub fn killPane(self: *TmuxBackend, pane_id: []const u8) !void {
        const io = uuid_mod.defaultIo();
        const res = try std.process.run(self.allocator, io, .{
            .argv = &.{ "tmux", "kill-pane", "-t", pane_id },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        defer self.allocator.free(res.stdout);
        defer self.allocator.free(res.stderr);

        switch (res.term) {
            .exited => |code| if (code != 0) return error.TmuxCommandFailed,
            else => return error.TmuxCommandFailed,
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TmuxBackend init" {
    const backend = TmuxBackend.init(std.testing.allocator);
    _ = backend;
}
