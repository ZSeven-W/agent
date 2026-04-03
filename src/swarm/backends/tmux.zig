//! Tmux teammate backend — shell command wrappers.
//!
//! Creates and manages tmux panes for running teammate processes.

const std = @import("std");

pub const TmuxBackend = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TmuxBackend {
        return .{ .allocator = allocator };
    }

    /// Split the current window and run `command`, returning the new pane ID.
    /// Caller owns the returned slice.
    pub fn createPane(self: *TmuxBackend, command: []const u8) ![]const u8 {
        var child = std.process.Child.init(
            &.{ "tmux", "split-window", "-h", "-P", "-F", "#{pane_id}", command },
            self.allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 4096);
        errdefer self.allocator.free(stdout);

        // Drain stderr.
        if (child.stderr) |stderr| {
            const err_buf = stderr.readToEndAlloc(self.allocator, 4096) catch &.{};
            if (err_buf.len > 0) self.allocator.free(err_buf);
        }

        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return error.TmuxCommandFailed,
            else => return error.TmuxCommandFailed,
        }

        // Trim trailing newline from pane ID.
        const trimmed_len = std.mem.trimRight(u8, stdout, "\n\r").len;
        if (trimmed_len < stdout.len) {
            // Shrink in-place — we own the allocation.
            return stdout[0..trimmed_len];
        }
        return stdout;
    }

    /// Send keystrokes to a pane.
    pub fn sendKeys(self: *TmuxBackend, pane_id: []const u8, keys: []const u8) !void {
        var child = std.process.Child.init(
            &.{ "tmux", "send-keys", "-t", pane_id, keys, "Enter" },
            self.allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Drain stdout/stderr.
        if (child.stdout) |stdout| {
            const buf = stdout.readToEndAlloc(self.allocator, 4096) catch &.{};
            if (buf.len > 0) self.allocator.free(buf);
        }
        if (child.stderr) |stderr| {
            const buf = stderr.readToEndAlloc(self.allocator, 4096) catch &.{};
            if (buf.len > 0) self.allocator.free(buf);
        }

        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return error.TmuxCommandFailed,
            else => return error.TmuxCommandFailed,
        }
    }

    /// Kill a pane by ID.
    pub fn killPane(self: *TmuxBackend, pane_id: []const u8) !void {
        var child = std.process.Child.init(
            &.{ "tmux", "kill-pane", "-t", pane_id },
            self.allocator,
        );
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Drain stdout/stderr.
        if (child.stdout) |stdout| {
            const buf = stdout.readToEndAlloc(self.allocator, 4096) catch &.{};
            if (buf.len > 0) self.allocator.free(buf);
        }
        if (child.stderr) |stderr| {
            const buf = stderr.readToEndAlloc(self.allocator, 4096) catch &.{};
            if (buf.len > 0) self.allocator.free(buf);
        }

        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return error.TmuxCommandFailed,
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
