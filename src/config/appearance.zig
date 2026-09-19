const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const args = @import("../cli/args.zig");
const file_load = @import("file_load.zig");
const formatter = @import("formatter.zig");
const themepkg = @import("theme.zig");

const log = std.log.scoped(.appearance);

pub const Scheme = enum { system, light, dark };

pub const Preferences = struct {
    scheme: Scheme = .system,
    inherit_terminal_colors: bool = false,
    theme: ?[]const u8 = null,
};

pub const Color = struct { r: u8, g: u8, b: u8 };

pub const Theme = struct {
    name: [:0]const u8,
    foreground: Color,
    background: Color,
    palette: [16]Color,
};

/// The managed file deliberately contains only appearance overrides. In
/// particular, an absent theme leaves the user's main configuration in charge.
const Managed = struct {
    @"gtk-color-scheme": Scheme = .system,
    @"window-theme": Config.WindowTheme = .system,
    theme: ?[]const u8 = null,
    _arena: ?std.heap.ArenaAllocator = null,
};

fn configPath(alloc: Allocator) ![]const u8 {
    const preferred = try file_load.preferredDefaultFilePath(alloc);
    defer alloc.free(preferred);
    return std.fs.path.join(alloc, &.{
        std.fs.path.dirname(preferred) orelse return error.BadPathName,
        "auto",
        "appearance.ghostty",
    });
}

/// Read before parsing so an I/O error or overlong line cannot become a
/// successfully parsed, truncated configuration in LineIterator.
fn readFile(alloc: Allocator, path: []const u8) ![]const u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    if ((try file.stat()).kind != .file) return error.NotAFile;
    const content = try file.readToEndAlloc(alloc, 1024 * 1024);
    errdefer alloc.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len > args.LineIterator.MAX_LINE_SIZE - 2)
            return error.ConfigLineTooLong;
    }
    return content;
}

fn withoutBom(content: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, content, "\xef\xbb\xbf")) content[3..] else content;
}

/// Returns an owned snapshot of the managed preferences, not the main config.
pub fn load(alloc: Allocator) !Preferences {
    const path = try configPath(alloc);
    defer alloc.free(path);
    const content = readFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer alloc.free(content);

    var managed: Managed = .{};
    defer if (managed._arena) |arena| arena.deinit();
    var reader: std.Io.Reader = .fixed(withoutBom(content));
    var iter: args.LineIterator = .{ .r = &reader, .filepath = path };
    try args.parse(Managed, alloc, &managed, &iter);
    if (managed.theme) |name| try validateThemeName(name);
    return .{
        .scheme = managed.@"gtk-color-scheme",
        .inherit_terminal_colors = managed.@"window-theme" == .ghostty,
        .theme = if (managed.theme) |name| try alloc.dupe(u8, name) else null,
    };
}

pub fn deinit(alloc: Allocator, prefs: *Preferences) void {
    if (prefs.theme) |name| alloc.free(name);
    prefs.* = .{};
}

/// Load into the ordinary configuration replay stream without invoking the
/// default-file or recursive-file loaders again. Only the three managed
/// appearance keys are applied; command/env/keybind in a stale file cannot
/// override the user's real config.
pub fn loadConfig(alloc: Allocator, config: *Config) !void {
    var prefs = try load(alloc);
    defer deinit(alloc, &prefs);
    config.@"gtk-color-scheme" = prefs.scheme;
    if (prefs.inherit_terminal_colors) config.@"window-theme" = .ghostty;
    if (prefs.theme) |name| {
        if (config.theme) |old| {
            alloc.free(old.light);
            if (old.dark.ptr != old.light.ptr) alloc.free(old.dark);
        }
        const light = try alloc.dupe(u8, name);
        errdefer alloc.free(light);
        const dark = try alloc.dupe(u8, name);
        config.theme = .{ .light = light, .dark = dark };
    }
}

/// Theme names must round-trip as one literal Ghostty theme value. Ghostty
/// reserves comma, colon and equals for conditional theme expressions.
fn validateThemeName(name: []const u8) !void {
    if (name.len == 0 or name.len > args.LineIterator.MAX_LINE_SIZE - 16 or
        !std.unicode.utf8ValidateSlice(name) or
        !std.mem.eql(u8, name, std.mem.trim(u8, name, args.whitespace)))
        return error.InvalidThemeName;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f or c == ',' or c == ':' or c == '=')
            return error.InvalidThemeName;
    }
    if (name[0] == '"' and name[name.len - 1] == '"')
        return error.InvalidThemeName;
    if (!std.fs.path.isAbsolute(name) and
        !std.mem.eql(u8, name, std.fs.path.basename(name)))
        return error.InvalidThemeName;
}

