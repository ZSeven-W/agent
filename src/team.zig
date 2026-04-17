//! Team orchestrator — leader + member coordination.
//!
//! The leader QueryEngine runs the main loop. When tools dispatch to
//! the "delegate" tool, the team runs the target member's engine,
//! wraps member events in member_start/member_end, and returns
//! the member's result as the delegate tool result.

const std = @import("std");
const query_engine_mod = @import("query_engine.zig");
const streaming = @import("streaming.zig");
const streaming_events = @import("streaming/events.zig");
const message_mod = @import("message.zig");
const abort_mod = @import("abort.zig");
const tools_reg = @import("tools/registry.zig");
const providers_types = @import("providers/types.zig");
const perm = @import("permission.zig");
const hook_mod = @import("hook.zig");
const context_mod = @import("context.zig");
const json_mod = @import("json.zig");

pub const TeamMemberConfig = struct {
    id: []const u8,
    provider: *providers_types.Provider,
    tools: *tools_reg.ToolRegistry,
    system_prompt: ?[]const u8 = null,
    max_turns: u32 = 20,
    max_output_tokens: u32 = 16_384,
};

pub const TeamConfig = struct {
    allocator: std.mem.Allocator,
    lead_provider: *providers_types.Provider,
    lead_tools: *tools_reg.ToolRegistry,
    lead_system_prompt: ?[]const u8 = null,
    lead_max_turns: u32 = 20,
    lead_max_output_tokens: u32 = 8192,
    members: []const TeamMemberConfig,
};

