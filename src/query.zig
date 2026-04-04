// src/query.zig
const std = @import("std");
const message_mod = @import("message.zig");
const tool_mod = @import("tool.zig");
const perm = @import("permission.zig");
const streaming_events = @import("streaming/events.zig");
const tool_executor_mod = @import("streaming/tool_executor.zig");
const providers_types = @import("providers/types.zig");
const session_mod = @import("session.zig");
const hook_mod = @import("hook.zig");
const abort_mod = @import("abort.zig");
const context_mod = @import("context/strategy.zig");
const json_mod = @import("json.zig");
const tools_reg = @import("tools/registry.zig");
const file_cache_mod = @import("file_cache.zig");
const etq_mod = @import("external_tool_queue.zig");

pub const Event = streaming_events.Event;
pub const EventIterator = streaming_events.EventIterator;

pub const Transition = enum {
    tool_use,
    collapse_drain,
    reactive_compact,
    max_output_escalate,
    max_output_multi_turn,
    stop_hook,
};

pub const QueryState = struct {
    messages: *message_mod.MessageStore,
    ctx: *tool_mod.ToolUseContext,
    max_output_recovery_count: u32 = 0,
    has_attempted_reactive_compact: bool = false,
    max_output_override: ?u32 = null,
    stop_hook_active: bool = false,
    turn_count: u32 = 0,
    transition: ?Transition = null,
    done: bool = false,
    result: ?streaming_events.ResultData = null,
};

pub const QueryParams = struct {
    allocator: std.mem.Allocator,
    provider: *providers_types.Provider,
    tool_registry: *tools_reg.ToolRegistry,
    permission_ctx: *perm.PermissionContext,
    hook_runner: *hook_mod.HookRunner,
    session: *session_mod.Session,
    abort: *abort_mod.AbortController,
    context_strategy: *context_mod.ContextStrategy,
    file_cache: *file_cache_mod.FileStateCache,
    system_prompt: ?[]const u8 = null,
    max_turns: u32 = 50,
    max_budget_usd: ?f64 = null,
    external_queue: ?*etq_mod.ExternalToolQueue = null,
};

/// The main agentic loop. Returns a QueryLoopIterator that yields Events.
pub fn queryLoop(params: QueryParams, initial_messages: *message_mod.MessageStore) QueryLoopIterator {
    return .{
        .params = params,
        .state = .{
            .messages = initial_messages,
            .ctx = undefined, // initialized on first call when needed
        },
        .phase = .start,
    };
}

