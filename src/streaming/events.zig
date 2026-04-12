//! Streaming event types — Event union (~12 variants), EventIterator, EventBuffer.
//!
//! Events are the fundamental unit of information emitted by a streaming agent
//! session.  `EventIterator` provides a pull-based interface; `EventBuffer` is
//! a simple ArrayList-backed store useful in tests and batch contexts.

const std = @import("std");
const message = @import("../message.zig");

pub const AssistantMessage = message.AssistantMessage;
pub const UserMessage = message.UserMessage;
pub const JsonValue = message.JsonValue;

// ---------------------------------------------------------------------------
// StreamDelta
// ---------------------------------------------------------------------------

/// The kind of incremental update carried by a `StreamDelta`.
pub const DeltaType = enum {
    text_delta,
    tool_use_delta,
    thinking_delta,
    message_start,
    message_delta,
    message_stop,
    content_block_start,
    content_block_stop,
};

/// A single incremental update from the model's token stream.
pub const StreamDelta = struct {
    type: DeltaType,
    /// Content block index this delta belongs to (0-based).
    index: u32 = 0,
    /// Incremental text for `text_delta` / `thinking_delta`.
    text: ?[]const u8 = null,
    /// Tool-use invocation id for `tool_use_delta`.
    tool_use_id: ?[]const u8 = null,
    /// Tool name for `tool_use_delta` / `content_block_start`.
    tool_name: ?[]const u8 = null,
    /// Partial JSON argument fragment for `tool_use_delta`.
    partial_json: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Supporting event data types
// ---------------------------------------------------------------------------

/// Initial system context sent at the start of a session.
pub const SystemInit = struct {
    /// Registered tool names available in this session.
    tools: []const []const u8,
    /// Model identifier (e.g. "claude-opus-4").
    model: []const u8,
    /// Working directory of the agent process.
    cwd: []const u8,
    /// Active permission mode (e.g. "default", "restricted").
    permission_mode: []const u8,
};

/// Snapshot of high-level session status.
pub const Status = struct {
    /// Human-readable status string, if available.
    status: ?[]const u8 = null,
    /// Current permission mode, if known.
    permission_mode: ?[]const u8 = null,
};

/// Metadata emitted when the context window is compacted.
pub const CompactMeta = struct {
    /// What triggered the compaction.
    trigger: enum { manual, auto },
    /// Token count before compaction.
    pre_tokens: u64,
};

/// Intermediate progress from a running tool invocation.
pub const ToolProgress = struct {
    /// Name of the tool that is executing.
    tool_name: []const u8,
    /// Identifier that pairs this with the originating `ToolUseBlock`.
    tool_use_id: []const u8,
    /// Arbitrary JSON payload emitted by the tool.
    data: JsonValue,
};

/// Data associated with a lifecycle event from a hook.
pub const HookEventData = struct {
    /// Name of the hook that fired (e.g. "pre_tool_use").
    hook_name: []const u8,
    /// Specific event within the hook (e.g. "started", "response").
    event_name: []const u8,
    /// Optional JSON payload.
    data: ?JsonValue = null,
};

/// An external tool invocation that JS must execute and resolve via resolveToolResult.
pub const ToolUseEvent = struct {
    id: []const u8,
    name: []const u8,
    input: JsonValue,
};

/// Event data for team member lifecycle.
pub const MemberEvent = struct {
    member_id: []const u8,
    task: ?[]const u8 = null,
    result: ?[]const u8 = null,
};

/// Rate-limit information returned by the server.
pub const RateLimitInfo = struct {
    /// Whether the request was allowed, allowed with a warning, or rejected.
    status: enum { allowed, allowed_warning, rejected },
    /// Unix timestamp (seconds) when the rate limit resets, if known.
    resets_at: ?i64 = null,
    /// Current utilization fraction in [0, 1], if known.
    utilization: ?f64 = null,
};

/// Final result summary for a completed agent turn.
pub const ResultData = struct {
    /// `true` when the run ended with an unrecovered error.
    is_error: bool,
    /// Subtype tag for the result (e.g. "success", "timeout").
    subtype: []const u8,
    /// Human-readable result text, if available.
    result: ?[]const u8 = null,
    /// Number of conversation turns taken.
    num_turns: u32,
    /// Total cost of the run in USD.
    total_cost_usd: f64,
    /// Wall-clock duration of the run in milliseconds.
    duration_ms: u64,
    /// Non-fatal error messages accumulated during the run, if any.
    errors: ?[]const []const u8 = null,
};

// ---------------------------------------------------------------------------
// Event — top-level tagged union
// ---------------------------------------------------------------------------

/// Every type of event that can be emitted by a streaming agent session.
pub const Event = union(enum) {
    /// Raw streaming delta from the model.
    stream_event: StreamDelta,
    /// A completed assistant turn.
    assistant: AssistantMessage,
    /// A user turn (may be synthetic / harness-injected).
    user: UserMessage,
    /// Initial session context sent once at startup.
    system_init: SystemInit,
    /// High-level session status update.
    status: Status,
    /// Marks a context-compaction boundary.
    compact_boundary: CompactMeta,
    /// Intermediate output from a running tool.
    tool_progress: ToolProgress,
    /// A hook has started executing.
    hook_started: HookEventData,
    /// Intermediate progress from a running hook.
    hook_progress: HookEventData,
    /// A hook has produced its response.
    hook_response: HookEventData,
    /// Final result summary for the turn.
    result: ResultData,
    /// Rate-limit information from the server.
    rate_limit: RateLimitInfo,
    /// An external tool invocation that JS must execute and resolve via resolveToolResult.
    tool_use: ToolUseEvent,
    /// A team member has started working on a delegated task.
    member_start: MemberEvent,
    /// A team member has completed a delegated task.
    member_end: MemberEvent,
};

// ---------------------------------------------------------------------------
// EventIterator — pull-based iterator interface
// ---------------------------------------------------------------------------

/// A type-erased, pull-based iterator over `Event` values.
///
/// Callers drive iteration by repeatedly calling `next()` until it returns
/// `null`.  Concrete implementations supply the `nextFn` function pointer and
/// a `context` pointer that is passed through on every call.
pub const EventIterator = struct {
    context: *anyopaque,
    nextFn: *const fn (*anyopaque) ?Event,

    /// Advance the iterator and return the next event, or `null` when
    /// exhausted.
    pub fn next(self: *EventIterator) ?Event {
        return self.nextFn(self.context);
    }
};

// ---------------------------------------------------------------------------
// EventBuffer — ArrayList-backed store (testing / batch use)
// ---------------------------------------------------------------------------

/// An `ArrayList(Event)` wrapper that can produce an `EventIterator`.
///
/// Primarily intended for use in tests and offline replay scenarios where all
/// events are known up-front and must be replayed in order.
pub const EventBuffer = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator) EventBuffer {
        return .{
            .allocator = allocator,
            .events = .{},
        };
    }

    pub fn deinit(self: *EventBuffer) void {
        self.events.deinit(self.allocator);
    }

    /// Append an event to the buffer.
    pub fn push(self: *EventBuffer, event: Event) !void {
        try self.events.append(self.allocator, event);
    }

    /// State threaded through the type-erased iterator callback.
    const IterState = struct {
        items: []const Event,
        pos: usize,
    };

    fn iterNext(ctx: *anyopaque) ?Event {
        const state: *IterState = @ptrCast(@alignCast(ctx));
        if (state.pos >= state.items.len) return null;
        const ev = state.items[state.pos];
        state.pos += 1;
        return ev;
    }

    /// Return an `EventIterator` that walks the buffer from the beginning.
    ///
    /// The iterator allocates an `IterState` on the heap; it is owned by the
    /// caller and must be freed after iteration is complete via
    /// `allocator.destroy(iter_state_ptr)`.  In practice tests can just let
    /// the testing allocator handle it.
    pub fn iterator(self: *EventBuffer) !struct { iter: EventIterator, state: *IterState } {
        const state = try self.allocator.create(IterState);
        state.* = .{
            .items = self.events.items,
            .pos = 0,
        };
        return .{
            .iter = EventIterator{
                .context = state,
                .nextFn = iterNext,
            },
            .state = state,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "EventBuffer push and iterate" {
    const allocator = std.testing.allocator;

    var buf = EventBuffer.init(allocator);
    defer buf.deinit();

    // Push a Status event.
    try buf.push(Event{ .status = Status{
        .status = "ready",
        .permission_mode = "default",
    } });

    // Push a ResultData event.
    try buf.push(Event{ .result = ResultData{
        .is_error = false,
        .subtype = "success",
        .result = "all good",
        .num_turns = 3,
        .total_cost_usd = 0.0042,
        .duration_ms = 1234,
        .errors = null,
    } });

    const handle = try buf.iterator();
    defer allocator.destroy(handle.state);
    var iter = handle.iter;

    // First event: status
    const ev1 = iter.next();
    try std.testing.expect(ev1 != null);
    switch (ev1.?) {
        .status => |s| {
            try std.testing.expectEqualStrings("ready", s.status.?);
            try std.testing.expectEqualStrings("default", s.permission_mode.?);
        },
        else => return error.UnexpectedEventType,
    }

    // Second event: result
    const ev2 = iter.next();
    try std.testing.expect(ev2 != null);
    switch (ev2.?) {
        .result => |r| {
            try std.testing.expect(!r.is_error);
            try std.testing.expectEqualStrings("success", r.subtype);
            try std.testing.expectEqualStrings("all good", r.result.?);
            try std.testing.expectEqual(@as(u32, 3), r.num_turns);
        },
        else => return error.UnexpectedEventType,
    }

    // Iterator exhausted
    const ev3 = iter.next();
    try std.testing.expectEqual(@as(?Event, null), ev3);
}

test "EventBuffer handles stream_event and tool_progress" {
    const allocator = std.testing.allocator;
    var buf = EventBuffer.init(allocator);
    defer buf.deinit();

    try buf.push(Event{ .stream_event = StreamDelta{
        .@"type" = .text_delta,
        .text = "hello",
    } });
    try buf.push(Event{ .tool_progress = ToolProgress{
        .tool_name = "ReadFile",
        .tool_use_id = "t1",
        .data = .{ .string = "reading..." },
    } });

    const handle = try buf.iterator();
    defer allocator.destroy(handle.state);
    var iter = handle.iter;

    const ev1 = iter.next().?;
    try std.testing.expectEqualStrings("hello", ev1.stream_event.text.?);

    const ev2 = iter.next().?;
    try std.testing.expectEqualStrings("ReadFile", ev2.tool_progress.tool_name);
    try std.testing.expectEqualStrings("t1", ev2.tool_progress.tool_use_id);

    try std.testing.expectEqual(@as(?Event, null), iter.next());
}

test "StreamDelta defaults" {
    const delta = StreamDelta{ .@"type" = .message_start };
    try std.testing.expectEqual(@as(u32, 0), delta.index);
    try std.testing.expectEqual(@as(?[]const u8, null), delta.text);
    try std.testing.expectEqual(@as(?[]const u8, null), delta.tool_use_id);
    try std.testing.expectEqual(@as(?[]const u8, null), delta.tool_name);
    try std.testing.expectEqual(@as(?[]const u8, null), delta.partial_json);
}

test "ResultData struct fields" {
    const rd = ResultData{
        .is_error = false,
        .subtype = "success",
        .result = "all done",
        .num_turns = 5,
        .total_cost_usd = 0.05,
        .duration_ms = 3000,
    };
    try std.testing.expect(!rd.is_error);
    try std.testing.expectEqualStrings("success", rd.subtype);
    try std.testing.expectEqualStrings("all done", rd.result.?);
    try std.testing.expectEqual(@as(u32, 5), rd.num_turns);
    try std.testing.expectEqual(@as(?[]const []const u8, null), rd.errors);
}

test "EventBuffer empty iteration" {
    const allocator = std.testing.allocator;
    var buf = EventBuffer.init(allocator);
    defer buf.deinit();

    const handle = try buf.iterator();
    defer allocator.destroy(handle.state);
    var iter = handle.iter;

    try std.testing.expectEqual(@as(?Event, null), iter.next());
}
