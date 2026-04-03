//! File-based mailbox for teammate messaging.
//!
//! Path: ~/.claude/teams/{team}/inboxes/{agent}.json
//! Atomic read-modify-write with lockfile.
//! Matches Claude Code's teammateMailbox.ts.

const std = @import("std");

pub const TeammateMessage = struct {
    from: []const u8,
    text: []const u8,
    timestamp: []const u8,
    read: bool = false,
    color: ?[]const u8 = null,
    summary: ?[]const u8 = null,
};

pub const Mailbox = struct {
    base_path: []const u8,
    allocator: std.mem.Allocator,

    /// Initialise a mailbox for `team_name`.
    /// Creates the directory tree `~/.claude/teams/{team}/inboxes` if it
    /// does not already exist.
    pub fn init(allocator: std.mem.Allocator, team_name: []const u8) !Mailbox {
        const home = std.posix.getenv("HOME") orelse "/tmp";
        const base = try std.fmt.allocPrint(allocator, "{s}/.claude/teams/{s}/inboxes", .{ home, team_name });
        errdefer allocator.free(base);

        // Ensure directory tree exists — open root and recursively create the
        // relative sub-path.  This mirrors `mkdir -p` without needing to
        // manually create each component.
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        // base starts with "/" — strip the leading slash so makePath gets a
        // relative path under root.
        const rel = if (base.len > 0 and base[0] == '/') base[1..] else base;
        root.makePath(rel) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };

        return .{ .base_path = base, .allocator = allocator };
    }

    /// Alternative constructor that uses an explicit base path (for testing).
    pub fn initWithPath(allocator: std.mem.Allocator, base_path: []const u8) !Mailbox {
        const owned = try allocator.dupe(u8, base_path);
        return .{ .base_path = owned, .allocator = allocator };
    }

    pub fn deinit(self: *Mailbox) void {
        self.allocator.free(self.base_path);
    }

    fn inboxPath(self: *const Mailbox, agent_name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.base_path, agent_name });
    }

    fn lockPath(self: *const Mailbox, agent_name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}.json.lock", .{ self.base_path, agent_name });
    }

    /// Escape a string for inclusion in a JSON string value.
    /// Caller owns the returned slice.
    fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
        // Count how many extra bytes we need.
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

    /// Send a message to an agent's inbox.
    /// Uses a lockfile for atomic read-modify-write.
    pub fn send(self: *Mailbox, recipient: []const u8, msg: TeammateMessage) !void {
        const path = try self.inboxPath(recipient);
        defer self.allocator.free(path);
        const lock = try self.lockPath(recipient);
        defer self.allocator.free(lock);

        // Acquire lock (simple file-based advisory lock).
        var retries: u32 = 0;
        var lock_file: ?std.fs.File = null;
        while (retries < 10) : (retries += 1) {
            lock_file = std.fs.createFileAbsolute(lock, .{ .exclusive = true }) catch |e| switch (e) {
                error.PathAlreadyExists => {
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
                else => return e,
            };
            break;
        }
        if (lock_file == null) return error.LockTimeout;
        lock_file.?.close();
        defer std.fs.deleteFileAbsolute(lock) catch {};

        // Read existing content.
        var existing_content: []u8 = &.{};
        if (std.fs.openFileAbsolute(path, .{})) |file| {
            defer file.close();
            existing_content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch &.{};
        } else |_| {}
        defer if (existing_content.len > 0) self.allocator.free(existing_content);

        // Escape text values for safe JSON embedding.
        const esc_from = try jsonEscape(self.allocator, msg.from);
        defer self.allocator.free(esc_from);
        const esc_text = try jsonEscape(self.allocator, msg.text);
        defer self.allocator.free(esc_text);
        const esc_ts = try jsonEscape(self.allocator, msg.timestamp);
        defer self.allocator.free(esc_ts);

        // Build the new message JSON object.
        const msg_json = try std.fmt.allocPrint(
            self.allocator,
            \\{{"from":"{s}","text":"{s}","timestamp":"{s}","read":false}}
        ,
            .{ esc_from, esc_text, esc_ts },
        );
        defer self.allocator.free(msg_json);

        // Append to existing array or create new.
        var output: []u8 = undefined;
        if (existing_content.len > 2) {
            // Existing array — insert before closing ']'.
            var last_bracket: usize = existing_content.len;
            while (last_bracket > 0) {
                last_bracket -= 1;
                if (existing_content[last_bracket] == ']') break;
            }
            if (last_bracket > 1) {
                output = try std.fmt.allocPrint(self.allocator, "{s},{s}]", .{
                    existing_content[0..last_bracket],
                    msg_json,
                });
            } else {
                output = try std.fmt.allocPrint(self.allocator, "[{s}]", .{msg_json});
            }
        } else {
            output = try std.fmt.allocPrint(self.allocator, "[{s}]", .{msg_json});
        }
        defer self.allocator.free(output);

        // Write back atomically.
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(output);
    }

    /// Poll for messages with timeout. Returns first unread message or null.
    pub fn poll(
        self: *Mailbox,
        agent_name: []const u8,
        timeout_ms: u64,
        abort: *const std.atomic.Value(bool),
    ) !?TeammateMessage {
        const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (std.time.milliTimestamp() < deadline) {
            if (abort.load(.acquire)) return null;

            // Check for inbox file.
            const path = try self.inboxPath(agent_name);
            defer self.allocator.free(path);

            if (std.fs.openFileAbsolute(path, .{})) |file| {
                defer file.close();
                const stat = try file.stat();
                if (stat.size > 2) {
                    // Has content — return a simple indication.
                    // Full JSON parsing would be done by the caller.
                    return TeammateMessage{
                        .from = "system",
                        .text = "new_messages",
                        .timestamp = "0",
                        .read = false,
                    };
                }
            } else |_| {}

            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Mailbox initWithPath creates mailbox struct" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var mbox = try Mailbox.initWithPath(allocator, path);
    defer mbox.deinit();

    try std.testing.expectEqualStrings(path, mbox.base_path);
}

test "Mailbox send creates inbox file with JSON array" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var mbox = try Mailbox.initWithPath(allocator, path);
    defer mbox.deinit();

    try mbox.send("alice", .{
        .from = "bob",
        .text = "hello",
        .timestamp = "2026-04-03T00:00:00Z",
    });

    // Read the file back and verify it contains expected JSON.
    const file_path = try std.fmt.allocPrint(allocator, "{s}/alice.json", .{path});
    defer allocator.free(file_path);
    const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"from\":\"bob\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"text\":\"hello\"") != null);
    try std.testing.expect(contents[0] == '[');
    try std.testing.expect(contents[contents.len - 1] == ']');
}

