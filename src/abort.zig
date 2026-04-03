const std = @import("std");

pub const AbortController = struct {
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reason: ?[]const u8 = null,

    pub fn abort(self: *AbortController, reason: ?[]const u8) void {
        self.reason = reason;
        self.aborted.store(true, .release);
    }

    pub fn isAborted(self: *const AbortController) bool {
        return self.aborted.load(.acquire);
    }

    pub fn reset(self: *AbortController) void {
        self.aborted.store(false, .release);
        self.reason = null;
    }
};

test "starts not aborted" {
    var controller = AbortController{};
    try std.testing.expect(!controller.isAborted());
}

test "abort sets flag" {
    var controller = AbortController{};
    controller.abort("reason");
    try std.testing.expect(controller.isAborted());
    try std.testing.expectEqualSlices(u8, controller.reason.?, "reason");
}

test "reset clears" {
    var controller = AbortController{};
    controller.abort("reason");
    controller.reset();
    try std.testing.expect(!controller.isAborted());
    try std.testing.expect(controller.reason == null);
}
