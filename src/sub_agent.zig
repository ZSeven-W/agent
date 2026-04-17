//! SubAgent — in-process child agent for single-task execution.
//!
//! Wraps an independent QueryEngine with its own message store,
//! abort controller, and agent context. Equivalent to Claude Code's
//! runAgent() for Agent tool spawns.

const std = @import("std");
const query_engine_mod = @import("query_engine.zig");
const streaming = @import("streaming.zig");
const message_mod = @import("message.zig");
const abort_mod = @import("abort.zig");
const agent_ctx = @import("context/agent_context.zig");
const uuid_mod = @import("uuid.zig");
const providers_types = @import("providers/types.zig");
const tools_reg = @import("tools/registry.zig");
const perm = @import("permission.zig");
const hook_mod = @import("hook.zig");
const context_mod = @import("context.zig");
const file_cache_mod = @import("file_cache.zig");
const session_mod = @import("session.zig");

pub const SubAgentConfig = struct {
    allocator: std.mem.Allocator,
    provider: *providers_types.Provider,
    tools: *tools_reg.ToolRegistry,
    system_prompt: ?[]const u8 = null,
    max_turns: u32 = 50,
    parent_session_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    is_builtin: bool = false,
};

pub const SubAgent = struct {
    /// Heap-allocated UUID string so that slices into it remain stable.
    id_buf: *[36]u8,
    engine: query_engine_mod.QueryEngine,
    context: agent_ctx.AgentContext,
    abort_controller: abort_mod.AbortController,
    allocator: std.mem.Allocator,
    // Owned resources for cleanup
    perm_ctx: *perm.PermissionContext,
    hooks: *hook_mod.HookRunner,
    strategy_ptr: *context_mod.ContextStrategy,
    sw: *context_mod.SlidingWindowStrategy,

    pub fn init(config: SubAgentConfig) !SubAgent {
        const id_buf = try config.allocator.create([36]u8);
        id_buf.* = uuid_mod.v4();

        const perm_ctx = try config.allocator.create(perm.PermissionContext);
        perm_ctx.* = .{};
        const hooks = try config.allocator.create(hook_mod.HookRunner);
        hooks.* = hook_mod.HookRunner.init(config.allocator);
        const sw = try config.allocator.create(context_mod.SlidingWindowStrategy);
        sw.* = context_mod.SlidingWindowStrategy.init(20);
        const strategy_ptr = try config.allocator.create(context_mod.ContextStrategy);
        strategy_ptr.* = sw.strategy();

        var sa = SubAgent{
            .id_buf = id_buf,
            .engine = query_engine_mod.QueryEngine.init(.{
                .allocator = config.allocator,
                .provider = config.provider,
                .tools = config.tools,
                .permission_ctx = perm_ctx,
                .hook_runner = hooks,
                .context_strategy = strategy_ptr,
                .system_prompt = config.system_prompt,
                .max_turns = config.max_turns,
            }),
            .context = .{
                .identity = .{ .subagent = .{
                    .id = id_buf,
                    .name = config.name,
                    .parent_session_id = config.parent_session_id,
                    .is_builtin = config.is_builtin,
                } },
                .allocator = config.allocator,
                .abort_controller = undefined, // fixed below
            },
            .abort_controller = .{},
            .allocator = config.allocator,
            .perm_ctx = perm_ctx,
            .hooks = hooks,
            .strategy_ptr = strategy_ptr,
            .sw = sw,
        };
        // Fix self-referential pointer: context must point to our own abort_controller.
        sa.context.abort_controller = &sa.abort_controller;
        return sa;
    }

    pub fn deinit(self: *SubAgent) void {
        self.engine.deinit();
        self.hooks.deinit();
        self.allocator.destroy(self.perm_ctx);
        self.allocator.destroy(self.hooks);
        self.allocator.destroy(self.strategy_ptr);
        self.allocator.destroy(self.sw);
        self.allocator.destroy(self.id_buf);
    }

    /// Run the subagent with a prompt, returning an event iterator.
    /// Sets thread-local AgentContext for the duration of iteration.
    pub fn run(self: *SubAgent, prompt: []const u8) streaming.EventIterator {
        agent_ctx.AgentContext.setCurrent(&self.context);
        return self.engine.submitMessage(prompt);
    }

    /// Seed prior messages for context inheritance.
    pub fn seedMessages(self: *SubAgent, messages_json: []const u8) !void {
        try self.engine.seedMessages(messages_json);
    }

    /// Abort the subagent.
    pub fn abort(self: *SubAgent) void {
        self.abort_controller.abort(null);
        self.engine.abortQuery(null);
    }

    /// Number of messages in conversation.
    pub fn messageCount(self: *const SubAgent) usize {
        return self.engine.messageCount();
    }
};

test "SubAgent init and deinit" {
    const allocator = std.testing.allocator;
    var reg = tools_reg.ToolRegistry.init(allocator);
    defer reg.deinit();

    var sa = try SubAgent.init(.{
        .allocator = allocator,
        .provider = undefined,
        .tools = &reg,
        .system_prompt = "You are a test subagent.",
        .name = "test-sub",
    });
    defer sa.deinit();

    // Verify identity is subagent
    try std.testing.expect(sa.context.isSubagent());
    try std.testing.expect(!sa.context.isTeammate());

    // Verify message count starts at 0
    try std.testing.expectEqual(@as(usize, 0), sa.messageCount());

    // Verify abort_controller is not aborted initially
    try std.testing.expect(!sa.abort_controller.isAborted());
}

test "SubAgent abort sets flag" {
    const allocator = std.testing.allocator;
    var reg = tools_reg.ToolRegistry.init(allocator);
    defer reg.deinit();

    var sa = try SubAgent.init(.{
        .allocator = allocator,
        .provider = undefined,
        .tools = &reg,
    });
    defer sa.deinit();

    sa.abort();
    try std.testing.expect(sa.abort_controller.isAborted());
}

test "SubAgent context has correct agent id" {
    const allocator = std.testing.allocator;
    var reg = tools_reg.ToolRegistry.init(allocator);
    defer reg.deinit();

    var sa = try SubAgent.init(.{
        .allocator = allocator,
        .provider = undefined,
        .tools = &reg,
        .name = "worker",
        .parent_session_id = "parent-sess-1",
        .is_builtin = true,
    });
    defer sa.deinit();

    // The agent id should be the UUID stored in id_buf
    const agent_id = sa.context.getAgentId().?;
    try std.testing.expectEqual(@as(usize, 36), agent_id.len);
    // Verify it's a valid UUID format
    try std.testing.expectEqual(@as(u8, '-'), agent_id[8]);
    try std.testing.expectEqual(@as(u8, '-'), agent_id[13]);
    try std.testing.expectEqual(@as(u8, '4'), agent_id[14]);
}

test "SubAgent seedMessages adds to engine" {
    const allocator = std.testing.allocator;
    var reg = tools_reg.ToolRegistry.init(allocator);
    defer reg.deinit();

    var sa = try SubAgent.init(.{
        .allocator = allocator,
        .provider = undefined,
        .tools = &reg,
    });
    defer sa.deinit();

    try sa.seedMessages(
        \\[{"role":"user","content":"prior context"},{"role":"assistant","content":"understood"}]
    );
    try std.testing.expectEqual(@as(usize, 2), sa.messageCount());
}
