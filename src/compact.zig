// src/compact.zig
const std = @import("std");
const message_mod = @import("message.zig");

pub const CompactConfig = struct {
    token_threshold: u64 = 100_000,
    summary_max_tokens: u32 = 4096,
};

pub const CompactResult = struct {
    boundary_marker: message_mod.SystemMessage,
    summary_messages: []message_mod.UserMessage,
    pre_compact_token_count: ?u64 = null,
    post_compact_token_count: ?u64 = null,
};

/// Estimate token count for a message store (rough: 4 chars ≈ 1 token).
pub fn estimateTokens(messages: []const message_mod.Message) u64 {
    var chars: u64 = 0;
    for (messages) |msg| {
        switch (msg) {
            .user => |m| {
                for (m.content) |block| {
                    switch (block) {
                        .text => |t| chars += t.len,
                        else => chars += 100,
                    }
                }
            },
            .assistant => |m| {
                for (m.content) |block| {
                    switch (block) {
                        .text => |t| chars += t.len,
                        else => chars += 100,
                    }
                }
            },
            .system => |m| chars += m.content.len,
            else => {},
        }
    }
    return chars / 4;
}

/// Check if compaction should trigger.
pub fn shouldCompact(messages: []const message_mod.Message, config: CompactConfig) bool {
    return estimateTokens(messages) > config.token_threshold;
}

/// Build post-compact messages: boundary marker + summary.
pub fn buildPostCompactMessages(
    allocator: std.mem.Allocator,
    summary_text: []const u8,
    pre_tokens: u64,
) !CompactResult {
    const boundary = message_mod.SystemMessage{
        .header = message_mod.Header.init(),
        .content = "--- Conversation compacted ---",
        .subtype = .compact_boundary,
    };

    const summary_msg = try allocator.create(message_mod.UserMessage);
    summary_msg.* = .{
        .header = message_mod.Header.init(),
        .content = &.{.{ .text = summary_text }},
        .is_meta = true,
    };

    return .{
        .boundary_marker = boundary,
        .summary_messages = @as([*]message_mod.UserMessage, @ptrCast(summary_msg))[0..1],
        .pre_compact_token_count = pre_tokens,
    };
}

test "estimateTokens rough count" {
    const msgs = [_]message_mod.Message{
        .{ .system = .{ .header = message_mod.Header.init(), .content = "You are helpful." } },
    };
    const tokens = estimateTokens(&msgs);
    try std.testing.expectEqual(@as(u64, 4), tokens);
}

test "shouldCompact returns false below threshold" {
    const msgs = [_]message_mod.Message{
        .{ .system = .{ .header = message_mod.Header.init(), .content = "short" } },
    };
    try std.testing.expect(!shouldCompact(&msgs, .{ .token_threshold = 100 }));
}
