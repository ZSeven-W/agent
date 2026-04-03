//! Background agent task lifecycle management.
//! Tracks registered tasks with state machine: pending → active → completed/failed/killed.

const std = @import("std");
const uuid_mod = @import("uuid.zig");

pub const TaskState = enum { pending, active, completed, failed, killed };

pub const AgentTask = struct {
    id: [36]u8,
    agent_id: []const u8,
    prompt: []const u8,
    description: []const u8,
    state: TaskState = .pending,
    progress: ?[]const u8 = null,
    created_at: i64,
    completed_at: ?i64 = null,
    error_message: ?[]const u8 = null,

    pub fn activate(self: *AgentTask) void {
        self.state = .active;
    }

    pub fn complete(self: *AgentTask) void {
        self.state = .completed;
        self.completed_at = std.time.milliTimestamp();
    }

    pub fn fail(self: *AgentTask, err: []const u8) void {
        self.state = .failed;
        self.error_message = err;
        self.completed_at = std.time.milliTimestamp();
    }

    pub fn kill(self: *AgentTask) void {
        self.state = .killed;
        self.completed_at = std.time.milliTimestamp();
    }
};

pub const TaskManager = struct {
    tasks: std.AutoHashMap([36]u8, *AgentTask),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TaskManager {
        return .{
            .tasks = std.AutoHashMap([36]u8, *AgentTask).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TaskManager) void {
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.tasks.deinit();
    }

    pub fn register(self: *TaskManager, agent_id: []const u8, prompt: []const u8, description: []const u8) !*AgentTask {
        const task = try self.allocator.create(AgentTask);
        const id = uuid_mod.v4();
        task.* = .{
            .id = id,
            .agent_id = agent_id,
            .prompt = prompt,
            .description = description,
            .created_at = std.time.milliTimestamp(),
        };
        try self.tasks.put(id, task);
        return task;
    }

    pub fn get(self: *const TaskManager, task_id: [36]u8) ?*AgentTask {
        return self.tasks.get(task_id);
    }

    pub fn count(self: *const TaskManager) usize {
        return self.tasks.count();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TaskManager register creates a pending task" {
    const allocator = std.testing.allocator;
    var tm = TaskManager.init(allocator);
    defer tm.deinit();

    const task = try tm.register("agent-1", "write tests", "Write unit tests for task.zig");
    try std.testing.expectEqual(TaskState.pending, task.state);
    try std.testing.expectEqualStrings("agent-1", task.agent_id);
    try std.testing.expectEqualStrings("write tests", task.prompt);
    try std.testing.expectEqualStrings("Write unit tests for task.zig", task.description);
    try std.testing.expect(task.completed_at == null);
    try std.testing.expect(task.error_message == null);
}

test "TaskManager register increments count" {
    const allocator = std.testing.allocator;
    var tm = TaskManager.init(allocator);
    defer tm.deinit();

    try std.testing.expectEqual(@as(usize, 0), tm.count());
    _ = try tm.register("a1", "p1", "d1");
    try std.testing.expectEqual(@as(usize, 1), tm.count());
    _ = try tm.register("a2", "p2", "d2");
    try std.testing.expectEqual(@as(usize, 2), tm.count());
}

test "TaskManager get retrieves registered task" {
    const allocator = std.testing.allocator;
    var tm = TaskManager.init(allocator);
    defer tm.deinit();

    const task = try tm.register("agent-1", "prompt", "desc");
    const retrieved = tm.get(task.id);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("agent-1", retrieved.?.agent_id);
}

test "TaskManager get returns null for unknown id" {
    const allocator = std.testing.allocator;
    var tm = TaskManager.init(allocator);
    defer tm.deinit();

    const fake_id: [36]u8 = "00000000-0000-0000-0000-000000000000".*;
    try std.testing.expectEqual(@as(?*AgentTask, null), tm.get(fake_id));
}

test "AgentTask activate transitions to active" {
    const allocator = std.testing.allocator;
    var tm = TaskManager.init(allocator);
    defer tm.deinit();

    const task = try tm.register("agent-1", "prompt", "desc");
    try std.testing.expectEqual(TaskState.pending, task.state);
    task.activate();
    try std.testing.expectEqual(TaskState.active, task.state);
}

test "AgentTask complete transitions to completed with timestamp" {
    const allocator = std.testing.allocator;
    var tm = TaskManager.init(allocator);
    defer tm.deinit();

    const task = try tm.register("agent-1", "prompt", "desc");
    task.activate();
    task.complete();
    try std.testing.expectEqual(TaskState.completed, task.state);
    try std.testing.expect(task.completed_at != null);
}

test "AgentTask fail transitions to failed with error" {
    const allocator = std.testing.allocator;
    var tm = TaskManager.init(allocator);
    defer tm.deinit();

    const task = try tm.register("agent-1", "prompt", "desc");
    task.activate();
    task.fail("out of memory");
    try std.testing.expectEqual(TaskState.failed, task.state);
    try std.testing.expectEqualStrings("out of memory", task.error_message.?);
    try std.testing.expect(task.completed_at != null);
}

test "AgentTask kill transitions to killed with timestamp" {
    const allocator = std.testing.allocator;
    var tm = TaskManager.init(allocator);
    defer tm.deinit();

    const task = try tm.register("agent-1", "prompt", "desc");
    task.activate();
    task.kill();
    try std.testing.expectEqual(TaskState.killed, task.state);
    try std.testing.expect(task.completed_at != null);
}
