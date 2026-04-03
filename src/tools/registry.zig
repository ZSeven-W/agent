// src/tools/registry.zig
const std = @import("std");
const tool_mod = @import("../tool.zig");

pub const Tool = tool_mod.Tool;

pub const ToolRegistry = struct {
    tools: std.StringHashMap(Tool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .tools = std.StringHashMap(Tool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
    }

    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        const name = tool.getName();
        if (self.tools.contains(name)) return error.DuplicateTool;
        try self.tools.put(name, tool);
    }

    pub fn unregister(self: *ToolRegistry, name: []const u8) bool {
        return self.tools.remove(name);
    }

    pub fn replace(self: *ToolRegistry, tool: Tool) !void {
        const name = tool.getName();
        if (!self.tools.contains(name)) return error.ToolNotFound;
        try self.tools.put(name, tool);
    }

    pub fn get(self: *const ToolRegistry, name: []const u8) ?Tool {
        return self.tools.get(name);
    }

    pub fn count(self: *const ToolRegistry) usize {
        return self.tools.count();
    }

    /// Return all tool names (caller owns the returned slice).
    pub fn listNames(self: *const ToolRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        var names: std.ArrayList([]const u8) = .{};
        var it = self.tools.keyIterator();
        while (it.next()) |key| {
            try names.append(allocator, key.*);
        }
        return names.toOwnedSlice(allocator);
    }
};

test "ToolRegistry register and get" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    var impl = @import("../tool.zig").TestTool{};
    const tool = @import("../tool.zig").buildTool(@import("../tool.zig").TestTool, &impl);

    try reg.register(tool);
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    const found = reg.get("TestTool").?;
    try std.testing.expectEqualStrings("TestTool", found.getName());
}

test "ToolRegistry rejects duplicate" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    var impl = @import("../tool.zig").TestTool{};
    const tool = @import("../tool.zig").buildTool(@import("../tool.zig").TestTool, &impl);

    try reg.register(tool);
    try std.testing.expectError(error.DuplicateTool, reg.register(tool));
}

test "ToolRegistry unregister" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    var impl = @import("../tool.zig").TestTool{};
    const tool = @import("../tool.zig").buildTool(@import("../tool.zig").TestTool, &impl);

    try reg.register(tool);
    try std.testing.expect(reg.unregister("TestTool"));
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}
