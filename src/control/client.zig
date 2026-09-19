const std = @import("std");
const p = @import("protocol.zig");
const commands = @import("commands.zig");
const build_config = @import("../build_config.zig");

fn configuredSocketPath(alloc: std.mem.Allocator) !?[]const u8 {
    const canonical = std.posix.getenv("CMUX_SOCKET_PATH");
    const deprecated = std.posix.getenv("CMUX_SOCKET");
    if (canonical != null and deprecated != null and
        !std.mem.eql(u8, canonical.?, deprecated.?))
    {
        return error.ConflictingSocketVariables;
    }
    const value = canonical orelse deprecated orelse std.posix.getenv("COLM_SOCKET") orelse return null;
    if (value.len == 0) return error.InvalidSocketPath;
    return try alloc.dupe(u8, value);
}

pub fn socketPath(alloc: std.mem.Allocator) ![]const u8 {
    if (try configuredSocketPath(alloc)) |value| return value;
    const endpoints = try listEndpoints(alloc);
    if (endpoints.array.items.len == 0) return error.AppNotRunning;
    if (endpoints.array.items.len != 1) return error.AmbiguousInstance;
    return alloc.dupe(u8, try p.string(endpoints.array.items[0], "socket"));
}

fn commandSocketPath(alloc: std.mem.Allocator) ![]const u8 {
    return socketPath(alloc) catch |err| {
        if (err != error.AppNotRunning or
            std.posix.getenv("CMUX_SOCKET_PATH") != null or
            std.posix.getenv("CMUX_SOCKET") != null or
            std.posix.getenv("COLM_SOCKET") != null)
        {
            return err;
        }
        const executable = try std.fs.selfExePathAlloc(alloc);
        defer alloc.free(executable);
        var child = std.process.Child.init(&.{executable}, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        // The app publishes its private socket only after GTK registration.
        // Keep this CLI alive while the child starts; the GUI outlives us.
        var attempts: usize = 0;
        while (attempts < 300) : (attempts += 1) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            if (socketPath(alloc)) |path| return path else |lookup| switch (lookup) {
                error.AppNotRunning => {},
                else => return lookup,
            }
        }
        return error.AppLaunchTimedOut;
    };
}

