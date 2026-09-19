const std = @import("std");
const xdg = @import("../../os/xdg.zig");

pub const Kind = enum { prompt, rule };
const filename = "agents-v1.json";
const max_bytes = 4 * 1024 * 1024;

fn section(kind: Kind) []const u8 {
    return if (kind == .prompt) "prompts" else "rules";
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    return true;
}

fn empty(alloc: std.mem.Allocator) !std.json.Value {
    var root: std.json.ObjectMap = .init(alloc);
    try root.put("version", .{ .integer = 1 });
    try root.put("prompts", .{ .object = .init(alloc) });
    try root.put("rules", .{ .object = .init(alloc) });
    return .{ .object = root };
}

fn load(alloc: std.mem.Allocator) !std.json.Value {
    const path = try xdg.config(alloc, .{ .subdir = "colm" });
    defer alloc.free(path);
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return empty(alloc),
        else => return err,
    };
    defer dir.close();
    var file = dir.openFile(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return empty(alloc),
        else => return err,
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(alloc, max_bytes);
    defer alloc.free(bytes);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
    if (value != .object or value.object.get("version") == null or
        value.object.get("version").? != .integer or value.object.get("version").?.integer != 1 or
        value.object.get("prompts") == null or value.object.get("prompts").? != .object or
        value.object.get("rules") == null or value.object.get("rules").? != .object)
        return error.InvalidAgentStore;
    return value;
}

fn save(alloc: std.mem.Allocator, value: std.json.Value) !void {
    const path = try xdg.config(alloc, .{ .subdir = "colm" });
    defer alloc.free(path);
    try std.fs.cwd().makePath(path);
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    var buffer: [4096]u8 = undefined;
    var atomic = try dir.atomicFile(filename, .{ .mode = 0o600, .write_buffer = &buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.finish();
}

pub fn list(alloc: std.mem.Allocator, kind: Kind) !std.json.Value {
    const value = try load(alloc);
    const values = value.object.get(section(kind)).?.object;
    var result: std.array_list.Managed(std.json.Value) = .init(alloc);
    var names: std.array_list.Managed([]const u8) = .init(alloc);
    var iterator = values.iterator();
    while (iterator.next()) |entry| try names.append(entry.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    for (names.items) |name| try result.append(.{ .string = name });
    return .{ .array = result };
}

pub fn get(alloc: std.mem.Allocator, kind: Kind, name: []const u8) ![]const u8 {
    if (!validName(name)) return error.InvalidName;
    const value = try load(alloc);
    const item = value.object.get(section(kind)).?.object.get(name) orelse return error.NotFound;
    if (item != .string) return error.InvalidAgentStore;
    return item.string;
}

pub fn set(alloc: std.mem.Allocator, kind: Kind, name: []const u8, text: []const u8) !void {
    if (!validName(name)) return error.InvalidName;
    if (text.len == 0 or text.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    var value = try load(alloc);
    try value.object.getPtr(section(kind)).?.object.put(name, .{ .string = text });
    try save(alloc, value);
}

pub fn remove(alloc: std.mem.Allocator, kind: Kind, name: []const u8) !void {
    if (!validName(name)) return error.InvalidName;
    var value = try load(alloc);
    if (!value.object.getPtr(section(kind)).?.object.swapRemove(name)) return error.NotFound;
    try save(alloc, value);
}

const providers = [_][]const u8{
    "claude",  "codex",     "grok",    "opencode", "cursor", "gemini",
    "copilot", "codebuddy", "factory", "qoder",    "kimi",   "pi",
    "omp",     "campfire",  "rovo",    "omo",      "omx",    "omc",
};

fn providerName(provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "cursor-agent")) return "cursor";
    if (std.mem.eql(u8, provider, "droid")) return "factory";
    if (std.mem.eql(u8, provider, "qodercli")) return "qoder";
    if (std.mem.eql(u8, provider, "rovodev") or std.mem.eql(u8, provider, "acli")) return "rovo";
    inline for (providers) |name|
        if (std.mem.eql(u8, provider, name)) return name;
    return null;
}

fn providerBinary(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "cursor")) return "cursor-agent";
    if (std.mem.eql(u8, name, "factory")) return "droid";
    if (std.mem.eql(u8, name, "qoder")) return "qodercli";
    if (std.mem.eql(u8, name, "rovo")) return "acli";
    return name;
}

