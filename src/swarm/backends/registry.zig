//! Backend registry — detects the best available teammate backend.
//!
//! Priority: iTerm2 (if ITERM_SESSION_ID env) > tmux (if TMUX env or
//! `which tmux` succeeds) > in_process (always available).

const std = @import("std");

pub const BackendType = enum {
    in_process,
    tmux,
    iterm2,
};

pub const BackendRegistry = struct {
    cached: ?BackendType = null,

    /// Detect the best available backend, caching the result.
    pub fn detect(self: *BackendRegistry) BackendType {
        if (self.cached) |c| return c;

        // Terminal multiplexer backends (iTerm2, tmux) only exist on
        // Unix-like hosts. std.posix.getenv is also a compile error on
        // Windows (env strings are WTF-16), so gate the whole lookup behind
        // a comptime OS check.
        if (comptime @import("builtin").os.tag != .windows) {
            // iTerm2 — highest priority.
            if (std.posix.getenv("ITERM_SESSION_ID") != null) {
                self.cached = .iterm2;
                return .iterm2;
            }

            // tmux — check env variable first.
            if (std.posix.getenv("TMUX") != null) {
                self.cached = .tmux;
                return .tmux;
            }

            // tmux — check if binary is on PATH.
            if (tmuxBinaryExists()) {
                self.cached = .tmux;
                return .tmux;
            }
        }

        // Fallback — always available.
        self.cached = .in_process;
        return .in_process;
    }

    /// Clear the cached detection result.
    pub fn reset(self: *BackendRegistry) void {
        self.cached = null;
    }
};

/// Check whether `tmux` is available on PATH by running `which tmux`.
fn tmuxBinaryExists() bool {
    var child = std.process.Child.init(
        &.{ "which", "tmux" },
        std.heap.page_allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return false;

    // Drain stdout/stderr so the child doesn't block.
    if (child.stdout) |stdout| {
        _ = stdout.readToEndAlloc(std.heap.page_allocator, 4096) catch {};
    }
    if (child.stderr) |stderr| {
        _ = stderr.readToEndAlloc(std.heap.page_allocator, 4096) catch {};
    }

    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "BackendRegistry detect returns a valid backend" {
    var reg = BackendRegistry{};
    const result = reg.detect();
    try std.testing.expect(result == .in_process or result == .tmux or result == .iterm2);
}

test "BackendRegistry caches result" {
    var reg = BackendRegistry{};
    const first = reg.detect();
    const second = reg.detect();
    try std.testing.expectEqual(first, second);
    try std.testing.expect(reg.cached != null);
}

test "BackendRegistry reset clears cache" {
    var reg = BackendRegistry{};
    _ = reg.detect();
    try std.testing.expect(reg.cached != null);
    reg.reset();
    try std.testing.expectEqual(@as(?BackendType, null), reg.cached);
}
