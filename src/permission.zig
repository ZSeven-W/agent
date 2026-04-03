//! Permission types and 7-step evaluation chain for the agent SDK.
//!
//! Implements the same decision chain used by Claude Code:
//!   1a. Deny rule  → DENY
//!   1b. Ask rule   → ASK
//!   1c. Tool-specific check callback (deny / bypass-immune ask / safety_check respected)
//!   2a. Bypass mode → ALLOW
//!   2b. Whole-tool allow rule → ALLOW
//!   3.  Default → ASK
//!   4.  dont_ask mode → convert ASK to DENY

const std = @import("std");
const json = @import("json.zig");

pub const JsonValue = json.JsonValue;

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

pub const PermissionMode = enum {
    default,
    accept_edits,
    bypass,
    plan,
    dont_ask,
    auto,
};

pub const PermissionBehavior = enum {
    allow,
    deny,
    ask,
};

pub const RuleSource = enum {
    policy,
    user,
    project,
    local,
    flag,
    cli_arg,
    command,
    session,
};

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------

pub const PermissionRule = struct {
    source: RuleSource,
    behavior: PermissionBehavior,
    tool_name: []const u8,
    /// null means the rule applies to the whole tool (not a specific input pattern).
    rule_content: ?[]const u8,
};

pub const DecisionReason = union(enum) {
    rule: PermissionRule,
    mode: PermissionMode,
    safety_check: struct {
        reason: []const u8,
        classifier_approvable: bool,
    },
    other: []const u8,
};

pub const AllowDecision = struct {
    /// Optionally an updated/sanitised input to pass on to the tool.
    updated_input: ?JsonValue,
    reason: DecisionReason,
};

pub const AskDecision = struct {
    message_text: []const u8,
    reason: ?DecisionReason,
};

pub const DenyDecision = struct {
    message_text: []const u8,
    reason: DecisionReason,
};

pub const PermissionDecision = union(enum) {
    allow: AllowDecision,
    ask: AskDecision,
    deny: DenyDecision,
};

pub const PermissionContext = struct {
    mode: PermissionMode = .default,
    always_allow_rules: []const PermissionRule = &.{},
    always_deny_rules: []const PermissionRule = &.{},
    always_ask_rules: []const PermissionRule = &.{},
    is_bypass_available: bool = false,
    is_auto_available: bool = false,
    should_avoid_prompts: bool = false,
};

// ---------------------------------------------------------------------------
// Callback type
// ---------------------------------------------------------------------------

/// Optional per-tool check.  May return allow, ask, or deny.
pub const ToolPermissionCheckFn = *const fn (JsonValue) PermissionDecision;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Find the first rule in `rules` whose `tool_name` matches and that is a
/// whole-tool rule (`rule_content == null`).
pub fn findRuleForTool(rules: []const PermissionRule, tool_name: []const u8) ?PermissionRule {
    for (rules) |rule| {
        if (rule.rule_content == null and std.mem.eql(u8, rule.tool_name, tool_name)) {
            return rule;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// 7-step evaluation
// ---------------------------------------------------------------------------

pub fn evaluatePermission(
    tool_name: []const u8,
    input: JsonValue,
    ctx: PermissionContext,
    tool_check: ?ToolPermissionCheckFn,
) PermissionDecision {
    // Step 1a — deny rule blocks immediately.
    if (findRuleForTool(ctx.always_deny_rules, tool_name)) |rule| {
        return .{ .deny = .{
            .message_text = "Tool use denied by rule.",
            .reason = .{ .rule = rule },
        } };
    }

    // Step 1b — ask rule triggers confirmation.
    if (findRuleForTool(ctx.always_ask_rules, tool_name)) |rule| {
        return .{ .ask = .{
            .message_text = "Tool use requires confirmation.",
            .reason = .{ .rule = rule },
        } };
    }

    // Step 1c — tool-specific callback.
    if (tool_check) |check_fn| {
        const result = check_fn(input);
        switch (result) {
            .deny => return result,
            .ask => return result,
            .allow => {}, // fall through — bypass/allow-rule checks still apply
        }
    }

    // Step 2a — bypass mode allows everything.
    if (ctx.mode == .bypass) {
        return .{ .allow = .{
            .updated_input = null,
            .reason = .{ .mode = .bypass },
        } };
    }

    // Step 2b — whole-tool allow rule.
    if (findRuleForTool(ctx.always_allow_rules, tool_name)) |rule| {
        return .{ .allow = .{
            .updated_input = null,
            .reason = .{ .rule = rule },
        } };
    }

    // Step 3 — default: ask.
    const ask_decision = PermissionDecision{ .ask = .{
        .message_text = "Permission required.",
        .reason = null,
    } };

    // Step 4 — dont_ask converts ask to deny.
    if (ctx.mode == .dont_ask) {
        return .{ .deny = .{
            .message_text = "Permission required but prompting is disabled.",
            .reason = .{ .mode = .dont_ask },
        } };
    }

    return ask_decision;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn makeCtx(
    mode: PermissionMode,
    allow_rules: []const PermissionRule,
    deny_rules: []const PermissionRule,
    ask_rules: []const PermissionRule,
) PermissionContext {
    return .{
        .mode = mode,
        .always_allow_rules = allow_rules,
        .always_deny_rules = deny_rules,
        .always_ask_rules = ask_rules,
        .is_bypass_available = false,
        .is_auto_available = false,
        .should_avoid_prompts = false,
    };
}

const null_input = JsonValue{ .null = {} };

test "Step 1a: deny rule blocks tool" {
    const deny_rule = PermissionRule{
        .source = .user,
        .behavior = .deny,
        .tool_name = "Bash",
        .rule_content = null,
    };
    const ctx = makeCtx(.default, &.{}, &.{deny_rule}, &.{});
    const decision = evaluatePermission("Bash", null_input, ctx, null);
    try testing.expect(decision == .deny);
}

test "Step 2a: bypass mode allows everything" {
    const ctx = makeCtx(.bypass, &.{}, &.{}, &.{});
    const decision = evaluatePermission("Bash", null_input, ctx, null);
    try testing.expect(decision == .allow);
}

test "Step 2b: allow rule allows tool" {
    const allow_rule = PermissionRule{
        .source = .user,
        .behavior = .allow,
        .tool_name = "Read",
        .rule_content = null,
    };
    const ctx = makeCtx(.default, &.{allow_rule}, &.{}, &.{});
    const decision = evaluatePermission("Read", null_input, ctx, null);
    try testing.expect(decision == .allow);
}

test "Step 3: default falls through to ask" {
    const ctx = makeCtx(.default, &.{}, &.{}, &.{});
    const decision = evaluatePermission("Write", null_input, ctx, null);
    try testing.expect(decision == .ask);
}

test "Step 4: dont_ask converts ask to deny" {
    const ctx = makeCtx(.dont_ask, &.{}, &.{}, &.{});
    const decision = evaluatePermission("Write", null_input, ctx, null);
    try testing.expect(decision == .deny);
}

test "deny rule takes priority over allow rule" {
    const deny_rule = PermissionRule{
        .source = .policy,
        .behavior = .deny,
        .tool_name = "Bash",
        .rule_content = null,
    };
    const allow_rule = PermissionRule{
        .source = .user,
        .behavior = .allow,
        .tool_name = "Bash",
        .rule_content = null,
    };
    const ctx = makeCtx(.default, &.{allow_rule}, &.{deny_rule}, &.{});
    const decision = evaluatePermission("Bash", null_input, ctx, null);
    try testing.expect(decision == .deny);
}
