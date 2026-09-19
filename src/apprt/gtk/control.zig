const std = @import("std");
const glib = @import("glib");
const p = @import("../../control/protocol.zig");
const api = @import("automation.zig");
const alloc = std.heap.c_allocator;
var server: ?std.net.Server = null;
var timer: c_uint = 0;
var path: ?[]const u8 = null;
var clients: std.ArrayList(*Client) = .empty;
const Client = struct {
    socket: std.net.Stream,
    arena: std.heap.ArenaAllocator,
    input: std.ArrayList(u8) = .empty,
    output: ?[]const u8 = null,
    written: usize = 0,
    pending: bool = false,
    dead: bool = false,
    started: i64,
};

pub fn start() !void {
    if (server != null) return;
    const dir_path = try @import("../../control/client.zig").runtimeDirectory(alloc);
    defer alloc.free(dir_path);
    const socket_path = try std.fmt.allocPrint(alloc, "{s}/control-{d}.sock", .{ dir_path, std.os.linux.getpid() });
    errdefer alloc.free(socket_path);
    try std.fs.cwd().makePath(dir_path);
    const stat = try std.posix.fstatat(std.posix.AT.FDCWD, dir_path, std.posix.AT.SYMLINK_NOFOLLOW);
    if (stat.uid != std.posix.getuid() or (stat.mode & std.posix.S.IFMT) != std.posix.S.IFDIR) return error.UnsafeSocketDirectory;
    var directory = try std.fs.openDirAbsolute(dir_path, .{ .no_follow = true, .iterate = true });
    defer directory.close();
    try std.posix.fchmod(directory.fd, 0o700);
    // Sweep sockets leaked by instances that died without running stop().
    // Names encode the owning pid; a dead pid means a stale socket. A recycled
    // pid keeps its file, which endpoint discovery already filters by probe.
    var entries = directory.iterate();
    while (entries.next() catch null) |entry| {
        if (entry.kind != .unix_domain_socket) continue;
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, "control-") or !std.mem.endsWith(u8, name, ".sock")) continue;
        const owner = std.fmt.parseInt(i32, name["control-".len .. name.len - ".sock".len], 10) catch continue;
        if (owner == std.os.linux.getpid()) continue;
        std.posix.kill(owner, 0) catch |err| switch (err) {
            error.ProcessNotFound => directory.deleteFile(name) catch {},
            else => {},
        };
    }
    const address = try std.net.Address.initUnix(socket_path);
    // Only remove a stale socket owned by this UID, never an active instance.
    if (std.posix.fstatat(std.posix.AT.FDCWD, socket_path, std.posix.AT.SYMLINK_NOFOLLOW)) |existing| {
        if (existing.uid != std.posix.getuid() or (existing.mode & std.posix.S.IFMT) != std.posix.S.IFSOCK) return error.UnsafeSocketPath;
        if (std.net.connectUnixSocket(socket_path)) |active| {
            active.close();
            return error.ControlEndpointInUse;
        } else |err| switch (err) {
            error.ConnectionRefused, error.FileNotFound => try std.fs.cwd().deleteFile(socket_path),
            else => return err,
        }
    } else |err| if (err != error.FileNotFound) return err;
    server = try address.listen(.{ .force_nonblocking = true });
    errdefer {
        server.?.deinit();
        server = null;
    }
    const path_z = try alloc.dupeZ(u8, socket_path);
    defer alloc.free(path_z);
    if (std.c.chmod(path_z, 0o600) != 0) return error.SocketPermissionsFailed;
    path = socket_path;
    timer = glib.timeoutAdd(20, tick, null);
}

pub fn socketPath(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, path orelse return error.ControlEndpointUnavailable);
}

