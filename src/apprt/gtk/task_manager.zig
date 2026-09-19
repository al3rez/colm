const std = @import("std");
const p = @import("../../control/protocol.zig");

pub fn inspect(alloc: std.mem.Allocator, pid: i64) !p.Value {
    if (pid <= 0 or pid > std.math.maxInt(i32)) return error.InvalidPid;
    const path = try std.fmt.allocPrint(alloc, "/proc/{d}/status", .{pid});
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ProcessNotFound,
        else => return err,
    };
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 1024 * 1024);
    var name: []const u8 = "";
    var state: []const u8 = "";
    var parent: i64 = 0;
    var uid: i64 = -1;
    var memory_kib: i64 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Name:")) name = std.mem.trim(u8, line[5..], " \t");
        if (std.mem.startsWith(u8, line, "State:")) state = std.mem.trim(u8, line[6..], " \t");
        if (std.mem.startsWith(u8, line, "PPid:")) parent = std.fmt.parseInt(i64, std.mem.trim(u8, line[5..], " \t"), 10) catch 0;
        if (std.mem.startsWith(u8, line, "Uid:")) {
            var values = std.mem.tokenizeAny(u8, line[4..], " \t");
            uid = std.fmt.parseInt(i64, values.next() orelse "-1", 10) catch -1;
        }
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            var values = std.mem.tokenizeAny(u8, line[6..], " \t");
            memory_kib = std.fmt.parseInt(i64, values.next() orelse "0", 10) catch 0;
        }
    }
    if (uid != std.posix.getuid()) return error.ProcessNotOwnedByUser;
    return p.object(alloc, .{
        .pid = p.integer(pid),
        .parent_pid = p.integer(parent),
        .name = p.str(name),
        .state = p.str(state),
        .uid = p.integer(uid),
        .memory_kib = p.integer(memory_kib),
    });
}

pub fn signal(pid: i64, sig: @TypeOf(std.posix.SIG.TERM)) !void {
    if (pid <= 0 or pid > std.math.maxInt(i32)) return error.InvalidPid;
    std.posix.kill(@intCast(pid), sig) catch |err| switch (err) {
        error.ProcessNotFound => return error.ProcessNotFound,
        error.PermissionDenied => return error.ProcessNotOwnedByUser,
        else => return err,
    };
}
