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
    // Zig 0.15+ refuses to compile any module that references the `c` extern
    // namespace without explicit libc linkage. `src/` indirectly pulls in
    // std.heap.c_allocator / std.c.malloc_usable_size, so we opt in here.
    c_api_module.link_libc = true;
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
        // Static archive gets linked into a dynamic .node / .so on Linux, so
        // every object inside must be position-independent. macOS Mach-O is
        // always PIC so the flag is a no-op there, but on ELF the link step
        // fails with R_X86_64_32 relocation errors without it.
        .pic = true,
    });
    c_api_static_module.link_libc = true;
    // On Windows, std.net pulls in Winsock (WSA*) and std.http.Client's TLS
    // path pulls in the Crypto API (Cert*StoreW, etc.) — link both at the
    // static-lib level so downstream linkages (napi.node) don't have to know.
    if (target.result.os.tag == .windows) {
        c_api_static_module.linkSystemLibrary("ws2_32", .{});
        c_api_static_module.linkSystemLibrary("crypt32", .{});
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
        .pic = true,
    });
    bridge_module.linkLibrary(static_lib);
    bridge_module.link_libc = true;
    if (target.result.os.tag == .windows) {
        bridge_module.linkSystemLibrary("ws2_32", .{});
        bridge_module.linkSystemLibrary("crypt32", .{});
    }
    const napi_lib = b.addLibrary(.{
        .name = "agent_napi",
        .root_module = bridge_module,
        .linkage = .dynamic,
    });
    // NAPI symbols are provided at runtime by the Node.js process. On ELF /
    // Mach-O the linker can just emit undefined imports, but PE/COFF needs
    // an explicit import library that declares every napi_* as coming from
    // `node.exe`. We synthesize that on demand from `napi/node_api.def`
    // using `zig dlltool`, so nothing gets checked into the repo as a
    // pre-compiled .lib.
    napi_lib.linker_allow_shlib_undefined = true;
    if (target.result.os.tag == .windows) {
        const dll_machine = switch (target.result.cpu.arch) {
            .x86_64 => "i386:x86-64",
            .aarch64 => "arm64",
            .x86 => "i386",
            else => @panic("unsupported windows cpu arch for dlltool"),
        };
        const gen_node_lib = b.addSystemCommand(&.{
            "zig", "dlltool",
            "-m", dll_machine,
            "-d",
        });
        gen_node_lib.addFileArg(b.path("napi/node_api.def"));
        gen_node_lib.addArg("-l");
        const node_import_lib = gen_node_lib.addOutputFileArg("libnode_api.a");
        napi_lib.addObjectFile(node_import_lib);
    }
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