pub const QueryLoopIterator = struct {
    params: QueryParams,
    state: QueryState,
    phase: Phase,

    // Buffered events to yield
    event_buf: [64]Event = undefined,
    event_count: usize = 0,
    event_index: usize = 0,

    // Current turn state
    stream_iter: ?providers_types.StreamIterator = null,
    tool_exec: ?tool_executor_mod.StreamingToolExecutor = null,
    // Accumulates partial_json fragments for the current tool_use input
    tool_json_buf: std.ArrayListUnmanaged(u8) = .{},

    const Phase = enum {
        start,
        streaming,
        tool_dispatch,
        waiting_for_external_tools,
        tool_collecting,
        yielding_result,
        done,
    };

    pub fn toEventIterator(self: *QueryLoopIterator) EventIterator {
        return .{
            .context = @ptrCast(self),
            .nextFn = nextEvent,
        };
    }

    fn nextEvent(ctx: *anyopaque) ?Event {
        const self: *QueryLoopIterator = @ptrCast(@alignCast(ctx));

        // Drain buffered events first
        if (self.event_index < self.event_count) {
            const event = self.event_buf[self.event_index];
            self.event_index += 1;
            return event;
        }
        self.event_count = 0;
        self.event_index = 0;

        if (self.params.abort.isAborted()) {
            self.phase = .done;
            return .{ .result = .{
                .is_error = true,
                .subtype = "error_aborted",
                .num_turns = self.state.turn_count,
                .total_cost_usd = 0,
                .duration_ms = 0,
            } };
        }

        switch (self.phase) {
            .start => {
                if (self.state.turn_count >= self.params.max_turns) {
                    self.phase = .done;
                    return .{ .result = .{
                        .is_error = true,
                        .subtype = "error_max_turns",
                        .num_turns = self.state.turn_count,
                        .total_cost_usd = 0,
                        .duration_ms = 0,
                    } };
                }

                self.state.turn_count += 1;

                // Convert MessageStore to ApiMessages
                var api_messages: std.ArrayList(providers_types.ApiMessage) = .{};
                defer api_messages.deinit(self.params.allocator);

                const messages_slice = self.state.messages.items();
                for (messages_slice) |msg| {
                    switch (msg) {
                        .user => |u| {
                            const text: []const u8 = if (u.content.len > 0) switch (u.content[0]) {
                                .text => |t| t,
                                else => "",
                            } else "";
                            api_messages.append(self.params.allocator, .{
                                .role = "user",
                                .content = .{ .string = text },
                            }) catch {};
                        },
                        .assistant => |a| {
                            const text: []const u8 = if (a.content.len > 0) switch (a.content[0]) {
                                .text => |t| t,
                                else => "",
                            } else "";
                            api_messages.append(self.params.allocator, .{
                                .role = "assistant",
                                .content = .{ .string = text },
                            }) catch {};
                        },
                        else => {},
                    }
                }

                // Build merged tool schemas from registry (executable + external).
                // Use an arena so that both the slice and any inner JsonValue
                // allocations (from toJsonValue) are freed together.
                var schema_arena = std.heap.ArenaAllocator.init(self.params.allocator);
                defer schema_arena.deinit();
                const tool_schemas = self.params.tool_registry.allSchemas(schema_arena.allocator()) catch &.{};
                const tools_param: ?[]const providers_types.ToolSchema =
                    if (tool_schemas.len > 0) tool_schemas else null;

                const stream_result = self.params.provider.vtable.stream_text(
                    self.params.provider.ptr,
                    api_messages.items,
                    tools_param,
                    .{ .system_prompt = self.params.system_prompt },
                );

                if (stream_result) |iter| {
                    self.stream_iter = iter;
                    self.phase = .streaming;
                    return nextEvent(ctx);
                } else |err| {
                    self.phase = .done;
                    return .{ .result = .{
                        .is_error = true,
                        .subtype = switch (err) {
                            error.AuthenticationFailed => "error_authentication",
                            error.RateLimited => "error_rate_limit",
                            error.ServerError => "error_server",
                            error.InvalidRequest => "error_invalid_request",
                            else => "error_connection",
                        },
                        .num_turns = self.state.turn_count,
                        .total_cost_usd = 0,
                        .duration_ms = 0,
                    } };
                }
            },

            .streaming => {
                if (self.stream_iter) |*iter| {
                    if (iter.next()) |delta| {
                        // Track tool_use blocks
                        if (delta.@"type" == .content_block_start and delta.tool_name != null) {
                            if (self.tool_exec == null) {
                                self.tool_exec = tool_executor_mod.StreamingToolExecutor.init(self.params.allocator);
                            }
                            // Reset partial_json accumulator for new tool
                            self.tool_json_buf.clearRetainingCapacity();
                            const msg_count = self.state.messages.count();
                            const uuid = if (msg_count > 0)
                                self.state.messages.items()[msg_count - 1].getHeader().uuid
                            else
                                @import("uuid.zig").v4();
                            self.tool_exec.?.addTool(.{
                                .id = delta.tool_use_id orelse "unknown",
                                .name = delta.tool_name.?,
                                .input = .null,
                            }, uuid) catch {};
                        }

                        // Accumulate tool input JSON fragments
                        if (delta.@"type" == .tool_use_delta) {
                            if (delta.partial_json) |pj| {
                                self.tool_json_buf.appendSlice(self.params.allocator, pj) catch {};
                            }
                        }

                        // When a tool_use content block ends, parse accumulated JSON into the tool's input
                        if (delta.@"type" == .content_block_stop and self.tool_exec != null and self.tool_json_buf.items.len > 0) {
                            const parsed_input = json_mod.parse(self.params.allocator, self.tool_json_buf.items) catch null;
                            if (parsed_input) |p| {
                                // Update the last added tool's input
                                const tracked = self.tool_exec.?.tracked.items;
                                if (tracked.len > 0) {
                                    tracked[tracked.len - 1].block.input = p.value;
                                }
                            }
                            self.tool_json_buf.clearRetainingCapacity();
                        }

                        if (delta.@"type" == .message_stop) {
                            if (self.tool_exec != null and self.tool_exec.?.pendingCount() > 0) {
                                self.phase = .tool_dispatch;
                            } else {
                                self.phase = .yielding_result;
                            }
                            return nextEvent(ctx);
                        }
                        return .{ .stream_event = delta };
                    }
                }
                // Stream exhausted
                if (self.tool_exec != null and self.tool_exec.?.pendingCount() > 0) {
                    self.phase = .tool_dispatch;
                } else {
                    self.phase = .yielding_result;
                }
                return nextEvent(ctx);
            },

            .yielding_result => {
                self.phase = .done;
                return .{ .result = .{
                    .is_error = false,
                    .subtype = "success",
                    .num_turns = self.state.turn_count,
                    .total_cost_usd = 0,
                    .duration_ms = 0,
                    .result = "done",
                } };
            },

            .done => return null,

            .tool_dispatch => {
                if (self.tool_exec == null) {
                    self.tool_exec = tool_executor_mod.StreamingToolExecutor.init(self.params.allocator);
                }
                var exec = &self.tool_exec.?;

                for (exec.tracked.items) |*tracked| {
                    if (tracked.status != .queued) continue;
                    tracked.status = .executing;

                    const tool_name = tracked.block.name;
                    const tool_input = tracked.block.input;

                    // External tools: yield tool_use event for JS, don't execute locally
                    if (self.params.tool_registry.isExternal(tool_name)) {
                        self.event_buf[self.event_count] = .{ .tool_use = .{
                            .id = tracked.block.id,
                            .name = tool_name,
                            .input = tool_input,
                        } };
                        self.event_count += 1;
                        // Don't block here — mark as executing and let events drain first
                        continue;
                    }

                    // 1. Look up tool
                    const maybe_tool = self.params.tool_registry.get(tool_name);
                    if (maybe_tool == null) {
                        exec.fail(tracked.block.id, "Tool not found");
                        continue;
                    }
                    const found_tool = maybe_tool.?;

                    // 2. Permission check
                    const perm_decision = perm.evaluatePermission(
                        tool_name,
                        tool_input,
                        self.params.permission_ctx.*,
                        null,
                    );

                    switch (perm_decision) {
                        .deny => |d| {
                            exec.fail(tracked.block.id, d.message_text);
                            continue;
                        },
                        .ask => {
                            self.event_buf[self.event_count] = .{ .tool_progress = .{
                                .tool_name = tool_name,
                                .tool_use_id = tracked.block.id,
                                .data = .{ .string = "awaiting_permission" },
                            } };
                            self.event_count += 1;
                            continue;
                        },
                        .allow => {},
                    }

                    // 3. Execute tool
                    var tool_ctx = tool_mod.ToolUseContext{
                        .allocator = self.params.allocator,
                        .cwd = ".",
                        .abort_controller = self.params.abort,
                        .file_cache = self.params.file_cache,
                        .messages = self.state.messages,
                        .permission_ctx = self.params.permission_ctx,
                        .hook_runner = self.params.hook_runner,
                    };

                    if (found_tool.call(tool_input, &tool_ctx)) |result| {
                        exec.complete(tracked.block.id, result);
                    } else |_| {
                        exec.fail(tracked.block.id, "Tool execution failed");
                    }
                }

                // Check if there are external tools pending (executing but not yet resolved)
                var has_external_pending = false;
                for (exec.tracked.items) |t| {
                    if (t.status == .executing and self.params.tool_registry.isExternal(t.block.name)) {
                        has_external_pending = true;
                        break;
                    }
                }

                if (has_external_pending) {
                    self.phase = .waiting_for_external_tools;
                    // Return to drain buffered tool_use events first
                    return nextEvent(ctx);
                }

                self.phase = .tool_collecting;
                return nextEvent(ctx);
            },

            .waiting_for_external_tools => {
                if (self.params.external_queue == null) {
                    self.phase = .tool_collecting;
                    return nextEvent(ctx);
                }
                const queue = self.params.external_queue.?;
                var exec = &self.tool_exec.?;

                // Block on each pending external tool until JS resolves it
                for (exec.tracked.items) |*tracked| {
                    if (tracked.status != .executing) continue;
                    if (!self.params.tool_registry.isExternal(tracked.block.name)) continue;

                    // Block until JS resolves this tool
                    const ext_result = queue.waitFor(
                        tracked.block.id,
                        &self.params.abort.aborted,
                    );
                    if (ext_result) |r| {
                        const parsed = json_mod.parse(self.params.allocator, r.result_json) catch {
                            exec.fail(tracked.block.id, "Failed to parse external tool result");
                            self.params.allocator.free(r.tool_use_id);
                            self.params.allocator.free(r.result_json);
                            continue;
                        };
                        exec.complete(tracked.block.id, .{ .data = parsed.value });
                        self.params.allocator.free(r.tool_use_id);
                        self.params.allocator.free(r.result_json);
                    } else {
                        exec.fail(tracked.block.id, "aborted");
                    }
                }

                self.phase = .tool_collecting;
                return nextEvent(ctx);
            },

            .tool_collecting => {
                var exec = &self.tool_exec.?;

                while (exec.nextCompleted()) |completed| {
                    const result_block = message_mod.ContentBlock{
                        .tool_result = .{
                            .tool_use_id = completed.block.id,
                            .content = if (completed.result) |r| r.data else .{ .string = completed.error_message orelse "unknown error" },
                            .is_error = completed.error_message != null,
                        },
                    };

                    self.state.messages.append(.{ .user = .{
                        .header = message_mod.Header.init(),
                        .content = &.{result_block},
                    } }) catch {};

                    self.params.session.record("{\"type\":\"tool_result\"}") catch {};
                }

                if (exec.pendingCount() == 0) {
                    self.phase = .start;
                    self.state.transition = .tool_use;
                    return nextEvent(ctx);
                }

                return null;
            },
        }
    }
};

