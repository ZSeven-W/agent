//! Swarm coordinator — top-level multi-agent coordination.
//! Ties together team, mailbox, backend registry, and task manager.

const std = @import("std");
const mailbox_mod = @import("mailbox.zig");
const registry_mod = @import("backends/registry.zig");
const task_mod = @import("../task.zig");
const abort_mod = @import("../abort.zig");

pub const SwarmConfig = struct {
    team_name: []const u8,
    allocator: std.mem.Allocator,
};

pub const Swarm = struct {
    team_name: []const u8,
    allocator: std.mem.Allocator,
    mailbox: mailbox_mod.Mailbox,
    backend_registry: registry_mod.BackendRegistry,
    task_manager: task_mod.TaskManager,
    abort: abort_mod.AbortController,

    pub fn init(config: SwarmConfig) !Swarm {
        return .{
            .team_name = config.team_name,
            .allocator = config.allocator,
            .mailbox = try mailbox_mod.Mailbox.init(config.allocator, config.team_name),
            .backend_registry = .{},
            .task_manager = task_mod.TaskManager.init(config.allocator),
            .abort = .{},
        };
    }

    /// Alternative constructor using an explicit mailbox path (for testing).
    pub fn initWithMailboxPath(config: SwarmConfig, mailbox_path: []const u8) !Swarm {
        return .{
            .team_name = config.team_name,
            .allocator = config.allocator,
            .mailbox = try mailbox_mod.Mailbox.initWithPath(config.allocator, mailbox_path),
            .backend_registry = .{},
            .task_manager = task_mod.TaskManager.init(config.allocator),
            .abort = .{},
        };
    }

    pub fn deinit(self: *Swarm) void {
        self.task_manager.deinit();
        self.mailbox.deinit();
    }

    pub fn sendMessage(self: *Swarm, to: []const u8, msg: mailbox_mod.TeammateMessage) !void {
        try self.mailbox.send(to, msg);
    }

    pub fn detectBackend(self: *Swarm) registry_mod.BackendType {
        return self.backend_registry.detect();
    }

    pub fn shutdown(self: *Swarm) void {
        self.abort.abort("swarm_shutdown");
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Swarm initWithMailboxPath creates all sub-components" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var s = try Swarm.initWithMailboxPath(.{
        .team_name = "test-team",
        .allocator = allocator,
    }, path);
    defer s.deinit();

    try std.testing.expectEqualStrings("test-team", s.team_name);
    try std.testing.expectEqual(@as(usize, 0), s.task_manager.count());
    try std.testing.expect(!s.abort.isAborted());
}

test "Swarm sendMessage delivers through mailbox" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var s = try Swarm.initWithMailboxPath(.{
        .team_name = "msg-team",
        .allocator = allocator,
    }, path);
    defer s.deinit();

    try s.sendMessage("alice", .{
        .from = "bob",
        .text = "hello from swarm",
        .timestamp = "2026-04-03T00:00:00Z",
    });

    // Verify file was created.
    const file_path = try std.fmt.allocPrint(allocator, "{s}/alice.json", .{path});
    defer allocator.free(file_path);
    const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "hello from swarm") != null);
}

test "Swarm detectBackend returns a valid backend" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var s = try Swarm.initWithMailboxPath(.{
        .team_name = "detect-team",
        .allocator = allocator,
    }, path);
    defer s.deinit();

    const backend = s.detectBackend();
    try std.testing.expect(backend == .in_process or backend == .tmux or backend == .iterm2);
}

test "Swarm shutdown sets abort flag" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var s = try Swarm.initWithMailboxPath(.{
        .team_name = "shutdown-team",
        .allocator = allocator,
    }, path);
    defer s.deinit();

    try std.testing.expect(!s.abort.isAborted());
    s.shutdown();
    try std.testing.expect(s.abort.isAborted());
    try std.testing.expectEqualStrings("swarm_shutdown", s.abort.reason.?);
}

test "Swarm task_manager integration" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var s = try Swarm.initWithMailboxPath(.{
        .team_name = "task-team",
        .allocator = allocator,
    }, path);
    defer s.deinit();

    const task = try s.task_manager.register("agent-1", "do something", "a task");
    try std.testing.expectEqual(task_mod.TaskState.pending, task.state);
    task.activate();
    try std.testing.expectEqual(task_mod.TaskState.active, task.state);
    try std.testing.expectEqual(@as(usize, 1), s.task_manager.count());
}
