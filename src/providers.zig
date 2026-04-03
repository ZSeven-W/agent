// src/providers.zig
pub const types = @import("providers/types.zig");
pub const anthropic = @import("providers/anthropic.zig");
pub const openai_compat = @import("providers/openai_compat.zig");
pub const ollama = @import("providers/ollama.zig");
pub const Provider = types.Provider;
pub const ProviderConfig = types.ProviderConfig;
pub const AnthropicProvider = anthropic.AnthropicProvider;
pub const OpenAICompatProvider = openai_compat.OpenAICompatProvider;
pub const presets = openai_compat.presets;