pub fn stop() void {
    if (timer != 0) {
        _ = glib.Source.remove(timer);
        timer = 0;
    }
    if (server) |*s| {
        s.deinit();
        server = null;
    }
    if (path) |value| {
        std.fs.cwd().deleteFile(value) catch {};
        alloc.free(value);
        path = null;
    }
    for (clients.items) |c| {
        c.dead = true;
        c.socket.close();
        if (!c.pending) destroy(c);
    }
    clients.deinit(alloc);
    clients = .empty;
}
fn destroy(c: *Client) void {
    c.arena.deinit();
    alloc.destroy(c);
}
fn reply(ctx: *anyopaque, result: p.Result) void {
    const c: *Client = @ptrCast(@alignCast(ctx));
    c.pending = false;
    if (c.dead) {
        destroy(c);
        return;
    }
    const a = c.arena.allocator();
    const envelope = switch (result) {
        .ok => |value| p.object(a, .{ .ok = p.boolean(true), .result = value }),
        .err => |message| blk: {
            const detail = p.object(a, .{ .code = p.str(message), .message = p.str(message) }) catch break :blk error.OutOfMemory;
            break :blk p.object(a, .{ .ok = p.boolean(false), .@"error" = detail });
        },
    } catch {
        c.output = "{\"ok\":false,\"error\":{\"code\":\"OutOfMemory\",\"message\":\"OutOfMemory\"}}\n";
        return;
    };
    const json = std.json.Stringify.valueAlloc(a, envelope, .{}) catch {
        c.output = "{\"ok\":false}\n";
        return;
    };
    c.output = std.fmt.allocPrint(a, "{s}\n", .{json}) catch "{\"ok\":false}\n";
}

pub fn hasPendingReply() bool {
    for (clients.items) |client| {
        if (client.output != null) return true;
    }
    return false;
}
fn tick(_: ?*anyopaque) callconv(.c) c_int {
    const s = &(server orelse return 0);
    while (clients.items.len < 32) {
        const fd = std.posix.accept(s.stream.handle, null, null, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK) catch break;
        const Credential = extern struct { pid: i32, uid: u32, gid: u32 };
        var credentials: Credential = undefined;
        std.posix.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.PEERCRED, std.mem.asBytes(&credentials)) catch {
            std.posix.close(fd);
            continue;
        };
        if (credentials.uid != std.posix.getuid()) {
            std.posix.close(fd);
            continue;
        }
        const c = alloc.create(Client) catch {
            std.posix.close(fd);
            break;
        };
        c.* = .{ .socket = .{ .handle = fd }, .arena = .init(alloc), .started = std.time.milliTimestamp() };
        clients.append(alloc, c) catch {
            c.socket.close();
            destroy(c);
            break;
        };
    }
    var index: usize = 0;
    while (index < clients.items.len) {
        const c = clients.items[index];
        var remove = false;
        if (c.output) |output| {
            const sent = std.posix.send(c.socket.handle, output[c.written..], std.posix.MSG.NOSIGNAL) catch |err| blk: {
                if (err != error.WouldBlock) remove = true;
                break :blk 0;
            };
            c.written += sent;
            if (c.written == output.len) remove = true;
        } else if (!c.pending) {
            var buf: [8192]u8 = undefined;
            const n = c.socket.read(&buf) catch |err| blk: {
                if (err != error.WouldBlock) remove = true;
                break :blk null;
            };
            if (n) |count| {
                if (count == 0) {
                    remove = true;
                } else {
                    const a = c.arena.allocator();
                    c.input.appendSlice(a, buf[0..count]) catch {
                        remove = true;
                    };
                    if (c.input.items.len > 1024 * 1024) {
                        reply(c, .{ .err = "RequestTooLarge" });
                    } else if (std.mem.indexOfScalar(u8, c.input.items, '\n')) |end| {
                        const parsed = std.json.parseFromSlice(p.Value, a, c.input.items[0..end], .{ .allocate = .alloc_always, .max_value_len = 1024 * 1024 }) catch {
                            reply(c, .{ .err = "InvalidJSON" });
                            index += 1;
                            continue;
                        };
                        c.pending = true;
                        api.dispatch(a, parsed.value, c, reply);
                    }
                }
            }
        }
        if (std.time.milliTimestamp() - c.started > 360_000) remove = true;
        if (remove) {
            _ = clients.swapRemove(index);
            c.socket.close();
            c.dead = true;
            if (!c.pending) destroy(c);
        } else index += 1;
    }
    return 1;
}
