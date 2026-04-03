// src/query_engine.zig
const std = @import("std");
const message_mod = @import("message.zig");
const tool_mod = @import("tool.zig");
const perm = @import("permission.zig");
const streaming = @import("streaming.zig");
const providers_types = @import("providers/types.zig");
const session_mod = @import("session.zig");
const hook_mod = @import("hook.zig");
const abort_mod = @import("abort.zig");
const context_mod = @import("context.zig");
const file_cache_mod = @import("file_cache.zig");
const tools_reg = @import("tools/registry.zig");
const query_mod = @import("query.zig");

pub const QueryEngine = struct {
    config: Config,
    messages: message_mod.MessageStore,
    session: session_mod.Session,
    file_cache: file_cache_mod.FileStateCache,
    abort: abort_mod.AbortController,
    allocator: std.mem.Allocator,
    /// Heap-allocated current query loop (null when idle).
    current_loop: ?*query_mod.QueryLoopIterator = null,

    pub const Config = struct {
        allocator: std.mem.Allocator,
        cwd: []const u8 = ".",
        provider: *providers_types.Provider,
        tools: *tools_reg.ToolRegistry,
        permission_ctx: *perm.PermissionContext,
        hook_runner: *hook_mod.HookRunner,
        context_strategy: *context_mod.ContextStrategy,
        system_prompt: ?[]const u8 = null,
        max_turns: u32 = 50,
        max_budget_usd: ?f64 = null,
        session_path: ?[]const u8 = null,
    };

    pub fn init(config: Config) QueryEngine {
        var session = session_mod.Session.init(config.allocator);
        if (config.session_path) |p| session.setPath(p);

        return .{
            .config = config,
            .messages = message_mod.MessageStore.init(config.allocator),
            .session = session,
            .file_cache = file_cache_mod.FileStateCache.init(config.allocator, 100, 25 * 1024 * 1024),
            .abort = .{},
            .allocator = config.allocator,
        };
    }

    pub fn deinit(self: *QueryEngine) void {
        self.freeCurrentLoop();
        self.messages.deinit();
        self.session.deinit();
        self.file_cache.deinit();
    }

    fn freeCurrentLoop(self: *QueryEngine) void {
        if (self.current_loop) |loop| {
            if (loop.tool_exec) |*exec| exec.deinit();
            self.allocator.destroy(loop);
            self.current_loop = null;
        }
    }

    /// Submit a user message and get back an event iterator.
    /// The iterator drives the agentic loop: streaming, tool dispatch, recovery.
    pub fn submitMessage(self: *QueryEngine, prompt: []const u8) streaming.EventIterator {
        // Free any previous loop before starting a new one.
        self.freeCurrentLoop();

        const user_msg = message_mod.Message{ .user = .{
            .header = message_mod.Header.init(),
            .content = &.{.{ .text = prompt }},
        } };
        self.messages.append(user_msg) catch {};
        self.session.record("{\"type\":\"user\"}") catch {};

        // Heap-allocate the loop so its pointer remains valid after this function returns.
        const loop = self.allocator.create(query_mod.QueryLoopIterator) catch @panic("OOM");
        loop.* = query_mod.queryLoop(.{
            .allocator = self.allocator,
            .provider = self.config.provider,
            .tool_registry = self.config.tools,
            .permission_ctx = self.config.permission_ctx,
            .hook_runner = self.config.hook_runner,
            .session = &self.session,
            .abort = &self.abort,
            .context_strategy = self.config.context_strategy,
            .file_cache = &self.file_cache,
            .system_prompt = self.config.system_prompt,
            .max_turns = self.config.max_turns,
            .max_budget_usd = self.config.max_budget_usd,
        }, &self.messages);
        self.current_loop = loop;

        return loop.toEventIterator();
    }

    /// Abort the current query.
    pub fn abortQuery(self: *QueryEngine, reason: ?[]const u8) void {
        self.abort.abort(reason);
    }

    /// Number of messages in the conversation.
    pub fn messageCount(self: *const QueryEngine) usize {
        return self.messages.count();
    }
};

test "QueryEngine init and deinit" {
    const allocator = std.testing.allocator;
    var perm_ctx = perm.PermissionContext{};
    var hooks = hook_mod.HookRunner.init(allocator);
    defer hooks.deinit();
    var reg = tools_reg.ToolRegistry.init(allocator);
    defer reg.deinit();
    var sw = context_mod.SlidingWindowStrategy.init(20);
    var strategy = sw.strategy();

    var engine = QueryEngine.init(.{
        .allocator = allocator,
        .provider = undefined,
        .tools = &reg,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hooks,
        .context_strategy = &strategy,
        .system_prompt = "You are a test agent.",
    });
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.messageCount());
}
