// src/tool.zig
const std = @import("std");
const json_mod = @import("json.zig");
const message_mod = @import("message.zig");
const perm = @import("permission.zig");
const file_cache_mod = @import("file_cache.zig");
const hook_mod = @import("hook.zig");
const abort_mod = @import("abort.zig");

pub const JsonValue = json_mod.JsonValue;
pub const JsonSchema = json_mod.JsonSchema;

// ─── Supporting types ───

pub const InterruptBehavior = enum { cancel, block };

pub const ToolCallError = error{
    ToolNotFound,
    InvalidInput,
    ExecutionFailed,
    PermissionDenied,
    Aborted,
    Timeout,
};

pub const ToolResult = struct {
    data: JsonValue,
    new_messages: ?[]message_mod.Message = null,
};

pub const ValidationResult = union(enum) {
    valid: JsonValue,
    invalid: []const u8,
};

pub const RenderBlock = union(enum) {
    text: struct { content: []const u8, style: ?[]const u8 = null },
    code: struct { content: []const u8, language: ?[]const u8 = null },
    diff: struct { old_path: []const u8, new_path: []const u8 },
    file_path: struct { path: []const u8, line: ?u32 = null },
};

pub const RenderOutput = struct {
    blocks: []const RenderBlock,
};

pub const RenderOpts = struct {
    verbose: bool = false,
};

pub const DescriptionOpts = struct {
    is_non_interactive: bool = false,
};

pub const PromptOpts = struct {
    tools: ?[]const Tool = null,
};

pub const SearchReadInfo = struct {
    is_search: bool,
    is_read: bool,
    is_list: bool = false,
};

pub const ProgressCallback = *const fn (JsonValue) void;

pub const CanUseToolFn = *const fn (
    Tool,
    JsonValue,
    *ToolUseContext,
    *const message_mod.AssistantMessage,
    []const u8,
) perm.PermissionDecision;

// ─── ToolUseContext (DI container) ───

pub const ToolUseContext = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    verbose: bool = false,
    debug: bool = false,
    model: []const u8 = "",
    is_non_interactive: bool = false,
    abort_controller: *abort_mod.AbortController,
    file_cache: *file_cache_mod.FileStateCache,
    messages: *message_mod.MessageStore,
    permission_ctx: *perm.PermissionContext,
    hook_runner: *hook_mod.HookRunner,
    agent_id: ?[]const u8 = null,
    agent_type: ?[]const u8 = null,
    tool_use_id: ?[]const u8 = null,
};

// ─── Tool VTable ───

pub const Tool = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Identity
        name: []const u8,
        aliases: []const []const u8 = &.{},
        search_hint: ?[]const u8 = null,
        should_defer: bool = false,
        always_load: bool = false,
        max_result_size_chars: usize = 128 * 1024,

        // Schema
        input_schema: JsonSchema,
        output_schema: ?JsonSchema = null,
        strict: bool = false,

        // Execution
        call: *const fn (*anyopaque, JsonValue, *ToolUseContext) ToolCallError!ToolResult,

        // Lifecycle
        is_enabled: *const fn (*anyopaque) bool,
        is_concurrency_safe: *const fn (*anyopaque, JsonValue) bool,
        is_read_only: *const fn (*anyopaque, JsonValue) bool,
        is_destructive: ?*const fn (*anyopaque, JsonValue) bool = null,
        interrupt_behavior: ?*const fn (*anyopaque) InterruptBehavior = null,

        // Permissions
        check_permissions: *const fn (*anyopaque, JsonValue, *ToolUseContext) perm.PermissionDecision,

        // Description
        description: *const fn (*anyopaque) []const u8,
        user_facing_name: *const fn (*anyopaque) []const u8,
    };

    // ─── Convenience methods ───

    pub fn getName(self: Tool) []const u8 {
        return self.vtable.name;
    }

    pub fn call(self: Tool, args: JsonValue, ctx: *ToolUseContext) ToolCallError!ToolResult {
        return self.vtable.call(self.ptr, args, ctx);
    }

    pub fn isEnabled(self: Tool) bool {
        return self.vtable.is_enabled(self.ptr);
    }

    pub fn isReadOnly(self: Tool, input: JsonValue) bool {
        return self.vtable.is_read_only(self.ptr, input);
    }

    pub fn isConcurrencySafe(self: Tool, input: JsonValue) bool {
        return self.vtable.is_concurrency_safe(self.ptr, input);
    }

    pub fn checkPermissions(self: Tool, input: JsonValue, ctx: *ToolUseContext) perm.PermissionDecision {
        return self.vtable.check_permissions(self.ptr, input, ctx);
    }

    pub fn getDescription(self: Tool) []const u8 {
        return self.vtable.description(self.ptr);
    }
};

