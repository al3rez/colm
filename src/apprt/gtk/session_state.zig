const std = @import("std");
const xdg = @import("../../os/xdg.zig");

const max_snapshot_bytes = 32 * 1024 * 1024;
const current_name = "session-v1.json";
const previous_name = "session-v1.previous.json";
var rotated_current = false;

pub fn disabled() bool {
    return if (std.posix.getenv("COLM_DISABLE_SESSION_RESTORE")) |value|
        !std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "false")
    else
        false;
}

fn stateDirPath(alloc: std.mem.Allocator) ![]u8 {
    return xdg.state(alloc, .{ .subdir = "colm" });
}

fn writeAtomic(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var atomic = try dir.atomicFile(name, .{
        .mode = 0o600,
        .write_buffer = &buffer,
    });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.finish();
}

fn readNamed(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try stateDirPath(alloc);
    defer alloc.free(path);
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    var file = try dir.openFile(name, .{});
    defer file.close();
    return file.readToEndAlloc(alloc, max_snapshot_bytes);
}

pub fn loadCurrent(alloc: std.mem.Allocator) ![]u8 {
    return readNamed(alloc, current_name);
}

pub fn loadPrevious(alloc: std.mem.Allocator) ![]u8 {
    return readNamed(alloc, previous_name);
}

pub fn saveSnapshot(alloc: std.mem.Allocator, bytes: []const u8) !void {
    const path = try stateDirPath(alloc);
    defer alloc.free(path);
    try std.fs.cwd().makePath(path);
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();

    if (!rotated_current) {
        if (dir.openFile(current_name, .{})) |file_value| {
            var file = file_value;
            defer file.close();
            if (file.readToEndAlloc(alloc, max_snapshot_bytes)) |previous| {
                defer alloc.free(previous);
                const parsed = std.json.parseFromSlice(std.json.Value, alloc, previous, .{}) catch null;
                if (parsed) |valid| {
                    defer valid.deinit();
                    try writeAtomic(dir, previous_name, previous);
                }
            } else |_| {}
        } else |_| {}
        rotated_current = true;
    }
    try writeAtomic(dir, current_name, bytes);
}

pub fn saveScrollback(alloc: std.mem.Allocator, surface_id: []const u8, bytes: []const u8) !void {
    if (surface_id.len != 32) return error.InvalidSurfaceId;
    for (surface_id) |byte| if (!std.ascii.isHex(byte)) return error.InvalidSurfaceId;
    const root = try stateDirPath(alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "scrollback" });
    defer alloc.free(path);
    try std.fs.cwd().makePath(path);
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    const name = try std.fmt.allocPrint(alloc, "{s}.txt", .{surface_id});
    defer alloc.free(name);
    try writeAtomic(dir, name, bytes);
}

pub fn scrollbackPath(alloc: std.mem.Allocator, surface_id: []const u8) ![]u8 {
    if (surface_id.len != 32) return error.InvalidSurfaceId;
    for (surface_id) |byte| if (!std.ascii.isHex(byte)) return error.InvalidSurfaceId;
    const root = try stateDirPath(alloc);
    defer alloc.free(root);
    const name = try std.fmt.allocPrint(alloc, "{s}.txt", .{surface_id});
    defer alloc.free(name);
    return std.fs.path.join(alloc, &.{ root, "scrollback", name });
}
