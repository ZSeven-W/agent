//! Cross-agent permission coordination via file-based request/response.
//! Workers create pending requests; leader resolves them.
//! Path: ~/.claude/teams/{team}/permissions/{pending|resolved}/{requestId}.json

const std = @import("std");
const uuid_mod = @import("../uuid.zig");

pub const PermissionRequestStatus = enum { pending, approved, rejected };

pub const PermissionRequest = struct {
    id: []const u8,
    worker_id: []const u8,
    worker_name: []const u8,
    worker_color: ?[]const u8 = null,
    team_name: []const u8,
    tool_name: []const u8,
    tool_use_id: []const u8,
    description: []const u8,
    status: PermissionRequestStatus = .pending,
    created_at: i64,
};

pub const PermissionResponse = struct {
    request_id: []const u8,
    decision: enum { approved, rejected },
    feedback: ?[]const u8 = null,
};

pub const PermissionSync = struct {
    team_name: []const u8,
    base_path: []const u8,
    allocator: std.mem.Allocator,

    /// Initialise a PermissionSync for `team_name`.
    /// Creates `~/.claude/teams/{team}/permissions/{pending,resolved}` if needed.
    pub fn init(allocator: std.mem.Allocator, team_name: []const u8) !PermissionSync {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const base = try std.fmt.allocPrint(allocator, "{s}/.claude/teams/{s}/permissions", .{ home, team_name });
        errdefer allocator.free(base);

        // Ensure directory tree exists using makePath (mirrors mailbox.zig pattern).
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();

        const pending = try std.fmt.allocPrint(allocator, "{s}/pending", .{base});
        defer allocator.free(pending);
        const resolved = try std.fmt.allocPrint(allocator, "{s}/resolved", .{base});
        defer allocator.free(resolved);

        const pending_rel = if (pending.len > 0 and pending[0] == '/') pending[1..] else pending;
        root.makePath(pending_rel) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        const resolved_rel = if (resolved.len > 0 and resolved[0] == '/') resolved[1..] else resolved;
        root.makePath(resolved_rel) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };

        return .{ .team_name = team_name, .base_path = base, .allocator = allocator };
    }

    /// Alternative constructor that uses an explicit base path (for testing).
    pub fn initWithPath(allocator: std.mem.Allocator, base_path: []const u8) !PermissionSync {
        const owned = try allocator.dupe(u8, base_path);
        errdefer allocator.free(owned);

        // Ensure pending/ and resolved/ subdirs exist under the given path.
        const pending = try std.fmt.allocPrint(allocator, "{s}/pending", .{base_path});
        defer allocator.free(pending);
        const resolved = try std.fmt.allocPrint(allocator, "{s}/resolved", .{base_path});
        defer allocator.free(resolved);

        std.fs.makeDirAbsolute(pending) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        std.fs.makeDirAbsolute(resolved) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };

        return .{ .team_name = "", .base_path = owned, .allocator = allocator };
    }

    pub fn deinit(self: *PermissionSync) void {
        self.allocator.free(self.base_path);
    }

    /// Escape a string for inclusion in a JSON string value.
    /// Caller owns the returned slice.
    fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        var extra: usize = 0;
        for (input) |c| {
            switch (c) {
                '"', '\\' => extra += 1,
                '\n' => extra += 1,
                '\r' => extra += 1,
                '\t' => extra += 1,
                else => {},
            }
        }
        const out = try allocator.alloc(u8, input.len + extra);
        var i: usize = 0;
        for (input) |c| {
            switch (c) {
                '"' => {
                    out[i] = '\\';
                    i += 1;
                    out[i] = '"';
                    i += 1;
                },
                '\\' => {
                    out[i] = '\\';
                    i += 1;
                    out[i] = '\\';
                    i += 1;
                },
                '\n' => {
                    out[i] = '\\';
                    i += 1;
                    out[i] = 'n';
                    i += 1;
                },
                '\r' => {
                    out[i] = '\\';
                    i += 1;
                    out[i] = 'r';
                    i += 1;
                },
                '\t' => {
                    out[i] = '\\';
                    i += 1;
                    out[i] = 't';
                    i += 1;
                },
                else => {
                    out[i] = c;
                    i += 1;
                },
            }
        }
        return out;
    }

    /// Write a permission request to pending/.
    pub fn writeRequest(self: *PermissionSync, req: PermissionRequest) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/pending/{s}.json", .{ self.base_path, req.id });
        defer self.allocator.free(path);

        const esc_id = try jsonEscape(self.allocator, req.id);
        defer self.allocator.free(esc_id);
        const esc_worker_id = try jsonEscape(self.allocator, req.worker_id);
        defer self.allocator.free(esc_worker_id);
        const esc_worker_name = try jsonEscape(self.allocator, req.worker_name);
        defer self.allocator.free(esc_worker_name);
        const esc_team_name = try jsonEscape(self.allocator, req.team_name);
        defer self.allocator.free(esc_team_name);
        const esc_tool_name = try jsonEscape(self.allocator, req.tool_name);
        defer self.allocator.free(esc_tool_name);
        const esc_tool_use_id = try jsonEscape(self.allocator, req.tool_use_id);
        defer self.allocator.free(esc_tool_use_id);
        const esc_description = try jsonEscape(self.allocator, req.description);
        defer self.allocator.free(esc_description);

        const content = try std.fmt.allocPrint(self.allocator,
            \\{{"id":"{s}","worker_id":"{s}","worker_name":"{s}","team_name":"{s}","tool_name":"{s}","tool_use_id":"{s}","description":"{s}","status":"pending","created_at":{d}}}
        , .{ esc_id, esc_worker_id, esc_worker_name, esc_team_name, esc_tool_name, esc_tool_use_id, esc_description, req.created_at });
        defer self.allocator.free(content);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    /// Write a permission response to resolved/.
    pub fn writeResponse(self: *PermissionSync, resp: PermissionResponse) !void {
        const decision_str = switch (resp.decision) {
            .approved => "approved",
            .rejected => "rejected",
        };
        const path = try std.fmt.allocPrint(self.allocator, "{s}/resolved/{s}.json", .{ self.base_path, resp.request_id });
        defer self.allocator.free(path);

        const esc_request_id = try jsonEscape(self.allocator, resp.request_id);
        defer self.allocator.free(esc_request_id);

        const content = if (resp.feedback) |fb| blk: {
            const esc_feedback = try jsonEscape(self.allocator, fb);
            defer self.allocator.free(esc_feedback);
            break :blk try std.fmt.allocPrint(self.allocator,
                \\{{"request_id":"{s}","decision":"{s}","feedback":"{s}"}}
            , .{ esc_request_id, decision_str, esc_feedback });
        } else try std.fmt.allocPrint(self.allocator,
            \\{{"request_id":"{s}","decision":"{s}"}}
        , .{ esc_request_id, decision_str });
        defer self.allocator.free(content);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    /// Poll for a response to a specific request.
    /// Returns a PermissionResponse when the resolved file appears, or null on
    /// timeout / abort.
    pub fn pollResponse(
        self: *PermissionSync,
        request_id: []const u8,
        timeout_ms: u64,
        abort: *const std.atomic.Value(bool),
    ) !?PermissionResponse {
        const resolved_path = try std.fmt.allocPrint(self.allocator, "{s}/resolved/{s}.json", .{ self.base_path, request_id });
        defer self.allocator.free(resolved_path);

        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            if (abort.load(.acquire)) return null;

            if (std.fs.openFileAbsolute(resolved_path, .{})) |file| {
                defer file.close();
                // File exists — read and parse the decision.
                const content = file.readToEndAlloc(self.allocator, 64 * 1024) catch {
                    std.Thread.sleep(500 * std.time.ns_per_ms);
                    continue;
                };
                defer self.allocator.free(content);

                // Simple decision parsing — look for "approved" or "rejected".
                const is_approved = std.mem.indexOf(u8, content, "\"approved\"") != null;

                return .{
                    .request_id = request_id,
                    .decision = if (is_approved) .approved else .rejected,
                    .feedback = null,
                };
            } else |_| {}

            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PermissionSync initWithPath creates directory structure" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var sync = try PermissionSync.initWithPath(allocator, path);
    defer sync.deinit();

    try std.testing.expectEqualStrings(path, sync.base_path);

    // Verify pending/ and resolved/ directories exist.
    const pending_path = try std.fmt.allocPrint(allocator, "{s}/pending", .{path});
    defer allocator.free(pending_path);
    const resolved_path = try std.fmt.allocPrint(allocator, "{s}/resolved", .{path});
    defer allocator.free(resolved_path);

    var pending_dir = try std.fs.openDirAbsolute(pending_path, .{});
    pending_dir.close();
    var resolved_dir = try std.fs.openDirAbsolute(resolved_path, .{});
    resolved_dir.close();
}

test "PermissionSync writeRequest creates pending JSON file" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var sync = try PermissionSync.initWithPath(allocator, path);
    defer sync.deinit();

    try sync.writeRequest(.{
        .id = "req-001",
        .worker_id = "worker-abc",
        .worker_name = "alice",
        .team_name = "test-team",
        .tool_name = "bash",
        .tool_use_id = "tu-123",
        .description = "Run ls command",
        .created_at = 1700000000,
    });

    const file_path = try std.fmt.allocPrint(allocator, "{s}/pending/req-001.json", .{path});
    defer allocator.free(file_path);
    const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"id\":\"req-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"worker_id\":\"worker-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"worker_name\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"tool_name\":\"bash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"status\":\"pending\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"created_at\":1700000000") != null);
}

