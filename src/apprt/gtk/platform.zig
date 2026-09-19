const std = @import("std");
const builtin = @import("builtin");
const p = @import("../../control/protocol.zig");
const xdg = @import("../../os/xdg.zig");
const build_config = @import("../../build_config.zig");

fn manager(alloc: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("FLATPAK_ID") != null) return "flatpak";
    const executable = try std.fs.selfExePathAlloc(alloc);
    if (std.mem.startsWith(u8, executable, "/usr/") or std.mem.startsWith(u8, executable, "/app/")) return "system-package";
    return "self";
}

pub fn status(alloc: std.mem.Allocator) !p.Value {
    const executable = try std.fs.selfExePathAlloc(alloc);
    return p.object(alloc, .{
        .version = p.str(build_config.version_string),
        .provider = p.str(try manager(alloc)),
        .executable = p.str(executable),
        .self_update_enabled = p.boolean(std.posix.getenv("COLM_ALLOW_SELF_UPDATE") != null),
        .instruction = p.str("Flatpak and distro installations update through their package manager; standalone builds require COLM_ALLOW_SELF_UPDATE=1."),
    });
}

fn decodeHash(value: []const u8) ![32]u8 {
    if (value.len != 64) return error.InvalidSha256;
    var result: [32]u8 = undefined;
    for (0..32) |index| {
        const high = std.fmt.charToDigit(value[index * 2], 16) catch return error.InvalidSha256;
        const low = std.fmt.charToDigit(value[index * 2 + 1], 16) catch return error.InvalidSha256;
        result[index] = (high << 4) | low;
    }
    return result;
}

pub fn apply(alloc: std.mem.Allocator, artifact: []const u8, sha256: []const u8) !p.Value {
    if (std.posix.getenv("COLM_ALLOW_SELF_UPDATE") == null) return error.SelfUpdateDisabled;
    if (!std.fs.path.isAbsolute(artifact)) return error.AbsolutePathRequired;
    const expected = try decodeHash(sha256);
    var source = try std.fs.openFileAbsolute(artifact, .{});
    defer source.close();
    const stat = try source.stat();
    if (stat.kind != .file or stat.size == 0 or stat.size > 256 * 1024 * 1024) return error.InvalidUpdateArtifact;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try source.read(&buffer);
        if (count == 0) break;
        hash.update(buffer[0..count]);
    }
    var actual: [32]u8 = undefined;
    hash.final(&actual);
    if (!std.crypto.timing_safe.eql([32]u8, expected, actual)) return error.UpdateHashMismatch;

    const executable = try std.fs.selfExePathAlloc(alloc);
    if (std.mem.eql(u8, artifact, executable)) return error.UpdateArtifactIsRunningExecutable;
    const parent = std.fs.path.dirname(executable) orelse return error.BadPathName;
    var dir = try std.fs.openDirAbsolute(parent, .{});
    defer dir.close();
    try source.seekTo(0);
    var write_buffer: [64 * 1024]u8 = undefined;
    var atomic = try dir.atomicFile(std.fs.path.basename(executable), .{ .mode = 0o755, .write_buffer = &write_buffer });
    defer atomic.deinit();
    while (true) {
        const count = try source.read(&buffer);
        if (count == 0) break;
        try atomic.file_writer.interface.writeAll(buffer[0..count]);
    }
    try atomic.finish();
    return p.object(alloc, .{ .updated = p.boolean(true), .path = p.str(executable), .restart_required = p.boolean(true) });
}

pub fn collectDiagnostics(alloc: std.mem.Allocator, destination: []const u8) !p.Value {
    if (!std.fs.path.isAbsolute(destination)) return error.AbsolutePathRequired;
    const parent = std.fs.path.dirname(destination) orelse return error.BadPathName;
    try std.fs.cwd().makePath(parent);
    const state_path = try xdg.state(alloc, .{ .subdir = "colm" });
    const config_path = try xdg.config(alloc, .{ .subdir = "colm" });
    const payload = try std.json.Stringify.valueAlloc(alloc, .{
        .schema_version = 1,
        .generated_unix_ms = std.time.milliTimestamp(),
        .application = "Colm",
        .version = build_config.version_string,
        .platform = @tagName(builtin.os.tag),
        .architecture = @tagName(builtin.cpu.arch),
        .display_protocol = std.posix.getenv("XDG_SESSION_TYPE") orelse "unknown",
        .desktop = std.posix.getenv("XDG_CURRENT_DESKTOP") orelse "unknown",
        .paths = .{ .state = state_path, .config = config_path },
        .privacy = "No environment values, terminal contents, credentials, configuration contents, or browser state are included.",
    }, .{ .whitespace = .indent_2 });
    defer alloc.free(payload);
    var dir = try std.fs.openDirAbsolute(parent, .{});
    defer dir.close();
    var write_buffer: [4096]u8 = undefined;
    var atomic = try dir.atomicFile(std.fs.path.basename(destination), .{ .mode = 0o600, .write_buffer = &write_buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(payload);
    try atomic.finish();
    return p.object(alloc, .{ .path = p.str(destination), .bytes = p.integer(@as(i64, @intCast(payload.len))) });
}
