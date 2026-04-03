// tests/e2e_smoke_test.zig
const std = @import("std");
const agent = @import("agent");

test "E2E: mock LLM returns tool_use → tool executes → result fed back → final text" {
    const allocator = std.testing.allocator;

    // 1. Set up mock provider with 2 scripted responses:
    //    Response 1: text_delta("Let me check.") → tool_use(FakeTool) → message_stop
    //    Response 2: text_delta("Done!") → message_stop
    var mock = agent.testing.MockProvider.init(allocator, &.{
        // Turn 1: LLM calls FakeTool
        .{ .deltas = &.{
            .{ .@"type" = .text_delta, .text = "Let me check." },
            .{ .@"type" = .content_block_start, .tool_name = "FakeTool", .tool_use_id = "call_1" },
            .{ .@"type" = .content_block_stop },
            .{ .@"type" = .message_stop },
        } },
        // Turn 2: LLM responds with final text (after receiving tool result)
        .{ .deltas = &.{
            .{ .@"type" = .text_delta, .text = "Done!" },
            .{ .@"type" = .message_stop },
        } },
    });

    // 2. Register FakeTool
    var fake_tool_impl = agent.testing.FakeTool{
        .return_value = .{ .string = "tool result data" },
    };
    var tool_registry = agent.tools.ToolRegistry.init(allocator);
    defer tool_registry.deinit();
    try tool_registry.register(agent.tool.buildTool(agent.testing.FakeTool, &fake_tool_impl));

    // 3. Create QueryEngine
    var perm_ctx = agent.permission.PermissionContext{ .mode = .bypass }; // auto-allow all tools
    var hook_runner = agent.hook.HookRunner.init(allocator);
    defer hook_runner.deinit();
    var sw = agent.context.SlidingWindowStrategy.init(20);
    var ctx_strategy = sw.strategy();
    var provider_iface = mock.provider();

    var engine = agent.QueryEngine.init(.{
        .allocator = allocator,
        .provider = &provider_iface,
        .tools = &tool_registry,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hook_runner,
        .context_strategy = &ctx_strategy,
        .system_prompt = "You are a test agent.",
        .max_turns = 10,
    });
    defer engine.deinit();

    // 4. Submit message and consume events
    var iter = engine.submitMessage("Hello");

    var saw_text_delta = false;
    var saw_result = false;
    var result_subtype: ?[]const u8 = null;

    while (iter.next()) |event| {
        switch (event) {
            .stream_event => |delta| {
                if (delta.@"type" == .text_delta) saw_text_delta = true;
            },
            .result => |r| {
                saw_result = true;
                result_subtype = r.subtype;
            },
            else => {},
        }
    }

    // 5. Verify
    try std.testing.expect(saw_text_delta); // LLM produced text
    try std.testing.expectEqual(@as(u32, 1), fake_tool_impl.call_count); // FakeTool was called once
    try std.testing.expect(saw_result); // Got a terminal result
    try std.testing.expectEqualStrings("success", result_subtype.?); // Completed successfully
    try std.testing.expect(engine.messageCount() >= 2); // user + tool_result (assistant msgs emitted as stream events, not stored)
}