// ─── buildTool() comptime helper ───

pub fn buildTool(comptime T: type, impl_ptr: *T) Tool {
    const gen = struct {
        fn callFn(ptr: *anyopaque, args: JsonValue, ctx: *ToolUseContext) ToolCallError!ToolResult {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.call(args, ctx);
        }
        fn isEnabledFn(ptr: *anyopaque) bool {
            const self: *T = @ptrCast(@alignCast(ptr));
            if (comptime @hasDecl(T, "isEnabled")) return self.isEnabled();
            return true;
        }
        fn isConcurrencySafeFn(ptr: *anyopaque, input: JsonValue) bool {
            const self: *T = @ptrCast(@alignCast(ptr));
            if (comptime @hasDecl(T, "isConcurrencySafe")) return self.isConcurrencySafe(input);
            return false;
        }
        fn isReadOnlyFn(ptr: *anyopaque, input: JsonValue) bool {
            const self: *T = @ptrCast(@alignCast(ptr));
            if (comptime @hasDecl(T, "isReadOnly")) return self.isReadOnly(input);
            return false;
        }
        fn checkPermissionsFn(ptr: *anyopaque, _: JsonValue, _: *ToolUseContext) perm.PermissionDecision {
            const self: *T = @ptrCast(@alignCast(ptr));
            if (comptime @hasDecl(T, "checkPermissions")) return self.checkPermissions();
            return .{ .allow = .{ .updated_input = null, .reason = .{ .other = "default allow" } } };
        }
        fn descriptionFn(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return if (comptime @hasDecl(T, "description")) T.description else T.name;
        }
        fn userFacingNameFn(ptr: *anyopaque) []const u8 {
            _ = ptr;
            return T.name;
        }
    };

    return .{
        .ptr = @ptrCast(impl_ptr),
        .vtable = &.{
            .name = T.name,
            .input_schema = if (comptime @hasDecl(T, "input_schema")) T.input_schema else JsonSchema{ .@"type" = "object" },
            .call = gen.callFn,
            .is_enabled = gen.isEnabledFn,
            .is_concurrency_safe = gen.isConcurrencySafeFn,
            .is_read_only = gen.isReadOnlyFn,
            .check_permissions = gen.checkPermissionsFn,
            .description = gen.descriptionFn,
            .user_facing_name = gen.userFacingNameFn,
        },
    };
}

// ─── Tests ───

pub const TestTool = struct {
    call_count: u32 = 0,

    pub const name = "TestTool";
    pub const input_schema = JsonSchema{ .@"type" = "object" };

    pub fn call(self: *TestTool, _: JsonValue, _: *ToolUseContext) ToolCallError!ToolResult {
        self.call_count += 1;
        return .{ .data = .null };
    }

    pub fn isReadOnly(_: *TestTool, _: JsonValue) bool {
        return true;
    }
};