fn onPath(alloc: std.mem.Allocator, binary: []const u8) bool {
    const path = std.posix.getenv("PATH") orelse return false;
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(alloc, &.{ dir, binary }) catch continue;
        defer alloc.free(candidate);
        std.fs.accessAbsolute(candidate, .{}) catch continue;
        return true;
    }
    return false;
}

/// omp discovers hook factories in `<agent dir>/hooks/post/*.ts`; the agent
/// directory defaults to `~/.omp/agent` and honors PI_CODING_AGENT_DIR.
const omp_hook_filename = "colm-agent-bridge.ts";

fn ompHooksDir(alloc: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("PI_CODING_AGENT_DIR")) |value| {
        if (value.len > 0) return std.fs.path.join(alloc, &.{ value, "hooks", "post" });
    }
    const home = std.posix.getenv("HOME") orelse return error.MissingHomeDirectory;
    return std.fs.path.join(alloc, &.{ home, ".omp", "agent", "hooks", "post" });
}

const omp_hook_script =
    \\// Installed by Colm (`clm agent hooks-install omp`).
    \\// `clm ctl request` disables ambient targeting (commands.zig), so a
    \\// raw status.set JSON lands on the focused workspace — that's why two
    \\// omp threads both showed "omp is working…". `set-status`/`notify`
    \\// inject COLM_WORKSPACE_ID / COLM_TERMINAL_ID.
    \\//
    \\// cmux PromptTurnNotificationHandler never writes "Waiting for you".
    \\// Turn-end is notify: title=agent, subtitle=Completed, body=Task completed.
    \\// The sidebar extra line is customDescription + set-status pills + latest
    \\// notification — not PTY scrollback. We keep the last user prompt as the
    \\// omp status pill so the row shows what the thread is about.
    \\import { spawn } from "node:child_process";
    \\
    \\function clm(args) {
    \\  if (!process.env.COLM_SOCKET) return;
    \\  try {
    \\    const child = spawn("clm", args, { stdio: "ignore", detached: true });
    \\    child.on("error", () => {});
    \\    child.unref();
    \\  } catch {}
    \\}
    \\
    \\function setStatus(text, extra) {
    \\  const args = ["set-status", "--key", "omp"];
    \\  if (extra) args.push(...extra);
    \\  args.push(text);
    \\  clm(args);
    \\}
    \\
    \\function promptText(event) {
    \\  if (!event || typeof event !== "object") return "";
    \\  const raw = event.prompt || event.message || event.text || event.input
    \\    || (event.turn && (event.turn.prompt || event.turn.message))
    \\    || "";
    \\  return String(raw).replace(/\s+/g, " ").trim().slice(0, 160);
    \\}
    \\
    \\export default function colmBridge(pi) {
    \\  pi.on("turn_start", (event) => {
    \\    const text = promptText(event);
    \\    if (text) setStatus(text);
    \\  });
    \\  pi.on("tool_call", (event) => {
    \\    if (event && event.toolName === "ask") {
    \\      setStatus("Needs input", ["--icon", "bell.fill", "--color", "#4C8DFF"]);
    \\      clm(["notify", "omp", "--subtitle", "Waiting", "omp needs your input"]);
    \\    }
    \\  });
    \\  pi.on("session_update", (event) => {
    \\    const id = event && (event.sessionId || event.session_id);
    \\    if (id) clm(["agent", "capture-session", String(id), "--provider", "omp"]);
    \\  });
    \\  pi.on("turn_end", () => {
    \\    clm(["notify", "omp", "--subtitle", "Completed", "Task completed"]);
    \\  });
    \\  pi.on("session_shutdown", () => clm(["clear-status", "--key", "omp"]));
    \\}
    \\
;