pub fn runtimeDirectory(alloc: std.mem.Allocator) ![]const u8 {
    const runtime = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
    return std.fs.path.join(alloc, &.{ runtime, "colm" });
}
fn listEndpoints(alloc: std.mem.Allocator) !p.Value {
    var result: std.array_list.Managed(p.Value) = .init(alloc);
    const root = try runtimeDirectory(alloc);
    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true, .no_follow = true }) catch |err| {
        if (err == error.FileNotFound) return .{ .array = result };
        return err;
    };
    defer dir.close();
    const info = try std.posix.fstat(dir.fd);
    if (info.uid != std.posix.getuid() or info.mode & 0o077 != 0) return error.UnsafeSocketDirectory;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "control") or !std.mem.endsWith(u8, entry.name, ".sock")) continue;
        const stat = try std.posix.fstatat(dir.fd, entry.name, std.posix.AT.SYMLINK_NOFOLLOW);
        if (stat.uid != std.posix.getuid() or (stat.mode & std.posix.S.IFMT) != std.posix.S.IFSOCK) continue;
        const socket_path = try std.fs.path.join(alloc, &.{ root, entry.name });
        const stream = std.net.connectUnixSocket(socket_path) catch continue;
        defer stream.close();
        var credentials: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
        try std.posix.getsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.PEERCRED, std.mem.asBytes(&credentials));
        if (credentials.uid != std.posix.getuid()) continue;
        try result.append(try p.object(alloc, .{ .socket = p.str(socket_path), .pid = p.integer(credentials.pid) }));
    }
    return .{ .array = result };
}
fn openPath(alloc: std.mem.Allocator, input: []const u8) !void {
    const absolute = try std.fs.path.resolve(alloc, &.{input});
    defer alloc.free(absolute);
    const stat = try std.fs.cwd().statFile(absolute);
    const directory = if (stat.kind == .directory)
        absolute
    else
        std.fs.path.dirname(absolute) orelse "/";
    const option = try std.fmt.allocPrint(alloc, "--working-directory={s}", .{directory});
    defer alloc.free(option);
    const executable = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(executable);
    var child = std.process.Child.init(&.{ executable, option }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}

/// Intercept automation before Ghostty parses configuration arguments.
pub fn run() !bool {
    const alloc = std.heap.page_allocator;
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (!commands.isInvocation(args[1..])) return false;
    const code = execute(alloc, args[1..]) catch |err| blk: {
        const message = switch (err) {
            error.UnknownCommand => "Unknown command. Run clm --help for supported commands.",
            error.UnknownOption => "This option is not supported by the command. Run clm --help.",
            error.MissingArgument, error.MissingCommand => "Required argument missing. Run clm --help.",
            error.MissingOptionValue => "An option is missing its value.",
            error.DuplicateArgument => "An argument was supplied more than once.",
            error.AppNotRunning => "Colm is not running. Launch clm first.",
            error.AmbiguousInstance => "Multiple Colm instances are running. Use clm endpoints and --socket PATH.",
            else => @errorName(err),
        };
        const output = try std.json.Stringify.valueAlloc(alloc, .{ .ok = false, .@"error" = .{ .code = @errorName(err), .message = message } }, .{});
        defer alloc.free(output);
        try std.fs.File.stdout().writeAll(output);
        try std.fs.File.stdout().writeAll("\n");
        break :blk @as(u8, 2);
    };
    std.process.exit(code);
}
fn execute(alloc: std.mem.Allocator, args: []const [:0]u8) !u8 {
    const parsed = try commands.parse(alloc, args);
    if (parsed.help) {
        try commands.help(parsed.help_command);
        return 0;
    }
    if (parsed.version) {
        try std.fs.File.stdout().writeAll("Colm ");
        try std.fs.File.stdout().writeAll(build_config.version_string);
        try std.fs.File.stdout().writeAll("\n");
        return 0;
    }
    if (parsed.endpoints) {
        const output = try std.json.Stringify.valueAlloc(alloc, .{ .ok = true, .result = try listEndpoints(alloc) }, .{});
        try std.fs.File.stdout().writeAll(output);
        try std.fs.File.stdout().writeAll("\n");
        return 0;
    }
    if (parsed.open_path) |path| {
        try openPath(alloc, path);
        return 0;
    }
    var request = parsed.request;
    if (parsed.ambient_targets and request == .object) {
        if (request.object.getPtr("params")) |params| {
            if (params.* == .object and
                !params.object.contains("workspace_id") and
                !params.object.contains("terminal_id") and
                !params.object.contains("surface_id") and
                !params.object.contains("pane_id") and
                !params.object.contains("window_id") and
                !params.object.contains("browser_id"))
            {
                if (std.posix.getenv("COLM_WINDOW_ID") orelse std.posix.getenv("CMUX_WINDOW_ID")) |value| {
                    try params.object.put("window_id", p.str(value));
                }
                if (std.posix.getenv("COLM_WORKSPACE_ID") orelse
                    std.posix.getenv("CMUX_WORKSPACE_ID") orelse
                    std.posix.getenv("CMUX_TAB_ID")) |value|
                {
                    try params.object.put("workspace_id", p.str(value));
                }
                if (std.posix.getenv("COLM_TERMINAL_ID") orelse std.posix.getenv("CMUX_SURFACE_ID")) |value| {
                    try params.object.put("terminal_id", p.str(value));
                }
            }
        }
    }
    if (request == .object) {
        try request.object.put("id_format", p.str(parsed.id_format));
        if (parsed.password orelse std.posix.getenv("CMUX_SOCKET_PASSWORD")) |password| {
            try request.object.put("password", p.str(password));
        }
    }
    const bytes = try std.json.Stringify.valueAlloc(alloc, request, .{});
    defer alloc.free(bytes);
    if (bytes.len > 1024 * 1024) return error.RequestTooLarge;
    const path = if (parsed.socket) |explicit| try alloc.dupe(u8, explicit) else try commandSocketPath(alloc);
    defer alloc.free(path);
    const socket = try std.net.connectUnixSocket(path);
    defer socket.close();
    const timeout: std.posix.timeval = .{ .sec = 360, .usec = 0 };
    try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    try socket.writeAll(bytes);
    try socket.writeAll("\n");
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try socket.read(&buf);
        if (n == 0) return error.IncompleteResponse;
        try response.appendSlice(alloc, buf[0..n]);
        if (response.items.len > 16 * 1024 * 1024) return error.ResponseTooLarge;
        if (std.mem.indexOfScalar(u8, response.items, '\n')) |end| {
            const result = try std.json.parseFromSlice(p.Value, alloc, response.items[0..end], .{});
            defer result.deinit();
            if (result.value != .object) return error.InvalidResponse;
            const ok = result.value.object.get("ok") orelse return error.InvalidResponse;
            if (ok != .bool) return error.InvalidResponse;
            try std.fs.File.stdout().writeAll(response.items[0 .. end + 1]);
            return if (ok.bool) 0 else 1;
        }
    }
}
