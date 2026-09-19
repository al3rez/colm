const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.config);

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    if (builtin.os.tag == .linux) try migrateColumnSettings(alloc);
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = if (builtin.os.tag == .linux) "colm/config.ghostty" else "ghostty/config.ghostty" },
    );
}

/// Ghostty <1.3.0 default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn legacyDefaultXdgPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = if (builtin.os.tag == .linux) "colm/config" else "ghostty/config" },
    );
}

/// Copy the old application's settings once, without changing the source or
/// replacing any destination entry. All traversal below the trusted XDG root
/// uses directory handles and refuses symlinks, including concurrent swaps.
fn migrateColumnSettings(alloc: Allocator) !void {
    const root_path = try internal_os.xdg.config(alloc, .{});
    defer alloc.free(root_path);
    var root = std.fs.openDirAbsolute(root_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer root.close();
    var source = root.openDir("column", .{ .iterate = true, .no_follow = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.SymLinkLoop, error.NotDir => {
            log.warn("Column settings migration skipped: source is not a real directory; original retained", .{});
            return;
        },
        else => return err,
    };
    defer source.close();
    std.posix.mkdirat(root.fd, "colm", 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var destination = try root.openDir("colm", .{ .no_follow = true });
    defer destination.close();
    const marker = ".column-migration-complete";
    // A no-follow existence check must not open a user-controlled FIFO.
    _ = std.posix.fstatat(destination.fd, marker, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => {
            // The two main filenames are alternatives, not independent files.
            // Copying config.ghostty over a user's existing legacy `config`
            // would silently change which settings win despite no overwrite.
            const keep_main = try migrationEntryExists(destination, "config.ghostty") or
                try migrationEntryExists(destination, "config");
            try migrateDirectory(source, destination, keep_main);
            var file = destination.createFile(marker, .{ .exclusive = true, .mode = 0o600 }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => return,
                else => return create_err,
            };
            file.close();
            return;
        },
        else => return err,
    };
}

fn migrationEntryExists(dir: std.fs.Dir, name: []const u8) !bool {
    _ = std.posix.fstatat(dir.fd, name, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn migrateDirectory(source: std.fs.Dir, destination: std.fs.Dir, keep_main: bool) anyerror!void {
    var entries = source.iterate();
    while (try entries.next()) |entry| {
        if (keep_main and (std.mem.eql(u8, entry.name, "config") or
            std.mem.eql(u8, entry.name, "config.ghostty"))) continue;
        switch (entry.kind) {
            .directory => {
                var child = try source.openDir(entry.name, .{ .iterate = true, .no_follow = true });
                defer child.close();
                std.posix.mkdirat(destination.fd, entry.name, 0o700) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                var target = destination.openDir(entry.name, .{ .no_follow = true }) catch |err| switch (err) {
                    error.SymLinkLoop, error.NotDir => {
                        log.warn("migration retained existing Colm entry: {s}", .{entry.name});
                        continue;
                    },
                    else => return err,
                };
                defer target.close();
                try migrateDirectory(child, target, false);
            },
            .file => try migrateFile(source, destination, entry.name),
            else => log.warn("migration left non-regular entry in original Column settings: {s}", .{entry.name}),
        }
    }
}

fn migrateFile(source: std.fs.Dir, destination: std.fs.Dir, name: []const u8) !void {
    existing: {
        _ = std.posix.fstatat(destination.fd, name, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| switch (err) {
            error.FileNotFound => break :existing,
            else => return err,
        };
        return;
    }
    const fd = try std.posix.openat(source.fd, name, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
    }, 0);
    var input: std.fs.File = .{ .handle = fd };
    defer input.close();
    const stat = try input.stat();
    if (stat.kind != .file) return error.NotAFile;

    // Stage bytes privately, then link the complete file into place. linkat
    // never replaces an existing file, directory, or dangling symlink.
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    var name_buffer: [64]u8 = undefined;
    const temporary = try std.fmt.bufPrint(&name_buffer, ".colm-migrate-{x}", .{random});
    var output = try destination.createFile(temporary, .{ .exclusive = true, .mode = stat.mode & 0o700 });
    defer output.close();
    defer destination.deleteFile(temporary) catch {};
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const count = try input.read(&buffer);
        if (count == 0) break;
        try output.writeAll(buffer[0..count]);
    }
    try output.sync();
    std.posix.linkat(destination.fd, temporary, destination.fd, name, 0) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Preferred default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    // If the XDG path exists, use that.
    const xdg_path = try defaultXdgPath(alloc);
    if (open(xdg_path)) |f| {
        f.close();
        return xdg_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(xdg_path);
    const legacy_xdg_path = try legacyDefaultXdgPath(alloc);
    if (open(legacy_xdg_path)) |f| {
        f.close();
        alloc.free(xdg_path);
        return legacy_xdg_path;
    } else |_| {}

    // Legacy path and XDG path both don't exist. Return the
    // new one.
    alloc.free(legacy_xdg_path);
    return xdg_path;
}

/// Default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config.ghostty");
}

/// Ghostty <1.3.0 default path for the macOS Application Support
/// configuration file. Returned value must be freed by the caller.
pub fn legacyDefaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config");
}

/// Preferred default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn preferredAppSupportPath(alloc: Allocator) ![]const u8 {
    // If the app support path exists, use that.
    const app_support_path = try defaultAppSupportPath(alloc);
    if (open(app_support_path)) |f| {
        f.close();
        return app_support_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(app_support_path);
    const legacy_app_support_path = try legacyDefaultAppSupportPath(alloc);
    if (open(legacy_app_support_path)) |f| {
        f.close();
        alloc.free(app_support_path);
        return legacy_app_support_path;
    } else |_| {}

    // Legacy path and app support path both don't exist. Return the
    // new one.
    alloc.free(legacy_app_support_path);
    return app_support_path;
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            // macOS prefers the Application Support directory
            // if it exists.
            const app_support_path = try preferredAppSupportPath(alloc);
            const app_support_file = open(app_support_path) catch {
                // Try the XDG path if it exists
                const xdg_path = try preferredXdgPath(alloc);
                const xdg_file = open(xdg_path) catch {
                    // If neither file exists, use app support
                    alloc.free(xdg_path);
                    return app_support_path;
                };
                xdg_file.close();
                alloc.free(app_support_path);
                return xdg_path;
            };
            app_support_file.close();
            return app_support_path;
        },

        // All other platforms use XDG only
        else => return try preferredXdgPath(alloc),
    }
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(path: []const u8) OpenFileError!std.fs.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close();

    const stat = file.stat() catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}