const generic_hook_script =
    \\#!/bin/sh
    \\# Installed by Colm. No-op outside Colm terminals. Never uses
    \\# `clm ctl request` (that disables ambient workspace targeting).
    \\set -u
    \\[ -n "${COLM_SOCKET:-}" ] || exit 0
    \\command -v clm >/dev/null 2>&1 || exit 0
    \\provider="${COLM_HOOK_PROVIDER:-agent}"
    \\event="${1:-notification}"
    \\parsed="$(python3 -c '
    \\import json, sys
    \\try:
    \\    data = json.load(sys.stdin)
    \\except Exception:
    \\    data = {}
    \\event = data.get("hook_event_name") or data.get("event") or ""
    \\message = data.get("prompt") or data.get("message") or data.get("title") or data.get("body") or ""
    \\session = data.get("session_id") or data.get("sessionId") or (data.get("session") or {}).get("id") or ""
    \\print((event + "\n" + str(message).replace("\n", " ")[:240] + "\n" + str(session)).encode("utf-8", "replace").decode())
    \\' 2>/dev/null || printf '\n\n')"
    \\hook_event="$(printf '%s' "$parsed" | sed -n '1p')"
    \\message="$(printf '%s' "$parsed" | sed -n '2p')"
    \\session="$(printf '%s' "$parsed" | sed -n '3p')"
    \\[ -n "$session" ] && clm agent capture-session "$session" --provider "$provider" >/dev/null 2>&1 || true
    \\case "${hook_event:-$event}" in
    \\Stop|stop|agentStop|SessionComplete|complete)
    \\  clm notify "$provider" --subtitle Completed "Task completed"
    \\  ;;
    \\Notification|notification|PermissionRequest|needs_permission|AskUserQuestion)
    \\  clm set-status --key "$provider" --icon bell.fill --color "#4C8DFF" "Needs input"
    \\  clm notify "$provider" --subtitle Waiting "${message:-needs your input}"
    \\  ;;
    \\userPromptSubmitted|UserPromptSubmit|SessionStart|start)
    \\  [ -n "$message" ] && clm set-status --key "$provider" "$message"
    \\  ;;
    \\sessionEnd|SessionEnd)
    \\  clm clear-status --key "$provider"
    \\  ;;
    \\*)
    \\  clm agent-hook "${hook_event:-$event}"
    \\  ;;
    \\esac
    \\
;


const claude_hook_script =
    \\#!/bin/sh
    \\# Installed by Colm: bridges Claude Code hook events into the workspace
    \\# sidebar. Claude pipes hook JSON on stdin. No-op outside Colm terminals.
    \\set -u
    \\[ -n "${COLM_SOCKET:-}" ] || exit 0
    \\command -v clm >/dev/null 2>&1 || exit 0
    \\export COLM_HOOK_PROVIDER=claude
    \\event="${1:-notification}"
    \\parsed="$(python3 -c '
    \\import json, sys
    \\try:
    \\    data = json.load(sys.stdin)
    \\except Exception:
    \\    data = {}
    \\message = data.get("prompt") or data.get("message") or data.get("title") or ""
    \\session = data.get("session_id") or data.get("sessionId") or ""
    \\print((str(message).replace("\n", " ")[:240] + "\n" + str(session)).encode("utf-8", "replace").decode())
    \\' 2>/dev/null || printf '\n')"
    \\message="$(printf '%s' "$parsed" | sed -n '1p')"
    \\session="$(printf '%s' "$parsed" | sed -n '2p')"
    \\[ -n "$session" ] && clm agent capture-session "$session" --provider claude >/dev/null 2>&1 || true
    \\case "$event" in
    \\UserPromptSubmit|userPromptSubmitted)
    \\  [ -n "$message" ] && clm set-status --key claude "$message"
    \\  ;;
    \\notification) exec clm notify "claude" --subtitle Waiting "${message:-Claude needs your input}" ;;
    \\stop) exec clm notify "claude" --subtitle Completed "Task completed" ;;
    \\*) exec clm agent-hook "$event" ;;
    \\esac
    \\

    \\
;

fn hooksPath(alloc: std.mem.Allocator) ![]u8 {
    return xdg.config(alloc, .{ .subdir = "colm/hooks" });
}

pub fn installHook(alloc: std.mem.Allocator, provider: []const u8) ![]const u8 {
    const name = providerName(provider) orelse return error.InvalidProvider;
    if (std.mem.eql(u8, name, "omp")) {
        const root = try ompHooksDir(alloc);
        defer alloc.free(root);
        return writeExecutable(alloc, root, omp_hook_filename, omp_hook_script);
    }
    const root = try hooksPath(alloc);
    defer alloc.free(root);
    const filename_value = try std.fmt.allocPrint(alloc, "{s}.sh", .{name});
    defer alloc.free(filename_value);
    const script = if (std.mem.eql(u8, name, "claude")) claude_hook_script else generic_hook_script;
    const path = try writeExecutable(alloc, root, filename_value, script);
    if (std.mem.eql(u8, name, "claude")) try registerClaudeHooks(alloc, path);
    if (std.mem.eql(u8, name, "copilot")) try registerCopilotHooks(alloc, path);
    return path;
}

