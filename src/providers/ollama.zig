// src/providers/ollama.zig
const std = @import("std");
const types = @import("types.zig");
const openai_compat = @import("openai_compat.zig");

pub fn createOllamaConfig(model: []const u8) openai_compat.OpenAICompatConfig {
    return .{
        .base = .{
            .id = "ollama",
            .base_url = "http://localhost:11434/v1",
            .api_key = null,
            .model = model,
            .max_context_tokens = 32768,
        },
        .quirks = .{ .supports_stream_options = false },
    };
}

test "Ollama config defaults" {
    const config = createOllamaConfig("llama3");
    try std.testing.expectEqualStrings("ollama", config.base.id);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", config.base.base_url.?);
    try std.testing.expectEqual(@as(?[]const u8, null), config.base.api_key);
    try std.testing.expect(!config.quirks.supports_stream_options);
}
