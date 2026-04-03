const std = @import("std");

/// A UUID v4 string in the canonical format: "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
pub const Uuid = [36]u8;

/// Generate a random UUID v4.
///
/// Uses `std.crypto.random.bytes` for 16 random bytes, then:
/// - Sets the version nibble (byte 6 high nibble = 4)
/// - Sets the variant bits (byte 8 high 2 bits = 10)
/// - Formats as lowercase hex with dashes at positions 8, 13, 18, 23
pub fn v4() Uuid {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Set version: high nibble of byte 6 = 0x4
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant: high 2 bits of byte 8 = 0b10
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    var uuid: Uuid = undefined;

    const hex = "0123456789abcdef";

    // Groups: 4-2-2-2-6 bytes => 8-4-4-4-12 hex chars
    // Byte indices for each group:
    //   [0..3]   => positions  0.. 7
    //   [4..5]   => positions  9..12
    //   [6..7]   => positions 14..17
    //   [8..9]   => positions 19..22
    //   [10..15] => positions 24..35

    const groups = [_]struct { start: usize, end: usize, pos: usize }{
        .{ .start = 0, .end = 4, .pos = 0 },
        .{ .start = 4, .end = 6, .pos = 9 },
        .{ .start = 6, .end = 8, .pos = 14 },
        .{ .start = 8, .end = 10, .pos = 19 },
        .{ .start = 10, .end = 16, .pos = 24 },
    };

    for (groups) |g| {
        var out = g.pos;
        var i = g.start;
        while (i < g.end) : (i += 1) {
            uuid[out] = hex[bytes[i] >> 4];
            uuid[out + 1] = hex[bytes[i] & 0x0f];
            out += 2;
        }
    }

    uuid[8] = '-';
    uuid[13] = '-';
    uuid[18] = '-';
    uuid[23] = '-';

    return uuid;
}

/// Compare two UUIDs for equality.
pub fn eql(a: Uuid, b: Uuid) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Return a slice view into the UUID array.
pub fn toString(uuid: *const Uuid) []const u8 {
    return uuid[0..];
}

test "v4 generates valid UUID format" {
    const id = v4();
    // Dashes at correct positions
    try std.testing.expectEqual('-', id[8]);
    try std.testing.expectEqual('-', id[13]);
    try std.testing.expectEqual('-', id[18]);
    try std.testing.expectEqual('-', id[23]);
    // Version digit must be '4'
    try std.testing.expectEqual('4', id[14]);
    // Variant: high nibble of char at position 19 must be '8', '9', 'a', or 'b'
    const variant_char = id[19];
    const valid_variant = variant_char == '8' or variant_char == '9' or
        variant_char == 'a' or variant_char == 'b';
    try std.testing.expect(valid_variant);
    // Total length
    try std.testing.expectEqual(@as(usize, 36), id.len);
}

test "two UUIDs are different" {
    const a = v4();
    const b = v4();
    try std.testing.expect(!eql(a, b));
}
