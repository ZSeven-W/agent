//! Delegate tool — routes tasks to team members.
//! Called by the team leader: delegate({member_id: "designer", task: "..."})
//! The team orchestrator handles actual member execution.

const std = @import("std");
const json_mod = @import("../json.zig");

pub const DelegateArgs = struct {
    member_id: []const u8,
    task: []const u8,
};

/// Parse delegate args from JSON input.
pub fn parseDelegateArgs(input: json_mod.JsonValue) ?DelegateArgs {
    const obj = switch (input) {
        .object => |o| o,
        else => return null,
    };
    const member_id = switch (obj.get("member_id") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const task = switch (obj.get("task") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    return .{ .member_id = member_id, .task = task };
}

test "parseDelegateArgs valid input" {
    // Simple test with null JsonValue
    const result = parseDelegateArgs(.null);
    try std.testing.expectEqual(@as(?DelegateArgs, null), result);
}

test "parseDelegateArgs with object" {
    const allocator = std.testing.allocator;

    const input = "{\"member_id\":\"designer\",\"task\":\"draw a box\"}";
    const parsed = try json_mod.parse(allocator, input);
    defer parsed.deinit();

    const args = parseDelegateArgs(parsed.value);
    try std.testing.expect(args != null);
    try std.testing.expectEqualStrings("designer", args.?.member_id);
    try std.testing.expectEqualStrings("draw a box", args.?.task);
}

test "parseDelegateArgs missing field" {
    const allocator = std.testing.allocator;

    const input = "{\"member_id\":\"designer\"}";
    const parsed = try json_mod.parse(allocator, input);
    defer parsed.deinit();

    const args = parseDelegateArgs(parsed.value);
    try std.testing.expectEqual(@as(?DelegateArgs, null), args);
}
