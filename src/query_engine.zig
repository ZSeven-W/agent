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
const etq_mod = @import("external_tool_queue.zig");
const json_mod = @import("json.zig");

pub const QueryEngine = struct {
    config: Config,
    messages: message_mod.MessageStore,
    session: session_mod.Session,
    file_cache: file_cache_mod.FileStateCache,
    abort: abort_mod.AbortController,
    allocator: std.mem.Allocator,
    external_queue: etq_mod.ExternalToolQueue,
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
        max_output_tokens: u32 = 16_384,
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
            .external_queue = etq_mod.ExternalToolQueue.init(config.allocator),
        };
    }

    pub fn deinit(self: *QueryEngine) void {
        self.freeCurrentLoop();
        self.external_queue.deinit();
        self.messages.deinit();
        self.session.deinit();
        self.file_cache.deinit();
    }

    fn freeCurrentLoop(self: *QueryEngine) void {
        if (self.current_loop) |loop| {
            if (loop.tool_exec) |*exec| exec.deinit();
            loop.text_buf.deinit(self.allocator);
            loop.tool_json_buf.deinit(self.allocator);
            self.allocator.destroy(loop);
            self.current_loop = null;
        }
    }

    /// Submit a user message and get back an event iterator.
    /// The iterator drives the agentic loop: streaming, tool dispatch, recovery.
    pub fn submitMessage(self: *QueryEngine, prompt: []const u8) streaming.EventIterator {
        // Free any previous loop before starting a new one.
        self.freeCurrentLoop();

        // Own every byte that will live in the message store — MessageStore
        // frees its entire arena on deinit, so borrowing `prompt` directly
        // would double-free the caller's memory.
        const msg_alloc = self.messages.allocator();
        const prompt_dupe = msg_alloc.dupe(u8, prompt) catch return streaming.EventIterator{ .context = undefined, .nextFn = undefined };
        const content = msg_alloc.alloc(message_mod.ContentBlock, 1) catch return streaming.EventIterator{ .context = undefined, .nextFn = undefined };
        content[0] = .{ .text = prompt_dupe };
        const user_msg = message_mod.Message{ .user = .{
            .header = message_mod.Header.init(),
            .content = content,
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
            .max_output_tokens = self.config.max_output_tokens,
            .max_budget_usd = self.config.max_budget_usd,
            .external_queue = &self.external_queue,
        }, &self.messages);
        self.current_loop = loop;

        return loop.toEventIterator();
    }

    /// Abort the current query.
    pub fn abortQuery(self: *QueryEngine, reason: ?[]const u8) void {
        self.abort.abort(reason);
    }

    /// Resolve an external tool result (called from JS/NAPI thread).
    pub fn resolveToolResult(self: *QueryEngine, tool_use_id: []const u8, result_json: []const u8) void {
        self.external_queue.push(tool_use_id, result_json, false) catch {};
    }

    /// Push external tool progress (called from JS/NAPI thread).
    pub fn pushToolProgress(self: *QueryEngine, tool_use_id: []const u8, progress_json: []const u8) void {
        _ = self;
        _ = tool_use_id;
        _ = progress_json;
        // TODO: implement progress event injection
    }

    /// Seed the message store with prior conversation history.
    /// `messages_json` is a JSON array of [{role: "user"|"assistant", content: "..."}].
    pub fn seedMessages(self: *QueryEngine, messages_json: []const u8) !void {
        const parsed = try json_mod.parse(self.allocator, messages_json);
        defer parsed.deinit();

        const array = switch (parsed.value) {
            .array => |a| a,
            else => return error.InvalidFormat,
        };

        for (array.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };

            const role_val = obj.get("role") orelse continue;
            const role_str = switch (role_val) {
                .string => |s| s,
                else => continue,
            };
            const content_val = obj.get("content") orelse continue;
            const content_str = switch (content_val) {
                .string => |s| s,
                else => continue,
            };

            // Allocate content slice through the message store's arena so it
            // is freed uniformly with every other stored message.
            const msg_alloc = self.messages.allocator();
            const content_dupe = try msg_alloc.dupe(u8, content_str);
            const content_slice = try msg_alloc.alloc(message_mod.ContentBlock, 1);
            content_slice[0] = .{ .text = content_dupe };

            if (std.mem.eql(u8, role_str, "user")) {
                try self.messages.append(.{ .user = .{
                    .header = message_mod.Header.init(),
                    .content = content_slice,
                } });
            } else if (std.mem.eql(u8, role_str, "assistant")) {
                try self.messages.append(.{ .assistant = .{
                    .header = message_mod.Header.init(),
                    .content = content_slice,
                } });
            }
        }
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

test "QueryEngine seedMessages parses user and assistant" {
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
    });
    defer engine.deinit();

    try engine.seedMessages(
        \\[{"role":"user","content":"hello"},{"role":"assistant","content":"hi there"},{"role":"user","content":"bye"}]
    );
    try std.testing.expectEqual(@as(usize, 3), engine.messageCount());

    // Verify first message is user
    const items = engine.messages.items();
    try std.testing.expectEqualStrings("hello", items[0].user.content[0].text);
    try std.testing.expectEqualStrings("hi there", items[1].assistant.content[0].text);
    try std.testing.expectEqualStrings("bye", items[2].user.content[0].text);
}

test "QueryEngine seedMessages rejects non-array" {
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
    });
    defer engine.deinit();

    try std.testing.expectError(error.InvalidFormat, engine.seedMessages("\"not an array\""));
}

test "QueryEngine seedMessages skips unknown roles" {
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
    });
    defer engine.deinit();

    try engine.seedMessages(
        \\[{"role":"system","content":"ignored"},{"role":"user","content":"kept"}]
    );
    // Only "user" role should be added, "system" is skipped
    try std.testing.expectEqual(@as(usize, 1), engine.messageCount());
}

test "QueryEngine abortQuery sets abort flag" {
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
    });
    defer engine.deinit();

    try std.testing.expect(!engine.abort.isAborted());
    engine.abortQuery("user cancelled");
    try std.testing.expect(engine.abort.isAborted());
}
