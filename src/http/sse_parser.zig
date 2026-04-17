// src/http/sse_parser.zig
const std = @import("std");

pub const SseEvent = struct {
    event: ?[]const u8 = null,
    data: []const u8,
    id: ?[]const u8 = null,
};

/// Parses SSE events from a buffer. Call feed() with incoming chunks,
/// then poll next() for parsed events.
pub const SseParser = struct {
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SseParser {
        return .{ .buffer = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *SseParser) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn feed(self: *SseParser, chunk: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, chunk);
    }

    /// Match `name:` or `name: ` at the start of a line and return the value.
    /// Returns null when the line doesn't carry that field. Accepts both
    /// "field:value" (no space) and "field: value" (single space) forms,
    /// per the SSE spec where the leading space after the colon is optional.
    fn parseField(line: []const u8, comptime name: []const u8) ?[]const u8 {
        const prefix = name ++ ":";
        if (!std.mem.startsWith(u8, line, prefix)) return null;
        var rest = line[prefix.len..];
        if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        return rest;
    }

    /// Try to extract next complete SSE event from buffer.
    /// Caller owns ALL returned slices (event, data, id) — free with allocator.
    pub fn next(self: *SseParser) ?SseEvent {
        const buf = self.buffer.items;
        // SSE events are terminated by \n\n
        const end = std.mem.indexOf(u8, buf, "\n\n") orelse return null;
        const raw = buf[0..end];

        var event_type: ?[]const u8 = null;
        var data: std.ArrayList(u8) = .{};
        var id: ?[]const u8 = null;

        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            // Per the SSE spec the single space after the colon is optional.
            // Anthropic's official endpoint emits "event: foo" but Aliyun's
            // /apps/anthropic adapter emits "event:foo" — accept both, else
            // every Aliyun event is silently dropped and the stream looks empty.
            if (parseField(line, "event")) |value| {
                event_type = value;
            } else if (parseField(line, "data")) |value| {
                if (data.items.len > 0) data.appendSlice(self.allocator, "\n") catch {};
                data.appendSlice(self.allocator, value) catch {};
            } else if (parseField(line, "id")) |value| {
                id = value;
            }
        }

        // Dupe event_type and id BEFORE modifying the buffer — they're slices
        // into it and would become dangling pointers after copyForwards.
        const owned_event = if (event_type) |et|
            (self.allocator.dupe(u8, et) catch null)
        else
            null;
        const owned_id = if (id) |i|
            (self.allocator.dupe(u8, i) catch null)
        else
            null;

        // Consume the parsed portion + \n\n
        const remaining = buf[end + 2 ..];
        std.mem.copyForwards(u8, self.buffer.items[0..remaining.len], remaining);
        self.buffer.shrinkRetainingCapacity(remaining.len);

        if (data.items.len == 0) {
            data.deinit(self.allocator);
            if (owned_event) |e| self.allocator.free(e);
            if (owned_id) |i| self.allocator.free(i);
            return null;
        }

        return .{
            .event = owned_event,
            .data = data.toOwnedSlice(self.allocator) catch "",
            .id = owned_id,
        };
    }
};

test "SseParser parses single event" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    try parser.feed("event: message_start\ndata: {\"type\":\"message\"}\n\n");
    const event = parser.next().?;
    defer allocator.free(event.data);
    defer allocator.free(event.event.?);
    try std.testing.expectEqualStrings("message_start", event.event.?);
    try std.testing.expectEqualStrings("{\"type\":\"message\"}", event.data);
}

test "SseParser handles partial chunks" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    try parser.feed("data: hel");
    try std.testing.expectEqual(@as(?SseEvent, null), parser.next());
    try parser.feed("lo\n\n");
    const event = parser.next().?;
    defer allocator.free(event.data);
    try std.testing.expectEqualStrings("hello", event.data);
}

test "SseParser handles multiple events in one chunk" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    try parser.feed("data: first\n\ndata: second\n\n");
    const e1 = parser.next().?;
    defer allocator.free(e1.data);
    try std.testing.expectEqualStrings("first", e1.data);
    const e2 = parser.next().?;
    defer allocator.free(e2.data);
    try std.testing.expectEqualStrings("second", e2.data);
}

test "SseParser parses field lines without a space after the colon (Aliyun adapter format)" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    try parser.feed("event:message_start\ndata:{\"type\":\"message_start\"}\n\n");
    const event = parser.next().?;
    defer allocator.free(event.data);
    defer allocator.free(event.event.?);
    try std.testing.expectEqualStrings("message_start", event.event.?);
    try std.testing.expectEqualStrings("{\"type\":\"message_start\"}", event.data);
}

test "SseParser tolerates a mix of spaced and unspaced field lines in one event" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    try parser.feed("event:content_block_delta\ndata: {\"delta\":\"hi\"}\n\n");
    const event = parser.next().?;
    defer allocator.free(event.data);
    defer allocator.free(event.event.?);
    try std.testing.expectEqualStrings("content_block_delta", event.event.?);
    try std.testing.expectEqualStrings("{\"delta\":\"hi\"}", event.data);
}