test "PermissionSync writeRequest escapes special characters" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var sync = try PermissionSync.initWithPath(allocator, path);
    defer sync.deinit();

    try sync.writeRequest(.{
        .id = "req-esc",
        .worker_id = "w1",
        .worker_name = "bob",
        .team_name = "team",
        .tool_name = "bash",
        .tool_use_id = "tu-1",
        .description = "echo \"hello\nworld\"",
        .created_at = 0,
    });

    const file_path = try std.fmt.allocPrint(allocator, "{s}/pending/req-esc.json", .{path});
    defer allocator.free(file_path);
    const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(contents);

    // Newline should be escaped.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\n") != null);
    // Quotes should be escaped.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\\"hello") != null);
}

test "PermissionSync writeResponse creates resolved JSON file (approved)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var sync = try PermissionSync.initWithPath(allocator, path);
    defer sync.deinit();

    try sync.writeResponse(.{
        .request_id = "req-001",
        .decision = .approved,
    });

    const file_path = try std.fmt.allocPrint(allocator, "{s}/resolved/req-001.json", .{path});
    defer allocator.free(file_path);
    const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"request_id\":\"req-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"decision\":\"approved\"") != null);
}

test "PermissionSync writeResponse creates resolved JSON file (rejected with feedback)" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var sync = try PermissionSync.initWithPath(allocator, path);
    defer sync.deinit();

    try sync.writeResponse(.{
        .request_id = "req-002",
        .decision = .rejected,
        .feedback = "Not allowed in production",
    });

    const file_path = try std.fmt.allocPrint(allocator, "{s}/resolved/req-002.json", .{path});
    defer allocator.free(file_path);
    const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"decision\":\"rejected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"feedback\":\"Not allowed in production\"") != null);
}

test "PermissionSync pollResponse returns null on timeout" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var sync = try PermissionSync.initWithPath(allocator, path);
    defer sync.deinit();

    var abort_flag = std.atomic.Value(bool).init(false);
    const result = try sync.pollResponse("nonexistent", 50, &abort_flag);
    try std.testing.expectEqual(@as(?PermissionResponse, null), result);
}

test "PermissionSync pollResponse returns null on abort" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var sync = try PermissionSync.initWithPath(allocator, path);
    defer sync.deinit();

    var abort_flag = std.atomic.Value(bool).init(true);
    const result = try sync.pollResponse("any-id", 10_000, &abort_flag);
    try std.testing.expectEqual(@as(?PermissionResponse, null), result);
}

test "PermissionSync pollResponse finds response after writeResponse" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var sync = try PermissionSync.initWithPath(allocator, path);
    defer sync.deinit();

    // Write a response first.
    try sync.writeResponse(.{
        .request_id = "req-poll-test",
        .decision = .approved,
    });

    var abort_flag = std.atomic.Value(bool).init(false);
    const result = try sync.pollResponse("req-poll-test", 100, &abort_flag);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.decision == .approved);
}
