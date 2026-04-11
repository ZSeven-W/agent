const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Target 1: Zig module (for @import consumers)
    const agent_module = b.addModule("agent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Target 2: C ABI shared library
    const c_api_module = b.addModule("c_api", .{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    const shared_lib = b.addLibrary(.{
        .name = "agent",
        .root_module = c_api_module,
        .linkage = .dynamic,
    });
    b.installArtifact(shared_lib);

    // Tests: unit tests (all modules via root.zig)
    const tests = b.addTest(.{
        .root_module = agent_module,
    });
    const test_step = b.step("test", "Run agent tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ─── Target 3: NAPI addon (zig build napi → zig-out/napi/agent_napi.node) ───
    // Statically links agent code so agent_napi.node is self-contained (no libagent.dylib needed).
    const c_api_static_module = b.addModule("c_api_static", .{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_api_static_module.link_libc = true;
    // std.net on Windows pulls in Winsock — link ws2_32 so WSASend/WSARecv/
    // WSAGetOverlappedResult resolve at link time instead of failing at load.
    if (target.result.os.tag == .windows) {
        c_api_static_module.linkSystemLibrary("ws2_32", .{});
    }
    const static_lib = b.addLibrary(.{
        .name = "agent_static",
        .root_module = c_api_static_module,
        .linkage = .static,
    });
    const bridge_module = b.addModule("bridge", .{
        .root_source_file = b.path("napi/src/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_module.linkLibrary(static_lib);
    bridge_module.link_libc = true;
    if (target.result.os.tag == .windows) {
        bridge_module.linkSystemLibrary("ws2_32", .{});
    }
    const napi_lib = b.addLibrary(.{
        .name = "agent_napi",
        .root_module = bridge_module,
        .linkage = .dynamic,
    });
    // NAPI symbols are provided at runtime by the Node.js process.
    napi_lib.linker_allow_shlib_undefined = true;
    const napi_install = b.addInstallFileWithDir(
        napi_lib.getEmittedBin(),
        .{ .custom = "napi" },
        "agent_napi.node",
    );
    const napi_step = b.step("napi", "Build NAPI addon (→ zig-out/napi/agent_napi.node)");
    napi_step.dependOn(&napi_install.step);

    // Tests: E2E smoke test
    const e2e_module = b.addModule("e2e_smoke_test", .{
        .root_source_file = b.path("tests/e2e_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "agent", .module = agent_module }},
    });
    const e2e_tests = b.addTest(.{
        .root_module = e2e_module,
    });
    test_step.dependOn(&b.addRunArtifact(e2e_tests).step);
}
