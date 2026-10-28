const std = @import("std");
const json = @import("json.zig");
const message = @import("message.zig");
const uuid_mod = @import("uuid.zig");

pub const Session = struct {
    file_path: ?[]const u8 = null,
    pending: std.ArrayList([]const u8),
    skipped_timestamps: std.AutoHashMap(i64, void),
    allocator: std.mem.Allocator,
    last_flush_error: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{
            .pending = .empty,
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

        const io = uuid_mod.defaultIo();
        var attempts: u32 = 0;
        while (attempts < max_retries) : (attempts += 1) {
            const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only }) catch |err| {
                if (err == error.FileNotFound) {
                    if (std.Io.Dir.cwd().createFile(io, path, .{})) |created| {
                        created.close(io);
                    } else |_| {
                        io.sleep(.fromMilliseconds(500), .awake) catch {};
                        continue;
                    }
                    continue;
                }
                io.sleep(.fromMilliseconds(500), .awake) catch {};
                continue;
            };
            defer file.close(io);
            var offset = file.length(io) catch continue;

            for (self.pending.items) |line| {
                file.writePositionalAll(io, line, offset) catch continue;
                offset += line.len;
                file.writePositionalAll(io, "\n", offset) catch continue;
                offset += 1;
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
    const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    const file_path = try std.fmt.allocPrint(allocator, "{s}/test.jsonl", .{path});
    defer allocator.free(file_path);

    // Create the file first
    const f = try std.Io.Dir.createFileAbsolute(std.testing.io, file_path, .{});
    f.close(std.testing.io);

    session.setPath(file_path);
    try session.record("{\"type\":\"user\"}");
    try session.record("{\"type\":\"assistant\"}");
    try session.flush(3);

    try std.testing.expectEqual(@as(usize, 0), session.pendingCount());

    // Verify file contents
    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, file_path, allocator, .limited(1024 * 1024));
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "{\"type\":\"user\"}") != null);
}
