//! Streaming — barrel module re-exporting all streaming event types.

pub const events = @import("streaming/events.zig");
pub const Event = events.Event;
pub const EventIterator = events.EventIterator;
pub const EventBuffer = events.EventBuffer;
pub const tool_executor = @import("streaming/tool_executor.zig");
pub const StreamingToolExecutor = tool_executor.StreamingToolExecutor;