pub fn installAllHooks(alloc: std.mem.Allocator) !std.json.Value {
    var result: std.array_list.Managed(std.json.Value) = .init(alloc);
    for (providers) |name| {
        const always = std.mem.eql(u8, name, "claude") or std.mem.eql(u8, name, "omp");
        if (!always and !onPath(alloc, providerBinary(name))) continue;
        const path = installHook(alloc, name) catch continue;
        var object: std.json.ObjectMap = .init(alloc);
        try object.put("provider", .{ .string = name });
        try object.put("path", .{ .string = path });
        try object.put("installed", .{ .bool = true });
        try result.append(.{ .object = object });
    }
    return .{ .array = result };
}

fn writeExecutable(alloc: std.mem.Allocator, root: []const u8, name: []const u8, content: []const u8) ![]const u8 {
    try std.fs.cwd().makePath(root);
    var dir = try std.fs.openDirAbsolute(root, .{});
    defer dir.close();
    var buffer: [4096]u8 = undefined;
    var atomic = try dir.atomicFile(name, .{ .mode = 0o700, .write_buffer = &buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(content);
    try atomic.finish();
    const path = try std.fs.path.join(alloc, &.{ root, name });
    var file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer file.close();
    try file.chmod(0o700);
    return path;
}

pub fn uninstallHook(alloc: std.mem.Allocator, provider: []const u8) !void {
    const name = providerName(provider) orelse return error.InvalidProvider;
    const root = if (std.mem.eql(u8, name, "omp")) try ompHooksDir(alloc) else try hooksPath(alloc);
    defer alloc.free(root);
    const filename_value = if (std.mem.eql(u8, name, "omp"))
        try alloc.dupe(u8, omp_hook_filename)
    else
        try std.fmt.allocPrint(alloc, "{s}.sh", .{name});
    defer alloc.free(filename_value);
    if (std.mem.eql(u8, name, "claude")) unregisterClaudeHooks(alloc) catch {};
    var dir = std.fs.openDirAbsolute(root, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
    defer dir.close();
    dir.deleteFile(filename_value) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
}

fn claudeSettingsDir(alloc: std.mem.Allocator) ![]u8 {
    if (std.posix.getenv("CLAUDE_CONFIG_DIR")) |value| {
        if (value.len > 0) return alloc.dupe(u8, value);
    }
    const home = std.posix.getenv("HOME") orelse return error.MissingHomeDirectory;
    return std.fs.path.join(alloc, &.{ home, ".claude" });
}

const claude_hook_events = .{
    .{ "Notification", "notification" },
    .{ "Stop", "stop" },
    .{ "UserPromptSubmit", "UserPromptSubmit" },
};


/// Registers the Colm bridge in Claude Code's own hook configuration, the
/// same mechanism cmux uses. Only appends missing entries; every other
/// setting is preserved byte-for-byte through parse/stringify.
fn registerClaudeHooks(alloc: std.mem.Allocator, script_path: []const u8) !void {
    const dir_path = try claudeSettingsDir(alloc);
    defer alloc.free(dir_path);
    try std.fs.cwd().makePath(dir_path);
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    var root: std.json.Value = load: {
        var file = dir.openFile("settings.json", .{}) catch |err| switch (err) {
            error.FileNotFound => break :load .{ .object = .init(alloc) },
            else => return err,
        };
        defer file.close();
        const bytes = try file.readToEndAlloc(alloc, max_bytes);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
        if (value != .object) return error.InvalidClaudeSettings;
        break :load value;
    };
    if (root.object.get("hooks") == null) try root.object.put("hooks", .{ .object = .init(alloc) });
    const hooks = root.object.getPtr("hooks").?;
    if (hooks.* != .object) return error.InvalidClaudeSettings;
    inline for (claude_hook_events) |event| {
        const command = try std.fmt.allocPrint(alloc, "{s} {s}", .{ script_path, event.@"1" });
        if (hooks.object.get(event.@"0") == null) try hooks.object.put(event.@"0", .{ .array = .init(alloc) });
        const entries = hooks.object.getPtr(event.@"0").?;
        if (entries.* != .array) return error.InvalidClaudeSettings;
        if (!claudeEntriesContain(entries.array.items, script_path)) {
            var hook: std.json.ObjectMap = .init(alloc);
            try hook.put("type", .{ .string = "command" });
            try hook.put("command", .{ .string = command });
            var hook_list: std.json.Array = .init(alloc);
            try hook_list.append(.{ .object = hook });
            var entry: std.json.ObjectMap = .init(alloc);
            try entry.put("matcher", .{ .string = "" });
            try entry.put("hooks", .{ .array = hook_list });
            try entries.array.append(.{ .object = entry });
        }
    }
    try writeClaudeSettings(dir, root, alloc);
}

fn unregisterClaudeHooks(alloc: std.mem.Allocator) !void {
    const dir_path = try claudeSettingsDir(alloc);
    defer alloc.free(dir_path);
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
    defer dir.close();
    var file = dir.openFile("settings.json", .{}) catch return;
    const bytes = file.readToEndAlloc(alloc, max_bytes) catch {
        file.close();
        return;
    };
    file.close();
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always }) catch return;
    if (root != .object) return;
    const hooks = root.object.getPtr("hooks") orelse return;
    if (hooks.* != .object) return;
    inline for (claude_hook_events) |event| {
        if (hooks.object.getPtr(event.@"0")) |entries| {
            if (entries.* == .array) {
                var index: usize = 0;
                while (index < entries.array.items.len) {
                    if (claudeEntriesContain(entries.array.items[index .. index + 1], "colm/hooks/claude.sh")) {
                        _ = entries.array.orderedRemove(index);
                    } else index += 1;
                }
            }
        }
    }
    try writeClaudeSettings(dir, root, alloc);
}

fn claudeEntriesContain(entries: []const std.json.Value, marker: []const u8) bool {
    for (entries) |entry| {
        if (entry != .object) continue;
        const hook_list = entry.object.get("hooks") orelse continue;
        if (hook_list != .array) continue;
        for (hook_list.array.items) |hook| {
            if (hook != .object) continue;
            const command = hook.object.get("command") orelse continue;
            if (command == .string and std.mem.indexOf(u8, command.string, marker) != null) return true;
        }
    }
    return false;
}

fn writeClaudeSettings(dir: std.fs.Dir, root: std.json.Value, alloc: std.mem.Allocator) !void {
    const bytes = try std.json.Stringify.valueAlloc(alloc, root, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    var buffer: [4096]u8 = undefined;
    var atomic = try dir.atomicFile("settings.json", .{ .mode = 0o644, .write_buffer = &buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.finish();
}

pub fn hookStatus(alloc: std.mem.Allocator) !std.json.Value {
    var result: std.array_list.Managed(std.json.Value) = .init(alloc);
    const root = try hooksPath(alloc);
    defer alloc.free(root);
    inline for (providers) |name| {
        const path = if (comptime std.mem.eql(u8, name, "omp"))
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ try ompHooksDir(alloc), omp_hook_filename })
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}.sh", .{ root, name });
        const installed = if (std.fs.openFileAbsolute(path, .{})) |file_value| installed: {
            var file = file_value;
            file.close();
            break :installed true;
        } else |_| false;
        try result.append(.{ .object = object: {
            var object: std.json.ObjectMap = .init(alloc);
            try object.put("provider", .{ .string = name });
            try object.put("installed", .{ .bool = installed });
            try object.put("path", .{ .string = path });
            try object.put("binary", .{ .string = providerBinary(name) });
            break :object object;
        } });
    }
    return .{ .array = result };
}

fn shellQuote(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();
    try result.writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') try result.writer.writeAll("'\\''") else try result.writer.writeByte(byte);
    }
    try result.writer.writeByte('\'');
    return result.toOwnedSlice();
}

