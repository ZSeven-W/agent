// src/hook.zig
const std = @import("std");
const json = @import("json.zig");

pub const JsonValue = json.JsonValue;

// ─── Event Types (25+) ───

pub const HookEventType = enum {
    pre_tool_use,
    post_tool_use,
    post_tool_use_failure,
    permission_request,
    permission_denied,
    user_prompt_submit,
    session_start,
    session_end,
    stop,
    stop_failure,
    subagent_start,
    subagent_stop,
    pre_compact,
    post_compact,
    setup,
    task_created,
    task_completed,
    file_changed,
    cwd_changed,
    config_change,
    worktree_create,
    worktree_remove,
    instructions_loaded,
    notification,
};

// ─── Hook Definition ───

pub const HookType = enum { command, js };

pub const HookDef = struct {
    hook_type: HookType,
    command: ?[]const u8 = null,
    js_source: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    condition: ?[]const u8 = null,
    timeout_ms: u32 = 5000,
};

pub const HookConfig = struct {
    matcher: ?[]const u8 = null, // tool name pattern
    hooks: []const HookDef,
};

// ─── Hook Input/Output ───

pub const HookInput = struct {
    event: HookEventType,
    session_id: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_input: ?JsonValue = null,
    tool_use_id: ?[]const u8 = null,
};

pub const HookOutput = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    decision: ?HookDecision = null,

    pub const HookDecision = struct {
        allow: bool = false,
        deny: bool = false,
        modified_input: ?JsonValue = null,
    };
};

// ─── Exit code semantics ───
// 0 = ok (tool executes normally)
// 2 = block (stderr shown to model, tool blocked)
// other = warn (stderr shown to user, tool executes)

pub fn interpretExitCode(output: HookOutput) enum { ok, block, warn } {
    return switch (output.exit_code) {
        0 => .ok,
        2 => .block,
        else => .warn,
    };
}

// ─── Hook Runner ───

pub const HookRunner = struct {
    configs: std.StringHashMap([]const HookConfig),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HookRunner {
        return .{
            .configs = std.StringHashMap([]const HookConfig).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HookRunner) void {
        self.configs.deinit();
    }

    pub fn registerHooks(self: *HookRunner, event_name: []const u8, configs: []const HookConfig) !void {
        try self.configs.put(event_name, configs);
    }

    /// Execute command hook, return output with exit code.
    pub fn executeCommand(
        self: *HookRunner,
        command: []const u8,
        input_json: []const u8,
        cwd: ?[]const u8,
    ) !HookOutput {
        var child = std.process.Child.init(
            &.{ "/bin/sh", "-c", command },
            self.allocator,
        );
        child.stdin_behavior = .pipe;
        child.stdout_behavior = .pipe;
        child.stderr_behavior = .pipe;
        if (cwd) |c| child.cwd = c;

        try child.spawn();

        // Write input to stdin
        if (child.stdin) |stdin| {
            stdin.writeAll(input_json) catch {};
            stdin.close();
            child.stdin = null;
        }

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const term = try child.wait();

        return .{
            .exit_code = switch (term) {
                .exited => |code| code,
                else => 1,
            },
            .stdout = stdout,
            .stderr = stderr,
        };
    }
};

// ─── Tests ───

test "interpretExitCode semantics" {
    try std.testing.expectEqual(.ok, interpretExitCode(.{ .exit_code = 0, .stdout = "", .stderr = "" }));
    try std.testing.expectEqual(.block, interpretExitCode(.{ .exit_code = 2, .stdout = "", .stderr = "" }));
    try std.testing.expectEqual(.warn, interpretExitCode(.{ .exit_code = 1, .stdout = "", .stderr = "" }));
    try std.testing.expectEqual(.warn, interpretExitCode(.{ .exit_code = 127, .stdout = "", .stderr = "" }));
}

test "HookRunner init/deinit" {
    const allocator = std.testing.allocator;
    var runner = HookRunner.init(allocator);
    defer runner.deinit();
    try std.testing.expectEqual(@as(usize, 0), runner.configs.count());
}

test "HookEventType has all 24 variants" {
    // Ensure enum is complete
    const count = @typeInfo(HookEventType).@"enum".fields.len;
    try std.testing.expectEqual(@as(usize, 24), count);
}
