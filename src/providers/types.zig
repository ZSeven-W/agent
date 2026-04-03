// src/providers/types.zig
const std = @import("std");
const json_mod = @import("../json.zig");
const message_mod = @import("../message.zig");
const streaming_events = @import("../streaming/events.zig");

pub const JsonValue = json_mod.JsonValue;
pub const StreamDelta = streaming_events.StreamDelta;

pub const StreamConfig = struct {
    max_tokens: u32 = 8192,
    system_prompt: ?[]const u8 = null,
    temperature: ?f32 = null,
    thinking: ?ThinkingConfig = null,
};

pub const ThinkingConfig = struct {
    enabled: bool = false,
    budget_tokens: ?u32 = null,
};

pub const ApiMessage = struct {
    role: []const u8, // "user", "assistant", "system"
    content: JsonValue,
};

pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    input_schema: JsonValue,
};

pub const StreamError = error{
    AuthenticationFailed,
    RateLimited,
    InsufficientCredits,
    InvalidRequest,
    ServerError,
    ConnectionFailed,
    ToolCallingUnsupported,
};

pub const ProviderConfig = struct {
    id: []const u8,
    api_key: ?[]const u8 = null,
    model: []const u8,
    base_url: ?[]const u8 = null,
    max_context_tokens: ?u32 = null,
};

/// Provider interface (VTable pattern).
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        id: []const u8,
        max_context_tokens: u32,
        supports_thinking: bool,
        supports_tool_use: bool,

        /// Start a streaming request to the LLM API.
        stream_text: *const fn (
            *anyopaque,
            messages: []const ApiMessage,
            tools: ?[]const ToolSchema,
            config: StreamConfig,
        ) StreamError!StreamIterator,
    };

    pub fn getId(self: Provider) []const u8 {
        return self.vtable.id;
    }

    pub fn getMaxContextTokens(self: Provider) u32 {
        return self.vtable.max_context_tokens;
    }

    pub fn supportsThinking(self: Provider) bool {
        return self.vtable.supports_thinking;
    }
};

/// Iterates over stream chunks from a provider response.
pub const StreamIterator = struct {
    context: *anyopaque,
    nextFn: *const fn (*anyopaque) ?StreamDelta,

    pub fn next(self: *StreamIterator) ?StreamDelta {
        return self.nextFn(self.context);
    }
};
