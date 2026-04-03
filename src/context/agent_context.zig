//! Thread-local agent identity isolation.
//!
//! Equivalent to Claude Code's AsyncLocalStorage<AgentContext>.
//! Each agent (main, subagent, teammate) has a distinct identity
//! stored in thread-local storage, enabling concurrent agents in
//! the same process without context interference.

const std = @import("std");
const abort_mod = @import("../abort.zig");
const uuid_mod = @import("../uuid.zig");

pub const AgentIdentity = union(enum) {
    main: void,
    subagent: SubagentIdentity,
    teammate: TeammateIdentity,
};

pub const SubagentIdentity = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    is_builtin: bool = false,
};

pub const TeammateIdentity = struct {
    agent_id: []const u8, // "name@team"
    agent_name: []const u8,
    team_name: []const u8,
    color: ?[]const u8 = null,
    is_leader: bool = false,
    parent_session_id: []const u8,
};

pub const AgentContext = struct {
    identity: AgentIdentity,
    allocator: std.mem.Allocator,
    abort_controller: *abort_mod.AbortController,

    /// Thread-local current agent context.
    threadlocal var current: ?*AgentContext = null;

    pub fn setCurrent(ctx: ?*AgentContext) void {
        current = ctx;
    }

    pub fn getCurrent() ?*AgentContext {
        return current;
    }

    pub fn isSubagent(self: *const AgentContext) bool {
        return self.identity == .subagent;
    }

    pub fn isTeammate(self: *const AgentContext) bool {
        return self.identity == .teammate;
    }

    pub fn getAgentId(self: *const AgentContext) ?[]const u8 {
        return switch (self.identity) {
            .main => null,
            .subagent => |s| s.id,
            .teammate => |t| t.agent_id,
        };
    }
};

/// Format agent ID: "name@teamName"
pub fn formatAgentId(name: []const u8, team_name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ name, team_name });
}

/// Parse agent ID: "name@team" → { name, team }
pub fn parseAgentId(agent_id: []const u8) struct { name: []const u8, team: []const u8 } {
    if (std.mem.indexOf(u8, agent_id, "@")) |idx| {
        return .{ .name = agent_id[0..idx], .team = agent_id[idx + 1 ..] };
    }
    return .{ .name = agent_id, .team = "" };
}

test "formatAgentId and parseAgentId" {
    const allocator = std.testing.allocator;
    const id = try formatAgentId("tester", "qa-squad", allocator);
    defer allocator.free(id);
    try std.testing.expectEqualStrings("tester@qa-squad", id);

    const parsed = parseAgentId("tester@qa-squad");
    try std.testing.expectEqualStrings("tester", parsed.name);
    try std.testing.expectEqualStrings("qa-squad", parsed.team);
}

test "parseAgentId with no @ returns full string as name" {
    const parsed = parseAgentId("solo-agent");
    try std.testing.expectEqualStrings("solo-agent", parsed.name);
    try std.testing.expectEqualStrings("", parsed.team);
}

test "AgentContext thread-local set/get" {
    const allocator = std.testing.allocator;
    var abort = abort_mod.AbortController{};
    var ctx = AgentContext{
        .identity = .{ .subagent = .{ .id = "test-123", .is_builtin = true } },
        .allocator = allocator,
        .abort_controller = &abort,
    };
    AgentContext.setCurrent(&ctx);
    defer AgentContext.setCurrent(null);

    const got = AgentContext.getCurrent().?;
    try std.testing.expect(got.isSubagent());
    try std.testing.expect(!got.isTeammate());
    try std.testing.expectEqualStrings("test-123", got.getAgentId().?);
}

test "AgentContext main identity has no agent id" {
    const allocator = std.testing.allocator;
    var abort = abort_mod.AbortController{};
    var ctx = AgentContext{
        .identity = .main,
        .allocator = allocator,
        .abort_controller = &abort,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.getAgentId());
    try std.testing.expect(!ctx.isSubagent());
    try std.testing.expect(!ctx.isTeammate());
}

test "AgentContext teammate identity" {
    const allocator = std.testing.allocator;
    var abort = abort_mod.AbortController{};
    var ctx = AgentContext{
        .identity = .{ .teammate = .{
            .agent_id = "tester@qa",
            .agent_name = "tester",
            .team_name = "qa",
            .color = "blue",
            .is_leader = false,
            .parent_session_id = "session-1",
        } },
        .allocator = allocator,
        .abort_controller = &abort,
    };
    try std.testing.expect(ctx.isTeammate());
    try std.testing.expectEqualStrings("tester@qa", ctx.getAgentId().?);
}
