//! Notification policy from ~/.config/colm/cmux.json and project cmux.json.
const std = @import("std");
const xdg = @import("../../os/xdg.zig");
const feature_store = @import("feature_store.zig");

pub const TurnComplete = enum { always, when_idle, never };
pub const Category = enum { generic, @"turn-complete", @"needs-permission", @"idle-reminder" };

pub const Effects = struct {
    record: bool = true,
    mark_unread: bool = true,
    reorder_workspace: bool = true,
    desktop: bool = true,
    pane_flash: bool = true,
};

pub const Decision = struct {
    effects: Effects = .{},
    drop: bool = false,
};

pub const Context = struct {
    workspace_id: []const u8,
    surface_id: ?[]const u8,
    title: []const u8,
    subtitle: []const u8,
    body: []const u8,
    cwd: ?[]const u8,
    app_focused: bool,
    agent_kind: ?[]const u8,
    category: Category,
    is_subagent: bool,
    pending: bool,
};

pub fn classify(title: []const u8, subtitle: []const u8, body: []const u8, explicit: ?[]const u8) Category {
    if (explicit) |value| {
        if (std.mem.eql(u8, value, "turn-complete")) return .@"turn-complete";
        if (std.mem.eql(u8, value, "needs-permission")) return .@"needs-permission";
        if (std.mem.eql(u8, value, "idle-reminder")) return .@"idle-reminder";
    }
    if (contains(title, "idle") or contains(subtitle, "idle") or contains(body, "idle reminder"))
        return .@"idle-reminder";
    if (contains(title, "needs input") or contains(subtitle, "needs input") or
        contains(body, "needs input") or contains(body, "permission") or contains(subtitle, "waiting"))
        return .@"needs-permission";
    if (contains(subtitle, "completed") or contains(body, "task completed") or contains(title, "done"))
        return .@"turn-complete";
    return .generic;
}

pub fn isSubagent(title: []const u8, subtitle: []const u8, body: []const u8, explicit: bool) bool {
    return explicit or contains(title, "subagent") or contains(subtitle, "subagent") or contains(body, "subagent");
}

pub fn decide(alloc: std.mem.Allocator, ctx: Context) Decision {
    var decision: Decision = .{};
    if (ctx.app_focused) {
        decision.effects.desktop = false;
        decision.effects.mark_unread = false;
    }
    const policy = load(alloc, ctx.cwd) catch Policy{};
    if (policy.suppress_subagent and ctx.is_subagent and ctx.category == .@"turn-complete") {
        return .{ .drop = true };
    }
    switch (ctx.category) {
        .@"turn-complete" => switch (policy.turn_complete) {
            .always => {
                decision.effects.desktop = true;
                decision.effects.mark_unread = true;
            },
            .when_idle => {},
            .never => {
                decision.effects.desktop = false;
                decision.effects.pane_flash = false;
            },
        },
        else => {},
    }
    applyHooks(alloc, ctx, policy, &decision);
    return decision;
}

const Hook = struct {
    id: []const u8,
    command: []const u8,
};

const Policy = struct {
    turn_complete: TurnComplete = .when_idle,
    suppress_subagent: bool = true,
    hooks: []const Hook = &.{},
};

fn load(alloc: std.mem.Allocator, cwd: ?[]const u8) !Policy {
    var policy: Policy = .{};
    if (xdg.config(alloc, .{ .subdir = "colm" })) |dir| {
        defer alloc.free(dir);
        const path = try std.fs.path.join(alloc, &.{ dir, "cmux.json" });
        mergeFile(alloc, path, &policy, true);
    } else |_| {}
    if (xdg.config(alloc, .{ .subdir = "cmux" })) |dir| {
        defer alloc.free(dir);
        const path = try std.fs.path.join(alloc, &.{ dir, "cmux.json" });
        mergeFile(alloc, path, &policy, true);
    } else |_| {}
    if (cwd) |dir| {
        const trusted = projectTrusted(alloc, dir);
        const nested = try std.fs.path.join(alloc, &.{ dir, ".cmux", "cmux.json" });
        mergeFile(alloc, nested, &policy, trusted);
        const flat = try std.fs.path.join(alloc, &.{ dir, "cmux.json" });
        mergeFile(alloc, flat, &policy, trusted);
    }
    return policy;
}

fn projectTrusted(alloc: std.mem.Allocator, cwd: []const u8) bool {
    const key = feature_store.trustKey(alloc, cwd) catch return false;
    _ = feature_store.get(alloc, "trust", &key) catch return false;
    return true;
}

