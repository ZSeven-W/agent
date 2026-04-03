// src/context/strategy.zig
const message_mod = @import("../message.zig");

pub const ContextStrategy = struct {
    ptr: *anyopaque,
    trimFn: *const fn (*anyopaque, []const message_mod.Message, u32) []const message_mod.Message,

    pub fn trim(self: ContextStrategy, messages: []const message_mod.Message, max_tokens: u32) []const message_mod.Message {
        return self.trimFn(self.ptr, messages, max_tokens);
    }
};
