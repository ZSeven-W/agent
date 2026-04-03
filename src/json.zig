//! JSON utilities — foundation type used throughout the agent SDK.
//!
//! Wraps `std.json` with convenience accessors and a schema builder type.

const std = @import("std");

// ---------------------------------------------------------------------------
// Core type aliases
// ---------------------------------------------------------------------------

/// Dynamic JSON value.  Identical to `std.json.Value`.
pub const JsonValue = std.json.Value;

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

/// Parse a JSON string into a `std.json.Parsed(JsonValue)`.
///
/// The returned value owns all allocated memory; call `.deinit()` when done.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(JsonValue) {
    return std.json.parseFromSlice(JsonValue, allocator, input, .{});
}

// ---------------------------------------------------------------------------
// Stringify
// ---------------------------------------------------------------------------

/// Serialize a `JsonValue` to a heap-allocated string.
///
/// Caller owns the returned slice and must free it with `allocator.free()`.
pub fn stringify(allocator: std.mem.Allocator, value: JsonValue) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

// ---------------------------------------------------------------------------
// Field accessors
// ---------------------------------------------------------------------------

/// Return the string value of `key` inside a JSON object, or `null`.
pub fn getString(value: JsonValue, key: []const u8) ?[]const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

/// Return the integer value of `key` inside a JSON object, or `null`.
pub fn getInt(value: JsonValue, key: []const u8) ?i64 {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .integer => |i| i,
        else => null,
    };
}

/// Return the bool value of `key` inside a JSON object, or `null`.
pub fn getBool(value: JsonValue, key: []const u8) ?bool {
    const obj = switch (value) {
        .object => |o| o,
        else => return null,
    };
    const field = obj.get(key) orelse return null;
    return switch (field) {
        .bool => |b| b,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// JsonSchema
// ---------------------------------------------------------------------------

/// Lightweight JSON Schema descriptor used to describe tool input/output shapes.
pub const JsonSchema = struct {
    /// JSON Schema "type" (e.g. "object", "string", "integer").
    type: []const u8,

    /// Optional human-readable description.
    description: ?[]const u8 = null,

    /// Named properties for an "object" schema.
    /// Each entry maps a property name to its own `JsonSchema`.
    properties: ?[]const Property = null,

    /// List of required property names.
    required: ?[]const []const u8 = null,

    /// A single property entry within an object schema.
    pub const Property = struct {
        name: []const u8,
        schema: JsonSchema,
    };

    /// Serialize this schema into a `JsonValue` tree.
    ///
    /// All allocations go through `allocator`; the result is only valid while
    /// the arena backing those allocations is alive.
    pub fn toJsonValue(self: JsonSchema, allocator: std.mem.Allocator) !JsonValue {
        var map = std.json.ObjectMap.init(allocator);
        errdefer map.deinit();

        // "type"
        try map.put("type", JsonValue{ .string = self.type });

        // "description"
        if (self.description) |desc| {
            try map.put("description", JsonValue{ .string = desc });
        }

        // "properties"
        if (self.properties) |props| {
            var props_map = std.json.ObjectMap.init(allocator);
            errdefer props_map.deinit();

            for (props) |prop| {
                const prop_value = try prop.schema.toJsonValue(allocator);
                try props_map.put(prop.name, prop_value);
            }

            try map.put("properties", JsonValue{ .object = props_map });
        }

        // "required"
        if (self.required) |req| {
            var arr = std.json.Array.init(allocator);
            errdefer arr.deinit();

            for (req) |name| {
                try arr.append(JsonValue{ .string = name });
            }

            try map.put("required", JsonValue{ .array = arr });
        }

        return JsonValue{ .object = map };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse and access JSON object" {
    const allocator = std.testing.allocator;

    const input = "{\"name\":\"Read\",\"count\":42,\"active\":true}";
    const parsed = try parse(allocator, input);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Read", getString(parsed.value, "name").?);
    try std.testing.expectEqual(@as(i64, 42), getInt(parsed.value, "count").?);
    try std.testing.expectEqual(true, getBool(parsed.value, "active").?);
}

test "stringify JSON value" {
    const allocator = std.testing.allocator;

    const input = "{\"a\":1}";
    const parsed = try parse(allocator, input);
    defer parsed.deinit();

    const out = try stringify(allocator, parsed.value);
    defer allocator.free(out);

    try std.testing.expectEqualStrings(input, out);
}

test "JsonSchema toJsonValue" {
    const allocator = std.testing.allocator;

    const schema = JsonSchema{
        .type = "object",
        .description = "A test schema",
        .properties = &[_]JsonSchema.Property{
            .{ .name = "path", .schema = .{ .type = "string", .description = "File path" } },
            .{ .name = "count", .schema = .{ .type = "integer" } },
        },
        .required = &[_][]const u8{ "path" },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const jv = try schema.toJsonValue(arena.allocator());

    // Top-level must be an object with "type" == "object"
    try std.testing.expectEqualStrings("object", getString(jv, "type").?);
    try std.testing.expectEqualStrings("A test schema", getString(jv, "description").?);

    // "properties" must exist and contain "path"
    const props = jv.object.get("properties") orelse return error.MissingProperties;
    const path_schema = props.object.get("path") orelse return error.MissingPathProperty;
    try std.testing.expectEqualStrings("string", getString(path_schema, "type").?);
    try std.testing.expectEqualStrings("File path", getString(path_schema, "description").?);

    const count_schema = props.object.get("count") orelse return error.MissingCountProperty;
    try std.testing.expectEqualStrings("integer", getString(count_schema, "type").?);

    // "required" must be an array containing "path"
    const req = jv.object.get("required") orelse return error.MissingRequired;
    try std.testing.expectEqual(@as(usize, 1), req.array.items.len);
    try std.testing.expectEqualStrings("path", req.array.items[0].string);
}