pub const Team = struct {
    allocator: std.mem.Allocator,
    lead: query_engine_mod.QueryEngine,
    members: std.StringHashMap(query_engine_mod.QueryEngine),
    abort: abort_mod.AbortController,
    // Explicitly owned resources for cleanup.
    // We store each resource type separately to avoid type-erasure complexity.
    perm_ctxs: std.ArrayList(*perm.PermissionContext),
    hook_runners: std.ArrayList(*hook_mod.HookRunner),
    sliding_windows: std.ArrayList(*context_mod.SlidingWindowStrategy),
    strategies: std.ArrayList(*context_mod.ContextStrategy),

    pub fn init(config: TeamConfig) !Team {
        var members = std.StringHashMap(query_engine_mod.QueryEngine).init(config.allocator);
        var perm_ctxs = std.ArrayList(*perm.PermissionContext){};
        var hook_runners = std.ArrayList(*hook_mod.HookRunner){};
        var sliding_windows = std.ArrayList(*context_mod.SlidingWindowStrategy){};
        var strategies = std.ArrayList(*context_mod.ContextStrategy){};

        errdefer {
            for (hook_runners.items) |h| h.deinit();
            for (perm_ctxs.items) |p| config.allocator.destroy(p);
            for (hook_runners.items) |h| config.allocator.destroy(h);
            for (sliding_windows.items) |sw| config.allocator.destroy(sw);
            for (strategies.items) |s| config.allocator.destroy(s);
            perm_ctxs.deinit(config.allocator);
            hook_runners.deinit(config.allocator);
            sliding_windows.deinit(config.allocator);
            strategies.deinit(config.allocator);
            var it = members.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit();
            members.deinit();
        }

        for (config.members) |m| {
            const m_perm = try config.allocator.create(perm.PermissionContext);
            m_perm.* = .{};
            try perm_ctxs.append(config.allocator, m_perm);

            const m_hooks = try config.allocator.create(hook_mod.HookRunner);
            m_hooks.* = hook_mod.HookRunner.init(config.allocator);
            try hook_runners.append(config.allocator, m_hooks);

            const m_sw = try config.allocator.create(context_mod.SlidingWindowStrategy);
            m_sw.* = context_mod.SlidingWindowStrategy.init(20);
            try sliding_windows.append(config.allocator, m_sw);

            const m_strat = try config.allocator.create(context_mod.ContextStrategy);
            m_strat.* = m_sw.strategy();
            try strategies.append(config.allocator, m_strat);

            try members.put(m.id, query_engine_mod.QueryEngine.init(.{
                .allocator = config.allocator,
                .provider = m.provider,
                .tools = m.tools,
                .permission_ctx = m_perm,
                .hook_runner = m_hooks,
                .context_strategy = m_strat,
                .system_prompt = m.system_prompt,
                .max_turns = m.max_turns,
                .max_output_tokens = m.max_output_tokens,
            }));
        }

        // Lead engine resources
        const l_perm = try config.allocator.create(perm.PermissionContext);
        l_perm.* = .{};
        try perm_ctxs.append(config.allocator, l_perm);

        const l_hooks = try config.allocator.create(hook_mod.HookRunner);
        l_hooks.* = hook_mod.HookRunner.init(config.allocator);
        try hook_runners.append(config.allocator, l_hooks);

        const l_sw = try config.allocator.create(context_mod.SlidingWindowStrategy);
        l_sw.* = context_mod.SlidingWindowStrategy.init(20);
        try sliding_windows.append(config.allocator, l_sw);

        const l_strat = try config.allocator.create(context_mod.ContextStrategy);
        l_strat.* = l_sw.strategy();
        try strategies.append(config.allocator, l_strat);

        return .{
            .allocator = config.allocator,
            .lead = query_engine_mod.QueryEngine.init(.{
                .allocator = config.allocator,
                .provider = config.lead_provider,
                .tools = config.lead_tools,
                .permission_ctx = l_perm,
                .hook_runner = l_hooks,
                .context_strategy = l_strat,
                .system_prompt = config.lead_system_prompt,
                .max_turns = config.lead_max_turns,
                .max_output_tokens = config.lead_max_output_tokens,
            }),
            .members = members,
            .abort = .{},
            .perm_ctxs = perm_ctxs,
            .hook_runners = hook_runners,
            .sliding_windows = sliding_windows,
            .strategies = strategies,
        };
    }

    /// Run the team with a prompt. Returns the lead engine's event iterator.
    pub fn run(self: *Team, prompt: []const u8) streaming.EventIterator {
        return self.lead.submitMessage(prompt);
    }

    /// Resolve an external tool result on the lead engine.
    pub fn resolveTeamToolResult(self: *Team, tool_use_id: []const u8, result_json: []const u8) void {
        self.lead.resolveToolResult(tool_use_id, result_json);
    }

    /// Abort all engines (lead + members).
    pub fn abortTeam(self: *Team) void {
        self.abort.abort(null);
        self.lead.abortQuery(null);
        var it = self.members.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.abortQuery(null);
        }
    }

    /// Seed messages on the lead engine.
    pub fn seedMessages(self: *Team, messages_json: []const u8) !void {
        try self.lead.seedMessages(messages_json);
    }

    /// Look up a member engine by id.
    pub fn getMember(self: *Team, member_id: []const u8) ?*query_engine_mod.QueryEngine {
        return self.members.getPtr(member_id);
    }

    /// Add a member to the team. Must be called before run().
    pub fn addMember(self: *Team, config: TeamMemberConfig) !void {
        const m_perm = try self.allocator.create(perm.PermissionContext);
        m_perm.* = .{};
        try self.perm_ctxs.append(self.allocator, m_perm);

        const m_hooks = try self.allocator.create(hook_mod.HookRunner);
        m_hooks.* = hook_mod.HookRunner.init(self.allocator);
        try self.hook_runners.append(self.allocator, m_hooks);

        const m_sw = try self.allocator.create(context_mod.SlidingWindowStrategy);
        m_sw.* = context_mod.SlidingWindowStrategy.init(20);
        try self.sliding_windows.append(self.allocator, m_sw);

        const m_strat = try self.allocator.create(context_mod.ContextStrategy);
        m_strat.* = m_sw.strategy();
        try self.strategies.append(self.allocator, m_strat);

        try self.members.put(config.id, query_engine_mod.QueryEngine.init(.{
            .allocator = self.allocator,
            .provider = config.provider,
            .tools = config.tools,
            .permission_ctx = m_perm,
            .hook_runner = m_hooks,
            .context_strategy = m_strat,
            .system_prompt = config.system_prompt,
            .max_turns = config.max_turns,
            .max_output_tokens = config.max_output_tokens,
        }));
    }

    /// Register the "delegate" tool schema in the leader's tool registry.
    /// Call after all members have been added, before run().
    /// This lets the leader LLM call delegate({member_id, task}) to dispatch work.
    pub fn registerDelegateTool(self: *Team) !void {
        const schema_json =
            \\{"type":"object","properties":{"member_id":{"type":"string","description":"ID of the team member to delegate to"},"task":{"type":"string","description":"Task description for the member"}},"required":["member_id","task"]}
        ;
        // Parse schema JSON
        const parsed = try json_mod.parse(self.allocator, schema_json);
        // Register as schema-only (external) tool — JS will handle execution
        try self.lead.config.tools.registerSchema(.{
            .name = "delegate",
            .description = "Delegate a task to a team member",
            .input_schema = parsed.value,
        });
    }

    /// Return the number of registered members.
    pub fn memberCount(self: *const Team) usize {
        return self.members.count();
    }

    pub fn deinit(self: *Team) void {
        self.lead.deinit();
        var it = self.members.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.members.deinit();
        // Destroy owned heap resources: deinit HookRunners, then free all pointers.
        for (self.hook_runners.items) |h| h.deinit();
        for (self.perm_ctxs.items) |p| self.allocator.destroy(p);
        for (self.hook_runners.items) |h| self.allocator.destroy(h);
        for (self.sliding_windows.items) |sw| self.allocator.destroy(sw);
        for (self.strategies.items) |s| self.allocator.destroy(s);
        self.perm_ctxs.deinit(self.allocator);
        self.hook_runners.deinit(self.allocator);
        self.sliding_windows.deinit(self.allocator);
        self.strategies.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Team init and deinit" {
    const allocator = std.testing.allocator;
    var lead_reg = tools_reg.ToolRegistry.init(allocator);
    defer lead_reg.deinit();

    // Provider pointers are undefined since we won't stream in this test.
    var team_inst = try Team.init(.{
        .allocator = allocator,
        .lead_provider = undefined,
        .lead_tools = &lead_reg,
        .lead_system_prompt = "You are the leader.",
        .members = &.{},
    });
    defer team_inst.deinit();

    try std.testing.expectEqual(@as(usize, 0), team_inst.memberCount());
    try std.testing.expect(!team_inst.abort.isAborted());
}

