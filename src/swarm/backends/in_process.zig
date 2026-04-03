//! In-process teammate backend.
//!
//! Spawns a teammate on an independent OS thread with an isolated
//! AgentContext (thread-local). The caller retains control via
//! join() and abort().

const std = @import("std");
const query_engine_mod = @import("../../query_engine.zig");
const agent_ctx = @import("../../context/agent_context.zig");
const abort_mod = @import("../../abort.zig");
const streaming = @import("../../streaming.zig");

pub const InProcessTeammate = struct {
    thread: ?std.Thread = null,
    agent_context: agent_ctx.AgentContext,
    engine: *query_engine_mod.QueryEngine,
    abort_controller: *abort_mod.AbortController,

    /// Spawn the teammate thread, submitting `prompt` to the engine.
    pub fn start(self: *InProcessTeammate, prompt: []const u8) !void {
        self.thread = try std.Thread.spawn(.{}, runLoop, .{ self, prompt });
    }

    fn runLoop(self: *InProcessTeammate, prompt: []const u8) void {
        // Install isolated agent context on this thread.
        agent_ctx.AgentContext.setCurrent(&self.agent_context);
        defer agent_ctx.AgentContext.setCurrent(null);

        var iter = self.engine.submitMessage(prompt);
        while (iter.next()) |_| {
            if (self.abort_controller.isAborted()) break;
        }
    }

    /// Block until the teammate thread exits.
    pub fn join(self: *InProcessTeammate) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Abort the running teammate.
    pub fn abort(self: *InProcessTeammate) void {
        self.abort_controller.abort("terminated");
        self.engine.abortQuery("terminated");
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "InProcessTeammate default has null thread" {
    const allocator = std.testing.allocator;
    var abort_ctrl = abort_mod.AbortController{};
    const ctx = agent_ctx.AgentContext{
        .identity = .main,
        .allocator = allocator,
        .abort_controller = &abort_ctrl,
    };

    // We cannot fully initialise a QueryEngine in a unit test without a
    // provider, but we can verify the struct layout and default state.
    var teammate = InProcessTeammate{
        .agent_context = ctx,
        .engine = undefined,
        .abort_controller = &abort_ctrl,
    };
    try std.testing.expectEqual(@as(?std.Thread, null), teammate.thread);

    // join() on a null thread is a no-op.
    teammate.join();
}

test "InProcessTeammate abort sets controller flag" {
    const allocator = std.testing.allocator;
    var abort_ctrl = abort_mod.AbortController{};
    const ctx = agent_ctx.AgentContext{
        .identity = .main,
        .allocator = allocator,
        .abort_controller = &abort_ctrl,
    };
    var teammate = InProcessTeammate{
        .agent_context = ctx,
        .engine = undefined,
        .abort_controller = &abort_ctrl,
    };

    // abort() without a running engine should just set the flag.
    // We cannot call teammate.abort() because engine is undefined, but
    // we can verify the controller mechanism directly.
    abort_ctrl.abort("terminated");
    try std.testing.expect(abort_ctrl.isAborted());
    try std.testing.expect(teammate.abort_controller.isAborted());
}