fn mergeFile(alloc: std.mem.Allocator, path: []const u8, policy: *Policy, run_hooks: bool) void {
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always }) catch return;
    if (parsed != .object) return;
    if (parsed.object.get("automation")) |automation| {
        if (automation == .object) {
            if (automation.object.get("suppressSubagentNotifications")) |value| {
                if (value == .bool) policy.suppress_subagent = value.bool;
            }
        }
    }
    const notifications = parsed.object.get("notifications") orelse return;
    if (notifications != .object) return;
    if (notifications.object.get("turnComplete")) |value| {
        if (value == .string) {
            if (std.mem.eql(u8, value.string, "always")) policy.turn_complete = .always;
            if (std.mem.eql(u8, value.string, "never")) policy.turn_complete = .never;
            if (std.mem.eql(u8, value.string, "whenIdle") or std.mem.eql(u8, value.string, "when_idle"))
                policy.turn_complete = .when_idle;
        }
    }
    if (!run_hooks) return;
    const hooks = notifications.object.get("hooks") orelse return;
    if (hooks != .array) return;
    var list: std.ArrayList(Hook) = .empty;
    list.appendSlice(alloc, policy.hooks) catch return;
    for (hooks.array.items) |item| {
        if (item != .object) continue;
        const command = if (item.object.get("command")) |value| if (value == .string) value.string else continue else continue;
        if (command.len == 0 or command.len > 4096) continue;
        const id = if (item.object.get("id")) |value| if (value == .string) value.string else "hook" else "hook";
        list.append(alloc, .{ .id = id, .command = command }) catch continue;
    }
    policy.hooks = list.items;
}

fn applyHooks(alloc: std.mem.Allocator, ctx: Context, policy: Policy, decision: *Decision) void {
    for (policy.hooks) |hook| {
        const payload = std.fmt.allocPrint(alloc,
            "{{\"version\":1,\"effects\":{{\"desktop\":{s},\"paneFlash\":{s}}}}}",
            .{
                if (decision.effects.desktop) "true" else "false",
                if (decision.effects.pane_flash) "true" else "false",
            },
        ) catch continue;
        const output = runHook(alloc, hook.command, payload, ctx) catch continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, output, .{}) catch continue;
        if (parsed != .object) continue;
        if (parsed.object.get("effects")) |effects| {
            if (effects != .object) continue;
            if (effects.object.get("desktop")) |value| {
                if (value == .bool) decision.effects.desktop = value.bool;
            }
            if (effects.object.get("paneFlash")) |value| {
                if (value == .bool) decision.effects.pane_flash = value.bool;
            }
            if (effects.object.get("record")) |value| {
                if (value == .bool) decision.effects.record = value.bool;
            }
            if (effects.object.get("markUnread")) |value| {
                if (value == .bool) decision.effects.mark_unread = value.bool;
            }
            if (effects.object.get("reorderWorkspace")) |value| {
                if (value == .bool) decision.effects.reorder_workspace = value.bool;
            }
        }
    }
}

