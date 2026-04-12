// src/session.zig
const std = @import("std");
const json = @import("json.zig");
const message = @import("message.zig");

pub const Session = struct {
    file_path: ?[]const u8 = null,
    pending: std.ArrayList([]const u8),
    skipped_timestamps: std.AutoHashMap(i64, void),
    allocator: std.mem.Allocator,
    last_flush_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .pending = .{},
            .skipped_timestamps = std.AutoHashMap(i64, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Session) void {
        self.pending.deinit(self.allocator);
        self.skipped_timestamps.deinit();
    }

    /// Set the transcript file path.
    pub fn setPath(self: *Session, path: []const u8) void {
        self.file_path = path;
    }

    /// Append a message to the pending buffer (serialized as JSON line).
    pub fn record(self: *Session, line: []const u8) !void {
        try self.pending.append(self.allocator, line);
    }

    /// Mark a timestamp to be skipped (for undo).
    pub fn skip(self: *Session, timestamp: i64) !void {
        try self.skipped_timestamps.put(timestamp, {});
    }

    /// Flush pending entries to disk. Retries up to max_retries times.
    pub fn flush(self: *Session, max_retries: u32) !void {
        const path = self.file_path orelse return;
        if (self.pending.items.len == 0) return;

        var attempts: u32 = 0;
        while (attempts < max_retries) : (attempts += 1) {
            const file = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| {
                if (err == error.FileNotFound) {
                    _ = std.fs.cwd().createFile(path, .{}) catch {
                        std.Thread.sleep(500 * std.time.ns_per_ms);
                        continue;
                    };
                    continue;
                }
                std.Thread.sleep(500 * std.time.ns_per_ms);
                continue;
            };
            defer file.close();
            file.seekFromEnd(0) catch continue;

            for (self.pending.items) |line| {
                file.writeAll(line) catch continue;
                file.writeAll("\n") catch continue;
            }
            self.pending.clearRetainingCapacity();
            self.last_flush_error = null;
            return;
        }
        self.last_flush_error = error.FlushFailed;
        return error.FlushFailed;
    }

    /// Number of pending (unflushed) entries.
    pub fn pendingCount(self: *const Session) usize {
        return self.pending.items.len;
    }
};

test "Session record and pendingCount" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator);
    defer session.deinit();

    try session.record("{\"type\":\"user\"}");
    try session.record("{\"type\":\"assistant\"}");
    try std.testing.expectEqual(@as(usize, 2), session.pendingCount());
}

test "Session skip timestamps" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator);
    defer session.deinit();

    try session.skip(12345);
    try std.testing.expect(session.skipped_timestamps.contains(12345));
    try std.testing.expect(!session.skipped_timestamps.contains(99999));
}

test "Session flush no-op without path" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator);
    defer session.deinit();

    try session.record("line1");
    // flush without setPath is a no-op — pending entries remain
    try session.flush(3);
    try std.testing.expectEqual(@as(usize, 1), session.pendingCount());
}

test "Session flush no-op with empty pending" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator);
    defer session.deinit();

    session.setPath("/tmp/nonexistent.jsonl");
    // Nothing recorded — flush should be a no-op
    try session.flush(3);
    try std.testing.expectEqual(@as(usize, 0), session.pendingCount());
}

test "Session setPath updates file path" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), session.file_path);
    session.setPath("/tmp/session.jsonl");
    try std.testing.expectEqualStrings("/tmp/session.jsonl", session.file_path.?);
}

test "Session flush to temp file" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator);
    defer session.deinit();

    // Create temp file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/test.jsonl", .{path});
    defer allocator.free(file_path);

    // Create the file first
    const f = try std.fs.createFileAbsolute(file_path, .{});
    f.close();

    session.setPath(file_path);
    try session.record("{\"type\":\"user\"}");
    try session.record("{\"type\":\"assistant\"}");
    try session.flush(3);

    try std.testing.expectEqual(@as(usize, 0), session.pendingCount());

    // Verify file contents
    const contents = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "{\"type\":\"user\"}") != null);
}
