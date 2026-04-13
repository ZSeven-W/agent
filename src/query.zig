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
    max_output_tokens: u32 = 16_384,
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

/// Maximum characters for a single tool_result content string.
/// Larger results are truncated to prevent context bloat (similar to
/// Claude Code's microcompact strategy of clearing old tool results).
const TOOL_RESULT_MAX_CHARS: usize = 4000;

/// Convert ContentBlock slice to a JsonValue suitable for the API.
/// If the slice has a single text block, return a plain string.
/// Otherwise return a JSON array with typed objects (text, thinking, tool_use, tool_result).
fn contentBlocksToJson(allocator: std.mem.Allocator, blocks: []const message_mod.ContentBlock) !json_mod.JsonValue {
    // Fast path: single text block → plain string
    if (blocks.len == 1) {
        switch (blocks[0]) {
            .text => |t| return .{ .string = t },
            else => {},
        }
    }
    if (blocks.len == 0) return .{ .string = "" };

    var arr = std.json.Array.init(allocator);
    for (blocks) |block| {
        switch (block) {
            .text => |t| {
                var obj = std.json.ObjectMap.init(allocator);
                try obj.put("type", .{ .string = "text" });
                try obj.put("text", .{ .string = t });
                try arr.append(.{ .object = obj });
            },
            .thinking => |tb| {
                // Echo thinking blocks back to preserve the reasoning chain.
                // MiniMax docs confirm: "将完整的 response.content（包含
                // thinking/text/tool_use 等所有块）添加到消息历史"
                var obj = std.json.ObjectMap.init(allocator);
                try obj.put("type", .{ .string = "thinking" });
                try obj.put("thinking", .{ .string = tb.thinking });
                try arr.append(.{ .object = obj });
            },
            .tool_use => |tu| {
                var obj = std.json.ObjectMap.init(allocator);
                try obj.put("type", .{ .string = "tool_use" });
                try obj.put("id", .{ .string = tu.id });
                try obj.put("name", .{ .string = tu.name });
                try obj.put("input", tu.input);
                try arr.append(.{ .object = obj });
            },
            .tool_result => |tr| {
                var obj = std.json.ObjectMap.init(allocator);
                try obj.put("type", .{ .string = "tool_result" });
                try obj.put("tool_use_id", .{ .string = tr.tool_use_id });
                // Anthropic API requires content to be a string, not a JSON object
                const raw_val: json_mod.JsonValue = switch (tr.content) {
                    .string => tr.content,
                    else => .{ .string = json_mod.stringify(allocator, tr.content) catch "" },
                };
                // Truncate oversized tool results to prevent context overflow
                const content_val: json_mod.JsonValue = if (raw_val == .string and raw_val.string.len > TOOL_RESULT_MAX_CHARS) blk: {
                    const truncated = std.fmt.allocPrint(
                        allocator,
                        "{s}...[truncated, {d} chars total]",
                        .{ raw_val.string[0..TOOL_RESULT_MAX_CHARS], raw_val.string.len },
                    ) catch raw_val.string;
                    break :blk .{ .string = truncated };
                } else raw_val;
                try obj.put("content", content_val);
                if (tr.is_error) try obj.put("is_error", .{ .bool = true });
                try arr.append(.{ .object = obj });
            },
            .image => {},
        }
    }
    return .{ .array = arr };
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
    // Accumulates text_delta fragments for the assistant message
    text_buf: std.ArrayListUnmanaged(u8) = .{},
    // Accumulates thinking_delta fragments for the assistant message
    thinking_buf: std.ArrayListUnmanaged(u8) = .{},

    const Phase = enum {
        start,
        streaming,
        tool_dispatch,
        waiting_for_external_tools,
        tool_collecting,
        yielding_result,
        done,
    };

    /// Flush any pending partial tool JSON into the last tracked tool's input.
    /// Called when the stream ends (message_stop or exhaustion) to handle cases
    /// where the model's output was truncated before content_block_stop.
    fn flushPendingToolInput(self: *QueryLoopIterator) void {
        if (self.tool_exec == null or self.tool_json_buf.items.len == 0) return;
        const parsed_input = json_mod.parse(self.params.allocator, self.tool_json_buf.items) catch null;
        if (parsed_input) |p| {
            const tracked = self.tool_exec.?.tracked.items;
            if (tracked.len > 0) {
                tracked[tracked.len - 1].block.input = p.value;
            }
        }
        self.tool_json_buf.clearRetainingCapacity();
    }

    /// Store the accumulated assistant message (thinking + text + tool_use blocks) in the message store.
    fn storeAssistantMessage(self: *QueryLoopIterator) void {
        const has_thinking = self.thinking_buf.items.len > 0;
        const has_text = self.text_buf.items.len > 0;
        const has_tools = self.tool_exec != null and self.tool_exec.?.tracked.items.len > 0;
        if (!has_thinking and !has_text and !has_tools) return;

        // Count content blocks needed
        var block_count: usize = 0;
        if (has_thinking) block_count += 1;
        if (has_text) block_count += 1;
        if (has_tools) block_count += self.tool_exec.?.tracked.items.len;

        // Allocate through the message store's arena so text / block ids /
        // content slice are all freed together with the store on engine.deinit.
        const msg_alloc = self.state.messages.allocator();
        const content = msg_alloc.alloc(message_mod.ContentBlock, block_count) catch return;
        var idx: usize = 0;

        // Thinking blocks MUST come before text (Anthropic API ordering).
        // Omitting these causes 400 errors with providers that emit thinking
        // (MiniMax, DeepSeek, etc.) because the conversation history is invalid.
        if (has_thinking) {
            const thinking_copy = msg_alloc.dupe(u8, self.thinking_buf.items) catch return;
            content[idx] = .{ .thinking = .{ .thinking = thinking_copy } };
            idx += 1;
        }

        if (has_text) {
            const text_copy = msg_alloc.dupe(u8, self.text_buf.items) catch return;
            content[idx] = .{ .text = text_copy };
            idx += 1;
        }

        if (has_tools) {
            for (self.tool_exec.?.tracked.items) |tracked| {
                // Dupe tracked ids into the store — the streaming iterator
                // that sourced these bytes may be torn down before deinit.
                const id_copy = msg_alloc.dupe(u8, tracked.block.id) catch return;
                const name_copy = msg_alloc.dupe(u8, tracked.block.name) catch return;
                content[idx] = .{ .tool_use = .{
                    .id = id_copy,
                    .name = name_copy,
                    .input = tracked.block.input,
                } };
                idx += 1;
            }
        }

        self.state.messages.append(.{ .assistant = .{
            .header = message_mod.Header.init(),
            .content = content,
        } }) catch {};

        self.thinking_buf.clearRetainingCapacity();
        self.text_buf.clearRetainingCapacity();
    }

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

                // Reset tool executor from previous turn so storeAssistantMessage
                // only records tool_use blocks from THIS turn's assistant response.
                if (self.tool_exec) |*exec| {
                    exec.deinit();
                    self.tool_exec = null;
                }

                // Convert MessageStore to ApiMessages (preserving tool_use / tool_result blocks).
                // Everything allocated for the api-message view — the slice itself and the
                // ObjectMap / Array / JsonValue chain inside each .content — is freed by the
                // turn arena below. Providers consume `api_messages` synchronously inside
                // stream_text (serializing to an HTTP body or ignoring it), so deinit'ing at
                // the end of this block is safe.
                var turn_arena = std.heap.ArenaAllocator.init(self.params.allocator);
                defer turn_arena.deinit();
                const turn_alloc = turn_arena.allocator();

                var api_messages: std.ArrayList(providers_types.ApiMessage) = .{};

                const messages_slice = self.state.messages.items();
                for (messages_slice) |msg| {
                    switch (msg) {
                        .user => |u| {
                            const content = contentBlocksToJson(turn_alloc, u.content) catch json_mod.JsonValue{ .string = "" };
                            api_messages.append(turn_alloc, .{
                                .role = "user",
                                .content = content,
                            }) catch {};
                        },
                        .assistant => |a| {
                            const content = contentBlocksToJson(turn_alloc, a.content) catch json_mod.JsonValue{ .string = "" };
                            api_messages.append(turn_alloc, .{
                                .role = "assistant",
                                .content = content,
                            }) catch {};
                        },
                        else => {},
                    }
                }

                // ── Microcompact: clear old tool results if context is too large ──
                // Inspired by Claude Code's microcompact strategy: estimate total
                // content size, and if it exceeds 80% of the provider's context
                // window, clear old tool_result content from oldest to newest
                // (keeping the most recent 2 tool results intact).
                const max_ctx_tokens = self.params.provider.vtable.max_context_tokens;
                const threshold_chars: usize = @as(usize, max_ctx_tokens) * 4 * 4 / 5; // 80% of max, 4 chars ≈ 1 token
                microcompactMessages(turn_alloc, api_messages.items, threshold_chars);

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
                    .{ .max_tokens = self.params.max_output_tokens, .system_prompt = self.params.system_prompt },
                );

                if (stream_result) |iter| {
                    self.stream_iter = iter;
                    self.phase = .streaming;
                    return nextEvent(ctx);
                } else |err| {
                    self.phase = .done;
                    // Surface the upstream HTTP error body if the provider
                    // captured one. Storage is owned by the provider and
                    // remains valid for the lifetime of this iterator.
                    const captured = self.params.provider.lastError();
                    const errors_slice: ?[]const []const u8 = if (captured) |msg| blk: {
                        const arr = self.params.allocator.alloc([]const u8, 1) catch break :blk null;
                        arr[0] = msg;
                        break :blk arr;
                    } else null;
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
                        .errors = errors_slice,
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

                        // Accumulate thinking for assistant message history
                        if (delta.@"type" == .thinking_delta) {
                            if (delta.text) |t| {
                                self.thinking_buf.appendSlice(self.params.allocator, t) catch {};
                            }
                        }

                        // Accumulate text for assistant message history
                        if (delta.@"type" == .text_delta) {
                            if (delta.text) |t| {
                                self.text_buf.appendSlice(self.params.allocator, t) catch {};
                            }
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
                            self.flushPendingToolInput();
                            self.storeAssistantMessage();
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
                // Stream exhausted (may be truncated by max_tokens)
                self.flushPendingToolInput();
                self.storeAssistantMessage();
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

                const msg_alloc = self.state.messages.allocator();
                while (exec.nextCompleted()) |completed| {
                    const id_copy = msg_alloc.dupe(u8, completed.block.id) catch continue;
                    const result_block = message_mod.ContentBlock{
                        .tool_result = .{
                            .tool_use_id = id_copy,
                            .content = if (completed.result) |r| r.data else .{ .string = completed.error_message orelse "unknown error" },
                            .is_error = completed.error_message != null,
                        },
                    };

                    const content = msg_alloc.alloc(message_mod.ContentBlock, 1) catch continue;
                    content[0] = result_block;
                    self.state.messages.append(.{ .user = .{
                        .header = message_mod.Header.init(),
                        .content = content,
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

// ---------------------------------------------------------------------------
// Microcompact — clear old tool results when context is too large
// ---------------------------------------------------------------------------

/// Estimate the character count of a JsonValue (rough, no full serialization).
fn estimateJsonChars(val: json_mod.JsonValue) usize {
    return switch (val) {
        .string => |s| s.len + 2, // quotes
        .integer => 8,
        .float => 12,
        .bool => 5,
        .null => 4,
        .array => |a| blk: {
            var sum: usize = 2; // []
            for (a.items) |item| sum += estimateJsonChars(item) + 1;
            break :blk sum;
        },
        .object => |o| blk: {
            var sum: usize = 2; // {}
            var it = o.iterator();
            while (it.next()) |entry| {
                sum += entry.key_ptr.len + 4 + estimateJsonChars(entry.value_ptr.*);
            }
            break :blk sum;
        },
        .number_string => |s| s.len,
    };
}

/// Clear old tool_result content when total context size exceeds threshold.
/// Preserves message structure and keeps the most recent 2 tool results intact.
/// This is modeled after Claude Code's microcompact strategy.
fn microcompactMessages(
    allocator: std.mem.Allocator,
    messages: []providers_types.ApiMessage,
    threshold_chars: usize,
) void {
    // Estimate total context size
    var total_chars: usize = 0;
    for (messages) |msg| {
        total_chars += msg.role.len + estimateJsonChars(msg.content);
    }

    if (total_chars <= threshold_chars) return;

    std.debug.print(
        "[agent-microcompact] context {d} chars exceeds threshold {d}, clearing old tool results\n",
        .{ total_chars, threshold_chars },
    );

    // Find all tool_result content blocks (in user messages with array content)
    // and clear from oldest to newest, keeping the last 2 intact.
    const KEEP_RECENT: usize = 2;
    const PosEntry = struct { msg_idx: usize, block_idx: usize, chars: usize };
    const MAX_POSITIONS: usize = 64;
    var positions_buf: [MAX_POSITIONS]PosEntry = undefined;
    var count: usize = 0;

    for (messages, 0..) |msg, mi| {
        if (!std.mem.eql(u8, msg.role, "user")) continue;
        if (msg.content != .array) continue;
        for (msg.content.array.items, 0..) |item, bi| {
            if (item != .object) continue;
            const type_val = item.object.get("type") orelse continue;
            if (type_val != .string) continue;
            if (!std.mem.eql(u8, type_val.string, "tool_result")) continue;
            const content_val = item.object.get("content") orelse continue;
            const chars = estimateJsonChars(content_val);
            if (count < MAX_POSITIONS) {
                positions_buf[count] = .{ .msg_idx = mi, .block_idx = bi, .chars = chars };
                count += 1;
            }
        }
    }

    if (count <= KEEP_RECENT) return;

    // Clear old tool results (keep last KEEP_RECENT)
    var freed: usize = 0;
    for (positions_buf[0 .. count - KEEP_RECENT]) |pos| {
        // Replace content with a compact placeholder
        const placeholder = std.fmt.allocPrint(
            allocator,
            "[cleared \u{2014} {d} chars]",
            .{pos.chars},
        ) catch "[cleared]";
        messages[pos.msg_idx].content.array.items[pos.block_idx].object.put(
            "content",
            json_mod.JsonValue{ .string = placeholder },
        ) catch {};
        freed += pos.chars;
    }

    std.debug.print(
        "[agent-microcompact] cleared {d}/{d} tool results, freed ~{d} chars\n",
        .{ count - KEEP_RECENT, count, freed },
    );
}

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

test "contentBlocksToJson single text block returns string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const blocks = [_]message_mod.ContentBlock{.{ .text = "hello world" }};
    const result = try contentBlocksToJson(alloc, &blocks);
    try std.testing.expectEqualStrings("hello world", result.string);
}

test "contentBlocksToJson empty blocks returns empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const blocks = [_]message_mod.ContentBlock{};
    const result = try contentBlocksToJson(alloc, &blocks);
    try std.testing.expectEqualStrings("", result.string);
}

test "contentBlocksToJson multiple blocks returns array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const blocks = [_]message_mod.ContentBlock{
        .{ .text = "I will read the file." },
        .{ .tool_use = .{
            .id = "toolu_123",
            .name = "ReadFile",
            .input = .null,
        } },
    };
    const result = try contentBlocksToJson(alloc, &blocks);
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);

    // First element: text block
    const text_obj = result.array.items[0].object;
    try std.testing.expectEqualStrings("text", json_mod.getString(.{ .object = text_obj }, "type").?);

    // Second element: tool_use block
    const tool_obj = result.array.items[1].object;
    try std.testing.expectEqualStrings("tool_use", json_mod.getString(.{ .object = tool_obj }, "type").?);
    try std.testing.expectEqualStrings("toolu_123", json_mod.getString(.{ .object = tool_obj }, "id").?);
}

test "contentBlocksToJson tool_result block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const blocks = [_]message_mod.ContentBlock{
        .{ .tool_result = .{
            .tool_use_id = "toolu_456",
            .content = .{ .string = "file contents here" },
            .is_error = false,
        } },
        .{ .tool_result = .{
            .tool_use_id = "toolu_789",
            .content = .{ .string = "error: not found" },
            .is_error = true,
        } },
    };
    const result = try contentBlocksToJson(alloc, &blocks);
    try std.testing.expect(result == .array);
    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);

    // Check is_error on second result
    const err_obj = result.array.items[1].object;
    try std.testing.expect(json_mod.getBool(.{ .object = err_obj }, "is_error").?);
}

