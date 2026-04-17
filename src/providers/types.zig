// src/providers/types.zig
const std = @import("std");
const json_mod = @import("../json.zig");
const message_mod = @import("../message.zig");
const streaming_events = @import("../streaming/events.zig");

pub const JsonValue = json_mod.JsonValue;
pub const StreamDelta = streaming_events.StreamDelta;

pub const StreamConfig = struct {
    max_tokens: u32 = 16_384,
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
    /// Some Anthropic-compat endpoints (notably MiniMax) reject follow-up
    /// rounds with HTTP 400 when an echoed assistant turn's content is
    /// tool_use-only. When true, `query.zig` inserts a single-space text
    /// block before tool_use blocks to satisfy the validator. The default
    /// is false, but `c_api.zig` auto-enables it via `detectPlaceholderTextQuirk`
    /// when `base_url`/`model` mentions MiniMax; `agent_provider_set_placeholder_text_quirk`
    /// remains available as an explicit override.
    needs_placeholder_text_before_tool_use: bool = false,

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

        /// Optional accessor for the most recent transport-layer error message
        /// (HTTP error body, etc.) captured during stream_text. The returned
        /// slice is owned by the provider and remains valid until the next call.
        /// Returns null when no error message is available.
        last_error: ?*const fn (*anyopaque) ?[]const u8 = null,
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

    /// Get the most recent transport-layer error message captured during
    /// the last `stream_text` call, if the provider exposes one.
    pub fn lastError(self: Provider) ?[]const u8 {
        if (self.vtable.last_error) |fn_ptr| {
            return fn_ptr(self.ptr);
        }
        return null;
    }
};

/// Case-insensitive substring match used to detect vendor-specific quirks
/// from `base_url` / `model` without pulling in locale-aware helpers.
fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = haystack[i + j];
            const b = needle[j];
            const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
            const bl = if (b >= 'A' and b <= 'Z') b + 32 else b;
            if (al != bl) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

/// Detect whether a provider configuration needs the `tool_use` placeholder
/// workaround. MiniMax's Anthropic-compat endpoint returns HTTP 400 when an
/// echoed assistant turn contains only `tool_use` blocks (no text). Match
/// on base URL or model name so both the Anthropic-compat and OpenAI-compat
/// MiniMax endpoints get the quirk automatically — callers never have to
/// know, and `agent_provider_set_placeholder_text_quirk` remains as an
/// explicit override.
pub fn detectPlaceholderTextQuirk(base_url: ?[]const u8, model: []const u8) bool {
    if (base_url) |bu| {
        if (containsCaseInsensitive(bu, "minimax")) return true;
    }
    return containsCaseInsensitive(model, "minimax");
}

test "detectPlaceholderTextQuirk" {
    try std.testing.expect(detectPlaceholderTextQuirk("https://api.minimaxi.com/v1", "x"));
    try std.testing.expect(detectPlaceholderTextQuirk("https://api.minimax.io/anthropic", "x"));
    try std.testing.expect(detectPlaceholderTextQuirk(null, "MiniMax-M2"));
    try std.testing.expect(detectPlaceholderTextQuirk(null, "minimax-m1"));
    try std.testing.expect(!detectPlaceholderTextQuirk("https://api.anthropic.com", "claude-opus-4-5"));
    try std.testing.expect(!detectPlaceholderTextQuirk(null, "gpt-4o"));
    try std.testing.expect(!detectPlaceholderTextQuirk(null, ""));
}

/// Check whether a base URL already ends with a version segment (e.g. /v1, /v3, /v4).
/// When true, providers should NOT prepend an extra `/v1` prefix.
pub fn urlEndsWithVersion(url: []const u8) bool {
    var end: usize = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    const trimmed = url[0..end];
    const last_slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return false;
    const seg = trimmed[last_slash + 1 ..];
    if (seg.len < 2 or seg[0] != 'v') return false;
    for (seg[1..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

test "urlEndsWithVersion" {
    try std.testing.expect(!urlEndsWithVersion("https://api.openai.com"));
    try std.testing.expect(urlEndsWithVersion("https://api.openai.com/v1"));
    try std.testing.expect(urlEndsWithVersion("https://api.openai.com/v1/"));
    try std.testing.expect(urlEndsWithVersion("https://ark.cn-beijing.volces.com/api/v3"));
    try std.testing.expect(urlEndsWithVersion("https://open.bigmodel.cn/api/paas/v4"));
    try std.testing.expect(!urlEndsWithVersion("https://generativelanguage.googleapis.com/v1beta/openai"));
    try std.testing.expect(!urlEndsWithVersion("https://api.groq.com/openai"));
    try std.testing.expect(!urlEndsWithVersion(""));
}

test "Provider getter methods via mock vtable" {
    const mock_vtable = Provider.VTable{
        .id = "test-provider",
        .max_context_tokens = 50_000,
        .supports_thinking = true,
        .supports_tool_use = true,
        .stream_text = undefined,
    };
    var dummy: u8 = 0;
    const p = Provider{
        .ptr = @ptrCast(&dummy),
        .vtable = &mock_vtable,
    };
    try std.testing.expectEqualStrings("test-provider", p.getId());
    try std.testing.expectEqual(@as(u32, 50_000), p.getMaxContextTokens());
    try std.testing.expect(p.supportsThinking());
}

test "ProviderConfig defaults" {
    const config = ProviderConfig{
        .id = "test",
        .model = "gpt-4",
    };
    try std.testing.expectEqual(@as(?[]const u8, null), config.api_key);
    try std.testing.expectEqual(@as(?[]const u8, null), config.base_url);
    try std.testing.expectEqual(@as(?u32, null), config.max_context_tokens);
}

test "StreamConfig defaults" {
    const sc = StreamConfig{};
    try std.testing.expectEqual(@as(u32, 16_384), sc.max_tokens);
    try std.testing.expectEqual(@as(?[]const u8, null), sc.system_prompt);
    try std.testing.expectEqual(@as(?f32, null), sc.temperature);
}

/// Iterates over stream chunks from a provider response.
pub const StreamIterator = struct {
    context: *anyopaque,
    nextFn: *const fn (*anyopaque) ?StreamDelta,

    pub fn next(self: *StreamIterator) ?StreamDelta {
        return self.nextFn(self.context);
    }
};