test "buildTool creates valid Tool from struct" {
    var impl = TestTool{};
    const tool = buildTool(TestTool, &impl);

    try std.testing.expectEqualStrings("TestTool", tool.getName());
    try std.testing.expect(tool.isEnabled());
    try std.testing.expect(tool.isReadOnly(.null));
    try std.testing.expect(!tool.isConcurrencySafe(.null));
}

test "Tool.call delegates to implementation" {
    var impl = TestTool{};
    const tool = buildTool(TestTool, &impl);

    // We need a minimal ToolUseContext — for test we can use undefined since TestTool ignores it
    var abort = abort_mod.AbortController{};
    var cache = file_cache_mod.FileStateCache.init(std.testing.allocator, 10, 1024);
    defer cache.deinit();
    var msgs = message_mod.MessageStore.init(std.testing.allocator);
    defer msgs.deinit();
    var perm_ctx = perm.PermissionContext{
        .mode = .default,
        .always_allow_rules = &.{},
        .always_deny_rules = &.{},
        .always_ask_rules = &.{},
        .is_bypass_available = false,
        .is_auto_available = false,
        .should_avoid_prompts = false,
    };
    var hooks = hook_mod.HookRunner.init(std.testing.allocator);
    defer hooks.deinit();

    var ctx = ToolUseContext{
        .allocator = std.testing.allocator,
        .cwd = "/tmp",
        .abort_controller = &abort,
        .file_cache = &cache,
        .messages = &msgs,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hooks,
    };

    const result = try tool.call(.null, &ctx);
    try std.testing.expect(result.data == .null);
    try std.testing.expectEqual(@as(u32, 1), impl.call_count);
}

test "buildTool isConcurrencySafe defaults to false" {
    var impl = TestTool{};
    const tool = buildTool(TestTool, &impl);
    try std.testing.expect(!tool.isConcurrencySafe(.null));
}

test "buildTool checkPermissions defaults to allow" {
    var impl = TestTool{};
    const tool = buildTool(TestTool, &impl);

    var abort = abort_mod.AbortController{};
    var cache = file_cache_mod.FileStateCache.init(std.testing.allocator, 10, 1024);
    defer cache.deinit();
    var msgs = message_mod.MessageStore.init(std.testing.allocator);
    defer msgs.deinit();
    var perm_ctx = perm.PermissionContext{};
    var hooks = hook_mod.HookRunner.init(std.testing.allocator);
    defer hooks.deinit();

    var ctx = ToolUseContext{
        .allocator = std.testing.allocator,
        .cwd = "/tmp",
        .abort_controller = &abort,
        .file_cache = &cache,
        .messages = &msgs,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hooks,
    };

    const decision = tool.checkPermissions(.null, &ctx);
    switch (decision) {
        .allow => |a| {
            try std.testing.expectEqual(@as(?json_mod.JsonValue, null), a.updated_input);
        },
        else => return error.UnexpectedDecision,
    }
}

test "buildTool getDescription falls back to name" {
    var impl = TestTool{};
    const tool = buildTool(TestTool, &impl);
    // TestTool has no `description` decl, so it should fall back to `name`
    try std.testing.expectEqualStrings("TestTool", tool.getDescription());
}

const ConcurrentTool = struct {
    pub const name = "ConcurrentTool";
    pub const description = "A tool that supports concurrency";
    pub const input_schema = JsonSchema{ .@"type" = "object" };

    pub fn call(_: *ConcurrentTool, _: JsonValue, _: *ToolUseContext) ToolCallError!ToolResult {
        return .{ .data = .null };
    }

    pub fn isConcurrencySafe(_: *ConcurrentTool, _: JsonValue) bool {
        return true;
    }
};

test "buildTool respects custom isConcurrencySafe and description" {
    var impl = ConcurrentTool{};
    const tool = buildTool(ConcurrentTool, &impl);
    try std.testing.expect(tool.isConcurrencySafe(.null));
    try std.testing.expectEqualStrings("A tool that supports concurrency", tool.getDescription());
}
