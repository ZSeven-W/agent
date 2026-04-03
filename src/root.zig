//! Agent SDK — AI agent framework for multi-turn LLM conversations with tool support.
//!
//! Core architecture replicated from claude-code-main.

pub const json = @import("json.zig");
pub const uuid = @import("uuid.zig");
pub const message = @import("message.zig");
pub const streaming = @import("streaming.zig");
pub const file_cache = @import("file_cache.zig");
pub const abort = @import("abort.zig");
pub const permission = @import("permission.zig");
pub const hook = @import("hook.zig");
pub const session = @import("session.zig");
pub const tool = @import("tool.zig");
pub const tools = @import("tools.zig");
pub const http = @import("http.zig");
pub const providers = @import("providers.zig");
pub const context = @import("context.zig");
pub const query = @import("query.zig");
pub const query_engine = @import("query_engine.zig");
pub const QueryEngine = query_engine.QueryEngine;
pub const sub_agent = @import("sub_agent.zig");
pub const SubAgent = sub_agent.SubAgent;
pub const team = @import("team.zig");
pub const Team = team.Team;
pub const delegate = @import("tools/delegate.zig");
pub const compact = @import("compact.zig");
pub const external_tool_queue = @import("external_tool_queue.zig");
pub const task = @import("task.zig");
pub const swarm = @import("swarm.zig");
pub const testing = @import("testing.zig");
pub const buildTool = tool.buildTool;

test {
    _ = json;
    _ = uuid;
    _ = message;
    _ = streaming;
    _ = file_cache;
    _ = abort;
    _ = permission;
    _ = hook;
    _ = session;
    _ = tool;
    _ = tools;
    _ = http;
    _ = providers;
    _ = context;
    _ = query;
    _ = query_engine;
    _ = sub_agent;
    _ = team;
    _ = delegate;
    _ = compact;
    _ = external_tool_queue;
    _ = task;
    _ = swarm;
    _ = testing;
}
