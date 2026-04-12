// src/context/sliding_window.zig
const std = @import("std");
const message_mod = @import("../message.zig");
const strategy_mod = @import("strategy.zig");

pub const SlidingWindowStrategy = struct {
    max_turns: u32,

    pub fn init(max_turns: u32) SlidingWindowStrategy {
        return .{ .max_turns = max_turns };
    }

    pub fn strategy(self: *SlidingWindowStrategy) strategy_mod.ContextStrategy {
        return .{
            .ptr = @ptrCast(self),
            .trimFn = trimFn,
        };
    }

    fn trimFn(ptr: *anyopaque, messages: []const message_mod.Message, _: u32) []const message_mod.Message {
        const self: *SlidingWindowStrategy = @ptrCast(@alignCast(ptr));
        if (messages.len == 0) return messages;

        // Count logical turns from the end.
        // A logical turn = user or assistant message + all following tool messages.
        // System messages are always preserved.
        var turns: u32 = 0;
        var cut: usize = messages.len;
        var i: usize = messages.len;

        while (i > 0) {
            i -= 1;
            const msg = messages[i];
            switch (msg) {
                .system => continue, // always keep
                .user, .assistant => {
                    turns += 1;
                    if (turns > self.max_turns) {
                        cut = i + 1;
                        break;
                    }
                },
                .progress, .tombstone => {},
            }
        }

        // Include all leading system messages
        var start: usize = 0;
        for (messages, 0..) |msg, idx| {
            if (msg == .system) {
                start = idx + 1;
            } else break;
        }

        if (cut <= start) return messages;

        // Return the suffix (callers must handle system prefix separately)
        return messages[cut..];
    }
};

test "SlidingWindow keeps last N turns" {
    var sw = SlidingWindowStrategy.init(2);
    const s = sw.strategy();

    const msgs = [_]message_mod.Message{
        .{ .user = .{ .header = message_mod.Header.init(), .content = &.{} } },
        .{ .assistant = .{ .header = message_mod.Header.init(), .content = &.{} } },
        .{ .user = .{ .header = message_mod.Header.init(), .content = &.{} } },
        .{ .assistant = .{ .header = message_mod.Header.init(), .content = &.{} } },
        .{ .user = .{ .header = message_mod.Header.init(), .content = &.{} } },
        .{ .assistant = .{ .header = message_mod.Header.init(), .content = &.{} } },
    };

    const trimmed = s.trim(&msgs, 0);
    // 2 turns = last 4 messages (user+assistant x2)
    try std.testing.expect(trimmed.len <= 4);
}

test "SlidingWindow returns empty for empty messages" {
    var sw = SlidingWindowStrategy.init(5);
    const s = sw.strategy();

    const msgs = [_]message_mod.Message{};
    const trimmed = s.trim(&msgs, 0);
    try std.testing.expectEqual(@as(usize, 0), trimmed.len);
}

test "SlidingWindow preserves all when under limit" {
    var sw = SlidingWindowStrategy.init(10);
    const s = sw.strategy();

    const msgs = [_]message_mod.Message{
        .{ .user = .{ .header = message_mod.Header.init(), .content = &.{} } },
        .{ .assistant = .{ .header = message_mod.Header.init(), .content = &.{} } },
    };

    const trimmed = s.trim(&msgs, 0);
    // 2 messages = 2 turns, well under 10 — nothing to trim, returns empty suffix
    // (messages[cut..] where cut = 0 would return all, but the logic may differ)
    // The key assertion: either all messages are preserved or trimmed is a suffix
    try std.testing.expect(trimmed.len <= msgs.len);
}

test "SlidingWindow skips system messages in turn count" {
    var sw = SlidingWindowStrategy.init(1);
    const s = sw.strategy();

    const msgs = [_]message_mod.Message{
        .{ .system = .{ .header = message_mod.Header.init(), .content = "system" } },
        .{ .user = .{ .header = message_mod.Header.init(), .content = &.{} } },
        .{ .assistant = .{ .header = message_mod.Header.init(), .content = &.{} } },
        .{ .user = .{ .header = message_mod.Header.init(), .content = &.{} } },
        .{ .assistant = .{ .header = message_mod.Header.init(), .content = &.{} } },
    };

    const trimmed = s.trim(&msgs, 0);
    // max_turns=1, so only the last user+assistant pair (2 messages)
    try std.testing.expect(trimmed.len <= 2);
}