pub fn launchCommand(
    alloc: std.mem.Allocator,
    provider: []const u8,
    session_id: ?[]const u8,
    team: ?[]const u8,
    prompt: ?[]const u8,
) ![]const u8 {
    const name = providerName(provider) orelse return error.InvalidProvider;
    if (session_id) |value| if (value.len == 0 or value.len > 256 or !std.unicode.utf8ValidateSlice(value))
        return error.InvalidSession;
    if (team) |value| if (value.len == 0 or value.len > 128 or !std.unicode.utf8ValidateSlice(value))
        return error.InvalidTeam;
    if (prompt) |value| if (value.len == 0 or value.len > 1024 * 1024 or !std.unicode.utf8ValidateSlice(value))
        return error.InvalidText;
    if (team != null and !std.mem.eql(u8, name, "claude")) return error.TeamsUnsupported;

    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();
    if (team != null) try result.writer.writeAll("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 ");
    try result.writer.writeAll(providerBinary(name));
    if (session_id) |value| {
        const quoted = try shellQuote(alloc, value);
        defer alloc.free(quoted);
        if (std.mem.eql(u8, name, "codex"))
            try result.writer.print(" resume {s}", .{quoted})
        else if (std.mem.eql(u8, name, "grok"))
            try result.writer.print(" -r {s}", .{quoted})
        else if (std.mem.eql(u8, name, "rovo"))
            try result.writer.print(" rovodev run --restore {s}", .{quoted})
        else if (std.mem.eql(u8, name, "claude") or
            std.mem.eql(u8, name, "cursor") or
            std.mem.eql(u8, name, "gemini") or
            std.mem.eql(u8, name, "copilot") or
            std.mem.eql(u8, name, "codebuddy") or
            std.mem.eql(u8, name, "factory") or
            std.mem.eql(u8, name, "qoder"))
            try result.writer.print(" --resume {s}", .{quoted})
        else
            try result.writer.print(" --session {s}", .{quoted});
    }
    if (team) |value| {
        const instruction = try std.fmt.allocPrint(alloc, "Create and coordinate the agent team named {s}.", .{value});
        defer alloc.free(instruction);
        const quoted = try shellQuote(alloc, instruction);
        defer alloc.free(quoted);
        try result.writer.print(" {s}", .{quoted});
    }
    if (prompt) |value| {
        const quoted = try shellQuote(alloc, value);
        defer alloc.free(quoted);
        try result.writer.print(" {s}", .{quoted});
    }
    return result.toOwnedSlice();
}

