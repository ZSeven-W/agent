// src/tools/registry.zig
const std = @import("std");
const tool_mod = @import("../tool.zig");
const providers_types = @import("../providers/types.zig");

pub const Tool = tool_mod.Tool;
pub const ToolSchema = providers_types.ToolSchema;

pub const ToolRegistry = struct {
    tools: std.StringHashMap(Tool),
    schemas: std.StringHashMap(ToolSchema),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .tools = std.StringHashMap(Tool).init(allocator),
            .schemas = std.StringHashMap(ToolSchema).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
        self.schemas.deinit();
    }

    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        const name = tool.getName();
        if (self.tools.contains(name)) return error.DuplicateTool;
        try self.tools.put(name, tool);
    }

    /// Register a schema-only tool (no execute fn). These are executed externally (e.g. by JS).
    pub fn registerSchema(self: *ToolRegistry, schema: ToolSchema) !void {
        if (self.schemas.contains(schema.name)) return error.DuplicateTool;
        try self.schemas.put(schema.name, schema);
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

    /// Check if a name exists in either executable tools or schema-only tools.
    pub fn isKnown(self: *const ToolRegistry, name: []const u8) bool {
        return self.tools.contains(name) or self.schemas.contains(name);
    }

    /// True if the name is in schemas but NOT in executable tools (schema-only, executed by JS).
    pub fn isExternal(self: *const ToolRegistry, name: []const u8) bool {
        return self.schemas.contains(name) and !self.tools.contains(name);
    }

    /// Return merged view of executable tools + schema-only tools as ToolSchema slice.
    /// Caller owns the returned slice and must free it with the provided allocator.
    pub fn allSchemas(self: *const ToolRegistry, allocator: std.mem.Allocator) ![]const ToolSchema {
        const total = self.tools.count() + self.schemas.count();
        if (total == 0) return &.{};

        var result = try allocator.alloc(ToolSchema, total);
        var idx: usize = 0;

        // 1. Executable tools — build ToolSchema from their VTable
        var tool_it = self.tools.valueIterator();
        while (tool_it.next()) |tool| {
            // Convert JsonSchema to JsonValue using an arena so the data lives
            // as long as the caller needs (they own the slice, but the JsonValue
            // trees are backed by this arena — callers should use the data before
            // freeing). For a simple implementation we use the provided allocator.
            const input_schema_value = tool.vtable.input_schema.toJsonValue(allocator) catch .null;
            result[idx] = .{
                .name = tool.vtable.name,
                .description = tool.vtable.description(tool.ptr),
                .input_schema = input_schema_value,
            };
            idx += 1;
        }

        // 2. Schema-only tools — directly from the schemas map
        var schema_it = self.schemas.valueIterator();
        while (schema_it.next()) |schema| {
            result[idx] = schema.*;
            idx += 1;
        }

        return result[0..idx];
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

test "ToolRegistry registerSchema and isKnown/isExternal" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    // Register a schema-only tool
    try reg.registerSchema(.{
        .name = "ExternalTool",
        .description = "A tool executed by JS",
        .input_schema = .{ .string = "object" },
    });

    // isKnown should find it
    try std.testing.expect(reg.isKnown("ExternalTool"));
    // isExternal should be true (only in schemas, not in tools)
    try std.testing.expect(reg.isExternal("ExternalTool"));
    // Unknown name should not be known or external
    try std.testing.expect(!reg.isKnown("NoSuchTool"));
    try std.testing.expect(!reg.isExternal("NoSuchTool"));

    // Register an executable tool
    var impl = @import("../tool.zig").TestTool{};
    const tool = @import("../tool.zig").buildTool(@import("../tool.zig").TestTool, &impl);
    try reg.register(tool);

    // Executable tool is known but not external
    try std.testing.expect(reg.isKnown("TestTool"));
    try std.testing.expect(!reg.isExternal("TestTool"));
}

test "ToolRegistry registerSchema rejects duplicate" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const schema = ToolSchema{
        .name = "ExtTool",
        .description = "desc",
        .input_schema = .null,
    };
    try reg.registerSchema(schema);
    try std.testing.expectError(error.DuplicateTool, reg.registerSchema(schema));
}

test "ToolRegistry allSchemas merges executable and schema-only" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    // Register an executable tool
    var impl = @import("../tool.zig").TestTool{};
    const tool = @import("../tool.zig").buildTool(@import("../tool.zig").TestTool, &impl);
    try reg.register(tool);

    // Register a schema-only tool
    try reg.registerSchema(.{
        .name = "ExternalTool",
        .description = "External",
        .input_schema = .{ .string = "object" },
    });

    // Use an arena to manage allocations from allSchemas
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const schemas = try reg.allSchemas(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), schemas.len);

    // Verify both tools are present (order not guaranteed by HashMap)
    var found_test = false;
    var found_ext = false;
    for (schemas) |s| {
        if (std.mem.eql(u8, s.name, "TestTool")) found_test = true;
        if (std.mem.eql(u8, s.name, "ExternalTool")) found_ext = true;
    }
    try std.testing.expect(found_test);
    try std.testing.expect(found_ext);
}

test "ToolRegistry allSchemas returns empty for empty registry" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const schemas = try reg.allSchemas(allocator);
    try std.testing.expectEqual(@as(usize, 0), schemas.len);
}

test "ToolRegistry replace updates existing tool" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    var impl1 = @import("../tool.zig").TestTool{};
    const tool1 = @import("../tool.zig").buildTool(@import("../tool.zig").TestTool, &impl1);

    try reg.register(tool1);
    try std.testing.expectEqual(@as(usize, 1), reg.count());

    // Replace with a different impl pointer (same name)
    var impl2 = @import("../tool.zig").TestTool{};
    const tool2 = @import("../tool.zig").buildTool(@import("../tool.zig").TestTool, &impl2);
    try reg.replace(tool2);

    try std.testing.expectEqual(@as(usize, 1), reg.count());
    // The new tool should reference impl2's address
    const found = reg.get("TestTool").?;
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&impl2)), found.ptr);
}

test "ToolRegistry replace rejects unknown tool" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    var impl = @import("../tool.zig").TestTool{};
    const tool = @import("../tool.zig").buildTool(@import("../tool.zig").TestTool, &impl);

    try std.testing.expectError(error.ToolNotFound, reg.replace(tool));
}

test "ToolRegistry listNames returns tool names" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    var impl = @import("../tool.zig").TestTool{};
    const tool = @import("../tool.zig").buildTool(@import("../tool.zig").TestTool, &impl);
    try reg.register(tool);

    const names = try reg.listNames(allocator);
    defer allocator.free(names);

    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("TestTool", names[0]);
}

test "ToolRegistry listNames returns empty for empty registry" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    const names = try reg.listNames(allocator);
    defer allocator.free(names);
    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "ToolRegistry get returns null for unknown tool" {
    const allocator = std.testing.allocator;
    var reg = ToolRegistry.init(allocator);
    defer reg.deinit();

    try std.testing.expectEqual(@as(?Tool, null), reg.get("NonExistent"));
}