test "queryLoop yields error on max_turns exceeded" {
    const allocator = std.testing.allocator;
    var msgs = message_mod.MessageStore.init(allocator);
    defer msgs.deinit();
    var abort = abort_mod.AbortController{};
    var hooks = hook_mod.HookRunner.init(allocator);
    defer hooks.deinit();
    var session = session_mod.Session.init(allocator);
    defer session.deinit();
    var perm_ctx = perm.PermissionContext{};
    var cache = file_cache_mod.FileStateCache.init(allocator, 10, 1024);
    defer cache.deinit();
    var reg = tools_reg.ToolRegistry.init(allocator);
    defer reg.deinit();

    var loop_iter = queryLoop(.{
        .allocator = allocator,
        .provider = undefined,
        .tool_registry = &reg,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hooks,
        .session = &session,
        .abort = &abort,
        .context_strategy = undefined,
        .file_cache = &cache,
        .max_turns = 0,
    }, &msgs);

    var iter = loop_iter.toEventIterator();
    const event = iter.next().?;
    try std.testing.expectEqualStrings("error_max_turns", event.result.subtype);
}

test "queryLoop yields error on abort" {
    const allocator = std.testing.allocator;
    var msgs = message_mod.MessageStore.init(allocator);
    defer msgs.deinit();
    var abort = abort_mod.AbortController{};
    abort.abort("test cancel");
    var hooks = hook_mod.HookRunner.init(allocator);
    defer hooks.deinit();
    var session = session_mod.Session.init(allocator);
    defer session.deinit();
    var perm_ctx = perm.PermissionContext{};
    var cache = file_cache_mod.FileStateCache.init(allocator, 10, 1024);
    defer cache.deinit();
    var reg = tools_reg.ToolRegistry.init(allocator);
    defer reg.deinit();

    var loop_iter = queryLoop(.{
        .allocator = allocator,
        .provider = undefined,
        .tool_registry = &reg,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hooks,
        .session = &session,
        .abort = &abort,
        .context_strategy = undefined,
        .file_cache = &cache,
    }, &msgs);

    var iter = loop_iter.toEventIterator();
    const event = iter.next().?;
    try std.testing.expectEqualStrings("error_aborted", event.result.subtype);
}