pub fn installTmuxShim(alloc: std.mem.Allocator) ![]const u8 {
    const root = try hooksPath(alloc);
    defer alloc.free(root);
    try std.fs.cwd().makePath(root);
    var dir = try std.fs.openDirAbsolute(root, .{});
    defer dir.close();
    const script =
        \\#!/bin/sh
        \\set -eu
        \\if [ "${1:-}" = "display-message" ]; then
        \\  value=
        \\  for arg in "$@"; do value=$arg; done
        \\  case "$value" in
        \\    '#{pane_id}') printf '%s\n' "${CMUX_PANE_ID:-${COLM_PANE_ID:-}}" ;;
        \\    '#{window_id}') printf '%s\n' "${CMUX_WORKSPACE_ID:-${COLM_WORKSPACE_ID:-}}" ;;
        \\    '#{session_id}') printf '%s\n' "${CMUX_WINDOW_ID:-${COLM_WINDOW_ID:-}}" ;;
        \\    *) printf '%s\n' "$value" ;;
        \\  esac
        \\  exit 0
        \\fi
        \\if [ "${1:-}" = "rename-window" ]; then
        \\  shift
        \\  exec clm rename-terminal "$*"
        \\fi
        \\if [ -x /usr/bin/tmux ]; then exec /usr/bin/tmux "$@"; fi
        \\printf '%s\n' "tmux is unavailable; the Colm shim supports display-message and rename-window" >&2
        \\exit 127
        \\
    ;
    var buffer: [2048]u8 = undefined;
    var atomic = try dir.atomicFile("tmux", .{ .mode = 0o700, .write_buffer = &buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(script);
    try atomic.finish();
    const path = try std.fs.path.join(alloc, &.{ root, "tmux" });
    var file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer file.close();
    try file.chmod(0o700);
    return path;
}

pub fn uninstallTmuxShim(alloc: std.mem.Allocator) !void {
    const root = try hooksPath(alloc);
    defer alloc.free(root);
    var dir = std.fs.openDirAbsolute(root, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
    defer dir.close();
    dir.deleteFile("tmux") catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
}

const sessions_filename = "hook-sessions.json";

pub const SessionRecord = struct {
    provider: []const u8,
    session_id: []const u8,
    workspace_id: []const u8,
    surface_id: []const u8,
    cwd: ?[]const u8,
};

fn sessionsPath(alloc: std.mem.Allocator) ![]u8 {
    return xdg.config(alloc, .{ .subdir = "colm" });
}

fn loadSessions(alloc: std.mem.Allocator) !std.json.Value {
    const path = try sessionsPath(alloc);
    defer alloc.free(path);
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return emptySessions(alloc),
        else => return err,
    };
    defer dir.close();
    var file = dir.openFile(sessions_filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return emptySessions(alloc),
        else => return err,
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(alloc, max_bytes);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
    if (value != .object or value.object.get("sessions") == null or value.object.get("sessions").? != .array)
        return emptySessions(alloc);
    return value;
}

fn emptySessions(alloc: std.mem.Allocator) !std.json.Value {
    var root: std.json.ObjectMap = .init(alloc);
    try root.put("version", .{ .integer = 1 });
    try root.put("sessions", .{ .array = .init(alloc) });
    return .{ .object = root };
}

fn saveSessions(alloc: std.mem.Allocator, value: std.json.Value) !void {
    const path = try sessionsPath(alloc);
    defer alloc.free(path);
    try std.fs.cwd().makePath(path);
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    var buffer: [4096]u8 = undefined;
    var atomic = try dir.atomicFile(sessions_filename, .{ .mode = 0o600, .write_buffer = &buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.finish();
}

pub fn captureSession(alloc: std.mem.Allocator, record: SessionRecord) !void {
    if (record.session_id.len == 0 or record.session_id.len > 256) return error.InvalidSession;
    if (!std.unicode.utf8ValidateSlice(record.session_id)) return error.InvalidSession;
    const provider = providerName(record.provider) orelse record.provider;
    var root = try loadSessions(alloc);
    const sessions = root.object.getPtr("sessions").?;
    var index: usize = 0;
    while (index < sessions.array.items.len) {
        const item = sessions.array.items[index];
        if (item == .object) {
            const same_provider = if (item.object.get("provider")) |value| value == .string and std.mem.eql(u8, value.string, provider) else false;
            const same_workspace = if (item.object.get("workspace_id")) |value| value == .string and std.mem.eql(u8, value.string, record.workspace_id) else false;
            if (same_provider and same_workspace) {
                _ = sessions.array.orderedRemove(index);
                continue;
            }
        }
        index += 1;
    }
    var object: std.json.ObjectMap = .init(alloc);
    try object.put("provider", .{ .string = try alloc.dupe(u8, provider) });
    try object.put("session_id", .{ .string = try alloc.dupe(u8, record.session_id) });
    try object.put("workspace_id", .{ .string = try alloc.dupe(u8, record.workspace_id) });
    try object.put("surface_id", .{ .string = try alloc.dupe(u8, record.surface_id) });
    if (record.cwd) |cwd| try object.put("cwd", .{ .string = try alloc.dupe(u8, cwd) });
    try object.put("updated_at", .{ .integer = std.time.milliTimestamp() });
    try sessions.array.append(.{ .object = object });
    try saveSessions(alloc, root);
}

pub fn listSessions(alloc: std.mem.Allocator) !std.json.Value {
    const root = try loadSessions(alloc);
    return root.object.get("sessions").?;
}

fn registerCopilotHooks(alloc: std.mem.Allocator, script_path: []const u8) !void {
    const home = std.posix.getenv("HOME") orelse return error.MissingHomeDirectory;
    const dir_path = try std.fs.path.join(alloc, &.{ home, ".copilot" });
    defer alloc.free(dir_path);
    try std.fs.cwd().makePath(dir_path);
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    var root: std.json.Value = load: {
        var file = dir.openFile("config.json", .{}) catch |err| switch (err) {
            error.FileNotFound => break :load .{ .object = .init(alloc) },
            else => return err,
        };
        defer file.close();
        const bytes = try file.readToEndAlloc(alloc, max_bytes);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, bytes, .{ .allocate = .alloc_always });
        if (value != .object) return error.InvalidCopilotSettings;
        break :load value;
    };
    if (root.object.get("hooks") == null) try root.object.put("hooks", .{ .object = .init(alloc) });
    const hooks = root.object.getPtr("hooks").?;
    if (hooks.* != .object) return error.InvalidCopilotSettings;
    const command = try std.fmt.allocPrint(alloc, "{s} copilot", .{script_path});
    inline for (.{ "agentStop", "errorOccurred", "userPromptSubmitted", "sessionEnd" }) |event| {
        if (hooks.object.get(event) == null) try hooks.object.put(event, .{ .array = .init(alloc) });
        const entries = hooks.object.getPtr(event).?;
        if (entries.* != .array) return error.InvalidCopilotSettings;
        var found = false;
        for (entries.array.items) |entry| {
            if (entry != .object) continue;
            const bash = entry.object.get("bash") orelse continue;
            if (bash == .string and std.mem.indexOf(u8, bash.string, script_path) != null) found = true;
        }
        if (!found) {
            var entry: std.json.ObjectMap = .init(alloc);
            try entry.put("type", .{ .string = "command" });
            try entry.put("bash", .{ .string = command });
            try entry.put("timeoutSec", .{ .integer = 5 });
            try entries.array.append(.{ .object = entry });
        }
    }
    const bytes = try std.json.Stringify.valueAlloc(alloc, root, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    var buffer: [4096]u8 = undefined;
    var atomic = try dir.atomicFile("config.json", .{ .mode = 0o644, .write_buffer = &buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.finish();
}

pub const Detected = struct {
    provider: []const u8,
    session_id: ?[]const u8 = null,
    tmux_session: ?[]const u8 = null,
};

pub fn parseArgv(args: []const []const u8) ?struct { provider: []const u8, session_id: ?[]const u8 } {
    var provider: ?[]const u8 = null;
    for (args) |arg| {
        const base = std.fs.path.basename(arg);
        if (providerName(base)) |name| {
            provider = name;
            break;
        }
    }
    const name = provider orelse return null;
    var session_id: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (consumeFlag(arg, args, &index, "--resume")) |value| {
            session_id = value;
        } else if (consumeFlag(arg, args, &index, "--session")) |value| {
            session_id = value;
        } else if (std.mem.eql(u8, arg, "-r") and index + 1 < args.len) {
            index += 1;
            session_id = args[index];
        } else if (std.mem.eql(u8, arg, "resume") and index + 1 < args.len) {
            index += 1;
            session_id = args[index];
        }
    }
    return .{ .provider = name, .session_id = session_id };
}

fn consumeFlag(arg: []const u8, args: []const []const u8, index: *usize, flag: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=')
        return arg[flag.len + 1 ..];
    if (std.mem.eql(u8, arg, flag) and index.* + 1 < args.len) {
        index.* += 1;
        return args[index.*];
    }
    return null;
}

pub fn parseTmuxSession(args: []const []const u8) ?[]const u8 {
    if (args.len == 0) return null;
    if (!std.mem.eql(u8, std.fs.path.basename(args[0]), "tmux")) return null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if ((std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "-s")) and index + 1 < args.len)
            return args[index + 1];
        if (std.mem.startsWith(u8, arg, "-t") and arg.len > 2) return arg[2..];
        if (std.mem.startsWith(u8, arg, "-s") and arg.len > 2) return arg[2..];
    }
    return null;
}

pub fn detectForTerminal(alloc: std.mem.Allocator, terminal_id: []const u8) !?Detected {
    if (terminal_id.len == 0 or terminal_id.len > 64) return null;
    var proc = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return null;
    defer proc.close();
    var iterator = proc.iterate();
    var found: ?Detected = null;
    var scanned: usize = 0;
    while (iterator.next() catch null) |entry| {
        scanned += 1;
        if (scanned > 4096) break;
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const env_path = std.fmt.allocPrint(alloc, "/proc/{s}/environ", .{entry.name}) catch continue;
        const env = std.fs.cwd().readFileAlloc(alloc, env_path, 64 * 1024) catch continue;
        if (!envHas(env, "COLM_TERMINAL_ID", terminal_id) and !envHas(env, "COLM_SURFACE_ID", terminal_id))
            continue;
        const cmd_path = std.fmt.allocPrint(alloc, "/proc/{s}/cmdline", .{entry.name}) catch continue;
        const cmd = std.fs.cwd().readFileAlloc(alloc, cmd_path, 8192) catch continue;
        if (cmd.len == 0) continue;
        var args: std.ArrayList([]const u8) = .empty;
        var start: usize = 0;
        for (cmd, 0..) |byte, i| {
            if (byte != 0) continue;
            if (i > start) args.append(alloc, cmd[start..i]) catch break;
            start = i + 1;
        }
        if (start < cmd.len) args.append(alloc, cmd[start..]) catch {};
        const agent = parseArgv(args.items);
        const tmux = parseTmuxSession(args.items);
        if (agent == null and tmux == null) continue;
        if (found == null) {
            found = .{
                .provider = if (agent) |value| try alloc.dupe(u8, value.provider) else "",
                .session_id = if (agent) |value| if (value.session_id) |id| try alloc.dupe(u8, id) else null else null,
                .tmux_session = if (tmux) |session| try alloc.dupe(u8, session) else null,
            };
        } else {
            if (found.?.session_id == null) {
                if (agent) |value| {
                    found.?.provider = try alloc.dupe(u8, value.provider);
                    if (value.session_id) |id| found.?.session_id = try alloc.dupe(u8, id);
                }
            }
            if (found.?.tmux_session == null) {
                if (tmux) |session| found.?.tmux_session = try alloc.dupe(u8, session);
            }
        }
        if (found.?.session_id != null and found.?.tmux_session != null) break;
    }
    return found;
}

fn envHas(env: []const u8, key: []const u8, value: []const u8) bool {
    var entries = std.mem.splitScalar(u8, env, 0);
    while (entries.next()) |entry| {
        if (entry.len < key.len + 1 + value.len) continue;
        if (!std.mem.startsWith(u8, entry, key) or entry[key.len] != '=') continue;
        if (std.mem.eql(u8, entry[key.len + 1 ..], value)) return true;
    }
    return false;
}