test "Team abort sets flag on all engines" {
    const allocator = std.testing.allocator;
    var lead_reg = tools_reg.ToolRegistry.init(allocator);
    defer lead_reg.deinit();

    var team_inst = try Team.init(.{
        .allocator = allocator,
        .lead_provider = undefined,
        .lead_tools = &lead_reg,
        .members = &.{},
    });
    defer team_inst.deinit();

    team_inst.abortTeam();
    try std.testing.expect(team_inst.abort.isAborted());
}

test "MemberEvent struct defaults" {
    const evt = streaming_events.MemberEvent{
        .member_id = "worker-1",
    };
    try std.testing.expectEqualStrings("worker-1", evt.member_id);
    try std.testing.expectEqual(@as(?[]const u8, null), evt.task);
    try std.testing.expectEqual(@as(?[]const u8, null), evt.result);
}

test "Team addMember and getMember" {
    const allocator = std.testing.allocator;
    var lead_reg = tools_reg.ToolRegistry.init(allocator);
    defer lead_reg.deinit();
    var member_reg = tools_reg.ToolRegistry.init(allocator);
    defer member_reg.deinit();

    var team_inst = try Team.init(.{
        .allocator = allocator,
        .lead_provider = undefined,
        .lead_tools = &lead_reg,
        .members = &.{},
    });
    defer team_inst.deinit();

    try std.testing.expectEqual(@as(usize, 0), team_inst.memberCount());

    try team_inst.addMember(.{
        .id = "worker-1",
        .provider = undefined,
        .tools = &member_reg,
        .system_prompt = "You are worker 1.",
        .max_turns = 10,
    });

    try std.testing.expectEqual(@as(usize, 1), team_inst.memberCount());

    // getMember should find the member
    const member = team_inst.getMember("worker-1");
    try std.testing.expect(member != null);

    // getMember should return null for unknown
    try std.testing.expectEqual(@as(?*query_engine_mod.QueryEngine, null), team_inst.getMember("nonexistent"));
}

test "Team init with members" {
    const allocator = std.testing.allocator;
    var lead_reg = tools_reg.ToolRegistry.init(allocator);
    defer lead_reg.deinit();
    var m1_reg = tools_reg.ToolRegistry.init(allocator);
    defer m1_reg.deinit();
    var m2_reg = tools_reg.ToolRegistry.init(allocator);
    defer m2_reg.deinit();

    const members = [_]TeamMemberConfig{
        .{ .id = "coder", .provider = undefined, .tools = &m1_reg, .system_prompt = "Code things" },
        .{ .id = "reviewer", .provider = undefined, .tools = &m2_reg, .system_prompt = "Review things" },
    };

    var team_inst = try Team.init(.{
        .allocator = allocator,
        .lead_provider = undefined,
        .lead_tools = &lead_reg,
        .members = &members,
    });
    defer team_inst.deinit();

    try std.testing.expectEqual(@as(usize, 2), team_inst.memberCount());
    try std.testing.expect(team_inst.getMember("coder") != null);
    try std.testing.expect(team_inst.getMember("reviewer") != null);
}

test "Team registerDelegateTool adds schema" {
    // Use an arena because registerDelegateTool intentionally keeps parsed JSON
    // alive (ToolSchema references it), which leaks under std.testing.allocator.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var lead_reg = tools_reg.ToolRegistry.init(allocator);
    defer lead_reg.deinit();

    var team_inst = try Team.init(.{
        .allocator = allocator,
        .lead_provider = undefined,
        .lead_tools = &lead_reg,
        .members = &.{},
    });
    defer team_inst.deinit();

    try team_inst.registerDelegateTool();

    // "delegate" should now be known in the lead's tool registry
    try std.testing.expect(lead_reg.isKnown("delegate"));
    try std.testing.expect(lead_reg.isExternal("delegate"));
}