pub fn save(alloc: Allocator, prefs: Preferences) !void {
    if (prefs.theme) |name| try validateThemeName(name);
    const path = try configPath(alloc);
    defer alloc.free(path);
    const parent = std.fs.path.dirname(path) orelse return error.BadPathName;
    try std.fs.cwd().makePath(parent);
    var dir = try std.fs.openDirAbsolute(parent, .{});
    defer dir.close();

    var buffer: [4096]u8 = undefined;
    var atomic = try dir.atomicFile(std.fs.path.basename(path), .{
        .mode = 0o600,
        .write_buffer = &buffer,
    });
    defer atomic.deinit();
    const writer = &atomic.file_writer.interface;
    try formatter.formatEntry(Scheme, "gtk-color-scheme", prefs.scheme, writer);
    const window_theme: Config.WindowTheme = if (prefs.inherit_terminal_colors)
        .ghostty
    else switch (prefs.scheme) {
        .system => .system,
        .light => .light,
        .dark => .dark,
    };
    try formatter.formatEntry(Config.WindowTheme, "window-theme", window_theme, writer);
    if (prefs.theme) |name| try formatter.formatEntry([]const u8, "theme", name, writer);
    try atomic.finish();
}

/// Themes follow precisely the terminal's user-before-resources search order.
/// Only the name and preview colors survive each parse, not a full Config.
pub fn listThemes(arena_alloc: Allocator) ![]Theme {
    var themes: std.ArrayList(Theme) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena_alloc);
    // The caller's allocator is an arena, so use independent transient storage
    // rather than retaining every theme's parser state in that arena.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var locations: themepkg.LocationIterator = .{ .arena_alloc = arena_alloc };
    while (try locations.next()) |location| {
        var dir = std.fs.cwd().openDir(location.dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                log.warn("cannot list themes path={s} err={}", .{ location.dir, err });
                continue;
            },
        };
        defer dir.close();
        var entries = dir.iterate();
        while (try entries.next()) |entry| {
            // Claim names even when the overriding entry is unusable: the
            // terminal would not fall back to a packaged duplicate either.
            if (seen.contains(entry.name)) continue;
            const name = try arena_alloc.dupeZ(u8, entry.name);
            try seen.put(arena_alloc, name, {});
            switch (entry.kind) {
                .file, .sym_link => {},
                else => continue,
            }
            validateThemeName(name) catch |err| {
                log.warn("skipping theme name={s} err={}", .{ name, err });
                continue;
            };
            _ = scratch.reset(.retain_capacity);
            const alloc = scratch.allocator();
            const path = try std.fs.path.join(alloc, &.{ location.dir, name });
            const preview = readTheme(alloc, path, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound => {
                    // A dangling symlink or vanished file does allow the
                    // terminal's lookup to continue to the next directory.
                    _ = seen.remove(name);
                    continue;
                },
                else => {
                    log.warn("skipping theme path={s} err={}", .{ path, err });
                    continue;
                },
            };
            try themes.append(arena_alloc, preview);
        }
    }
    std.mem.sortUnstable(Theme, themes.items, {}, struct {
        fn lessThan(_: void, lhs: Theme, rhs: Theme) bool {
            return switch (std.ascii.orderIgnoreCase(lhs.name, rhs.name)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, lhs.name, rhs.name),
            };
        }
    }.lessThan);
    return themes.toOwnedSlice(arena_alloc);
}

fn readTheme(alloc: Allocator, path: []const u8, name: [:0]const u8) !Theme {
    const content = try readFile(alloc, path);
    defer alloc.free(content);
    if (std.mem.trim(u8, withoutBom(content), " \t\r\n").len == 0)
        return error.EmptyTheme;
    var config = try Config.default(alloc);
    defer config.deinit();
    var reader: std.Io.Reader = .fixed(withoutBom(content));
    var iter: args.LineIterator = .{ .r = &reader, .filepath = path };
    try config.loadIter(alloc, &iter);
    if (!config._diagnostics.empty()) return error.InvalidTheme;
    // The parser starts with Ghostty's real defaults for omitted colors,
    // exactly as loading this file as a terminal theme does.
    var result: Theme = .{
        .name = name,
        .foreground = rgb(config.foreground),
        .background = rgb(config.background),
        .palette = undefined,
    };
    for (config.palette.value[0..16], &result.palette) |source, *dest| {
        dest.* = .{ .r = source.r, .g = source.g, .b = source.b };
    }
    return result;
}

fn rgb(color: Config.Color) Color {
    return .{ .r = color.r, .g = color.g, .b = color.b };
}