test "queryLoop streams text with MockProvider" {
    const allocator = std.testing.allocator;
    const testing_mod = @import("testing.zig");

    const deltas = [_]streaming_events.StreamDelta{
        .{ .@"type" = .message_start },
        .{ .@"type" = .text_delta, .text = "Hello" },
        .{ .@"type" = .text_delta, .text = " World" },
        .{ .@"type" = .message_stop },
    };
    var mock = testing_mod.MockProvider.init(allocator, &.{.{ .deltas = &deltas }});
    var provider_iface = mock.provider();

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
    var sw = @import("context/sliding_window.zig").SlidingWindowStrategy.init(20);
    var strategy = sw.strategy();

    // Seed a user message
    const text_block = try msgs.allocator().alloc(message_mod.ContentBlock, 1);
    text_block[0] = .{ .text = "Hi" };
    try msgs.append(.{ .user = .{ .header = message_mod.Header.init(), .content = text_block } });

    var loop_iter = queryLoop(.{
        .allocator = allocator,
        .provider = &provider_iface,
        .tool_registry = &reg,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hooks,
        .session = &session,
        .abort = &abort,
        .context_strategy = &strategy,
        .file_cache = &cache,
        .max_turns = 5,
    }, &msgs);
    defer {
        if (loop_iter.tool_exec) |*exec| exec.deinit();
        loop_iter.text_buf.deinit(allocator);
        loop_iter.tool_json_buf.deinit(allocator);
    }

    var iter = loop_iter.toEventIterator();

    // Collect events
    var saw_text = false;
    var saw_result = false;
    while (iter.next()) |event| {
        switch (event) {
            .stream_event => |delta| {
                if (delta.text != null) saw_text = true;
            },
            .result => |r| {
                saw_result = true;
                try std.testing.expect(!r.is_error);
                try std.testing.expectEqualStrings("success", r.subtype);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_text);
    try std.testing.expect(saw_result);
}

test "queryLoop dispatches tool calls with MockProvider" {
    // Use an arena because the query loop's tool-input JSON parsing intentionally
    // keeps the Parsed arena alive (tool inputs reference it).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const testing_mod = @import("testing.zig");

    // Simulate: model calls FakeTool, then produces a final text response
    const turn1_deltas = [_]streaming_events.StreamDelta{
        .{ .@"type" = .message_start },
        .{ .@"type" = .content_block_start, .tool_use_id = "t1", .tool_name = "FakeTool" },
        .{ .@"type" = .tool_use_delta, .partial_json = "{}" },
        .{ .@"type" = .content_block_stop },
        .{ .@"type" = .message_stop },
    };
    const turn2_deltas = [_]streaming_events.StreamDelta{
        .{ .@"type" = .message_start },
        .{ .@"type" = .text_delta, .text = "Done!" },
        .{ .@"type" = .message_stop },
    };
    var mock = testing_mod.MockProvider.init(allocator, &.{
        .{ .deltas = &turn1_deltas },
        .{ .deltas = &turn2_deltas },
    });
    var provider_iface = mock.provider();

    var msgs = message_mod.MessageStore.init(allocator);
    var abort = abort_mod.AbortController{};
    var hooks = hook_mod.HookRunner.init(allocator);
    var session = session_mod.Session.init(allocator);
    var perm_ctx = perm.PermissionContext{ .mode = .bypass };
    var cache = file_cache_mod.FileStateCache.init(allocator, 10, 1024);
    var reg = tools_reg.ToolRegistry.init(allocator);

    var fake = testing_mod.FakeTool{};
    const fake_tool = @import("tool.zig").buildTool(testing_mod.FakeTool, &fake);
    try reg.register(fake_tool);

    var sw = @import("context/sliding_window.zig").SlidingWindowStrategy.init(20);
    var strategy = sw.strategy();

    const text_block = try msgs.allocator().alloc(message_mod.ContentBlock, 1);
    text_block[0] = .{ .text = "Call FakeTool" };
    try msgs.append(.{ .user = .{ .header = message_mod.Header.init(), .content = text_block } });

    var loop_iter = queryLoop(.{
        .allocator = allocator,
        .provider = &provider_iface,
        .tool_registry = &reg,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hooks,
        .session = &session,
        .abort = &abort,
        .context_strategy = &strategy,
        .file_cache = &cache,
        .max_turns = 10,
    }, &msgs);

    var iter = loop_iter.toEventIterator();

    var saw_done_text = false;
    var saw_result = false;
    while (iter.next()) |event| {
        switch (event) {
            .stream_event => |delta| {
                if (delta.text) |t| {
                    if (std.mem.eql(u8, t, "Done!")) saw_done_text = true;
                }
            },
            .result => |r| {
                saw_result = true;
                try std.testing.expect(!r.is_error);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_done_text);
    try std.testing.expect(saw_result);
    try std.testing.expectEqual(@as(u32, 1), fake.call_count);
}

test "queryLoop yields provider error" {
    const allocator = std.testing.allocator;
    const testing_mod = @import("testing.zig");

    // Empty responses → ServerError on first call
    var mock = testing_mod.MockProvider.init(allocator, &.{});
    var provider_iface = mock.provider();

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
    var sw = @import("context/sliding_window.zig").SlidingWindowStrategy.init(20);
    var strategy = sw.strategy();

    const text_block = try msgs.allocator().alloc(message_mod.ContentBlock, 1);
    text_block[0] = .{ .text = "Hi" };
    try msgs.append(.{ .user = .{ .header = message_mod.Header.init(), .content = text_block } });

    var loop_iter = queryLoop(.{
        .allocator = allocator,
        .provider = &provider_iface,
        .tool_registry = &reg,
        .permission_ctx = &perm_ctx,
        .hook_runner = &hooks,
        .session = &session,
        .abort = &abort,
        .context_strategy = &strategy,
        .file_cache = &cache,
    }, &msgs);
    defer {
        if (loop_iter.tool_exec) |*exec| exec.deinit();
        loop_iter.text_buf.deinit(allocator);
        loop_iter.tool_json_buf.deinit(allocator);
    }

    var iter = loop_iter.toEventIterator();
    const event = iter.next().?;
    try std.testing.expectEqualStrings("error_server", event.result.subtype);
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