test "Mailbox send appends to existing inbox" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var mbox = try Mailbox.initWithPath(allocator, path);
    defer mbox.deinit();

    try mbox.send("carol", .{
        .from = "dave",
        .text = "first",
        .timestamp = "1",
    });
    try mbox.send("carol", .{
        .from = "eve",
        .text = "second",
        .timestamp = "2",
    });

    const file_path = try std.fmt.allocPrint(allocator, "{s}/carol.json", .{path});
    defer allocator.free(file_path);
    const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(contents);

    // Should contain both messages.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"text\":\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"text\":\"second\"") != null);
    // Should still be a valid-looking array.
    try std.testing.expect(contents[0] == '[');
    try std.testing.expect(contents[contents.len - 1] == ']');
}

test "Mailbox send escapes special characters" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var mbox = try Mailbox.initWithPath(allocator, path);
    defer mbox.deinit();

    try mbox.send("frank", .{
        .from = "grace",
        .text = "line1\nline2\ttab\"quote",
        .timestamp = "1",
    });

    const file_path = try std.fmt.allocPrint(allocator, "{s}/frank.json", .{path});
    defer allocator.free(file_path);
    const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(contents);

    // The newline should be escaped as \n, not literal.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\\"") != null);
}

test "Mailbox poll returns null on empty inbox" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var mbox = try Mailbox.initWithPath(allocator, path);
    defer mbox.deinit();

    var abort_flag = std.atomic.Value(bool).init(false);
    // Very short timeout — should return null quickly.
    const result = try mbox.poll("nobody", 50, &abort_flag);
    try std.testing.expectEqual(@as(?TeammateMessage, null), result);
}

test "Mailbox poll returns null on abort" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var mbox = try Mailbox.initWithPath(allocator, path);
    defer mbox.deinit();

    var abort_flag = std.atomic.Value(bool).init(true);
    const result = try mbox.poll("anyone", 10_000, &abort_flag);
    try std.testing.expectEqual(@as(?TeammateMessage, null), result);
}

test "Mailbox poll finds messages after send" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    var mbox = try Mailbox.initWithPath(allocator, path);
    defer mbox.deinit();

    // Send a message first, then poll.
    try mbox.send("hal", .{
        .from = "ivy",
        .text = "are you there?",
        .timestamp = "1",
    });

    var abort_flag = std.atomic.Value(bool).init(false);
    const result = try mbox.poll("hal", 100, &abort_flag);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("new_messages", result.?.text);
}

test "jsonEscape handles special chars" {
    const allocator = std.testing.allocator;
    const escaped = try Mailbox.jsonEscape(allocator, "a\"b\\c\nd\re\tf");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd\\re\\tf", escaped);
}

test "jsonEscape handles plain string" {
    const allocator = std.testing.allocator;
    const escaped = try Mailbox.jsonEscape(allocator, "hello world");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("hello world", escaped);
}