fn runHook(alloc: std.mem.Allocator, command: []const u8, payload: []const u8, ctx: Context) ![]u8 {
    const cmd_z = try alloc.dupeZ(u8, command);
    var child = std.process.Child.init(&.{ "timeout", "2", "/bin/sh", "-c", cmd_z }, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    var env = try std.process.getEnvMap(alloc);
    try env.put("CMUX_NOTIFICATION_TITLE", ctx.title);
    try env.put("CMUX_NOTIFICATION_SUBTITLE", ctx.subtitle);
    try env.put("CMUX_NOTIFICATION_BODY", ctx.body);
    try env.put("CMUX_NOTIFICATION_AGENT_KIND", ctx.agent_kind orelse "");
    try env.put("CMUX_NOTIFICATION_AGENT_CATEGORY", @tagName(ctx.category));
    try env.put("CMUX_NOTIFICATION_AGENT_IS_SUBAGENT", if (ctx.is_subagent) "1" else "0");
    child.env_map = &env;
    try child.spawn();
    if (child.stdin) |stdin| {
        stdin.writeAll(payload) catch {};
        stdin.close();
        child.stdin = null;
    }
    const stdout = child.stdout orelse return error.NoStdout;
    const output = try stdout.readToEndAlloc(alloc, 64 * 1024);
    _ = child.wait() catch {};
    return output;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

pub const CommandSpec = struct { title: []const u8, command: []const u8 };
pub const SidebarSpec = struct { title: []const u8, url: []const u8 };

pub fn loadCustomCommands(alloc: std.mem.Allocator, cwd: ?[]const u8) []CommandSpec {
    var list: std.ArrayList(CommandSpec) = .empty;
    const paths = collectConfigPaths(alloc, cwd);
    for (paths) |path| appendCommands(alloc, path, &list);
    return list.items;
}


fn collectConfigPaths(alloc: std.mem.Allocator, cwd: ?[]const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    if (xdg.config(alloc, .{ .subdir = "colm" })) |dir| {
        if (std.fs.path.join(alloc, &.{ dir, "cmux.json" })) |path|
            list.append(alloc, path) catch {}
        else |_| {}
    } else |_| {}
    if (cwd) |dir| {
        if (std.fs.path.join(alloc, &.{ dir, ".cmux", "cmux.json" })) |path|
            list.append(alloc, path) catch {}
        else |_| {}
        if (std.fs.path.join(alloc, &.{ dir, "cmux.json" })) |path|
            list.append(alloc, path) catch {}
        else |_| {}
    }
    return list.items;
}


fn appendCommands(alloc: std.mem.Allocator, path: []const u8, list: *std.ArrayList(CommandSpec)) void {

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always }) catch return;
    if (parsed != .object) return;
    const commands = parsed.object.get("commands") orelse parsed.object.get("customCommands") orelse return;
    if (commands != .array) return;
    for (commands.array.items) |item| {
        if (item != .object) continue;
        const title = if (item.object.get("title") orelse item.object.get("name")) |value|
            if (value == .string) value.string else continue
        else
            continue;
        const command = if (item.object.get("command")) |value|
            if (value == .string) value.string else continue
        else
            continue;
        if (title.len == 0 or command.len == 0) continue;
        list.append(alloc, .{ .title = title, .command = command }) catch continue;
    }
}

pub fn runAutomations(alloc: std.mem.Allocator, event: []const u8, title: []const u8, body: []const u8) void {
    const dir = xdg.config(alloc, .{ .subdir = "colm" }) catch return;
    const path = std.fs.path.join(alloc, &.{ dir, "automations.json" }) catch return;
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always }) catch return;
    const items = if (parsed == .object)
        (parsed.object.get("automations") orelse return)
    else
        parsed;
    if (items != .array) return;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const when = if (item.object.get("when")) |value| if (value == .string) value.string else continue else continue;
        if (!std.mem.eql(u8, when, event) and !std.mem.eql(u8, when, "*")) continue;
        const action = if (item.object.get("action")) |value| if (value == .string) value.string else "run" else "run";
        if (!std.mem.eql(u8, action, "run")) continue;
        const command = if (item.object.get("command")) |value| if (value == .string) value.string else continue else continue;
        if (command.len == 0 or command.len > 4096) continue;
        const cmd_z = alloc.dupeZ(u8, command) catch continue;
        var child = std.process.Child.init(&.{ "timeout", "2", "/bin/sh", "-c", cmd_z }, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        var env = std.process.getEnvMap(alloc) catch continue;
        env.put("COLM_EVENT", event) catch {};
        env.put("COLM_TITLE", title) catch {};
        env.put("COLM_BODY", body) catch {};
        child.env_map = &env;
        child.spawn() catch continue;
        _ = child.wait() catch {};
    }
}

pub fn loadSidebars(alloc: std.mem.Allocator, cwd: ?[]const u8) []SidebarSpec {
    var list: std.ArrayList(SidebarSpec) = .empty;
    const paths = collectConfigPaths(alloc, cwd);
    for (paths) |path| {
        const bytes = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always }) catch continue;
        if (parsed != .object) continue;
        const sidebars = parsed.object.get("customSidebars") orelse parsed.object.get("sidebars") orelse continue;
        if (sidebars != .array) continue;
        for (sidebars.array.items) |item| {
            if (item != .object) continue;
            const title = if (item.object.get("title") orelse item.object.get("id")) |value|
                if (value == .string) value.string else continue
            else
                continue;
            const url = if (item.object.get("url")) |value|
                if (value == .string) value.string else continue
            else
                continue;
            if (title.len == 0 or url.len == 0) continue;
            list.append(alloc, .{ .title = title, .url = url }) catch continue;
        }
    }
    return list.items;
}

