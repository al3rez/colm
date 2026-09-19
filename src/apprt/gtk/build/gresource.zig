//! This file contains a binary helper that builds our gresource XML
//! file that we can then use with `glib-compile-resources`.
//!
//! This binary is expected to be run from the Ghostty source root.
//! Litmus test: `src/apprt/gtk` should exist relative to the pwd.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Prefix/appid for the gresource file.
pub const prefix = "/io/github/al3rez/Colm";
pub const app_id = "io.github.al3rez.Colm";

/// Full-color artwork, rasterized for native icon sizes.
pub const icon_sizes = [_]u16{ 16, 24, 32, 48, 64, 96, 128, 192, 256, 512, 1024 };
pub const icon_variants = [_][]const u8{ "", "-dark" };

/// Symbolic status icons, recolored by GTK like any -symbolic icon.
pub const symbolic_icons = [_][]const u8{
    "colm-task-none",
    "colm-task-filled",
    "colm-task-blocked",
    "colm-pin",
};

/// The path to the symbolic icon sources.
pub const icons_path = "src/apprt/gtk/icons";

/// The path to the Blueprint files. The folder structure is expected to be
/// `{version}/{name}.blp` where `version` is the major and minor
/// minimum adwaita version.
pub const ui_path = "src/apprt/gtk/ui";

/// The path to the CSS files.
pub const css_path = "src/apprt/gtk/css";

/// The blueprint files that we will embed into the gresource file.
/// We can't look these up at runtime [easily] because we require the
/// compiled UI files as input. We can refactor this lator to maybe do
/// all of this automatically and ensure we have the right dependencies
/// setup in the build system.
///
/// These will be asserted to exist at runtime.
pub const blueprints: []const Blueprint = &.{
    .{ .major = 1, .minor = 0, .name = "clipboard-confirmation-dialog" },
    .{ .major = 1, .minor = 4, .name = "clipboard-confirmation-dialog" },
    .{ .major = 1, .minor = 2, .name = "close-confirmation-dialog" },
    .{ .major = 1, .minor = 2, .name = "config-errors-dialog" },
    .{ .major = 1, .minor = 2, .name = "debug-warning" },
    .{ .major = 1, .minor = 3, .name = "debug-warning" },
    .{ .major = 1, .minor = 5, .name = "imgui-widget" },
    .{ .major = 1, .minor = 5, .name = "inspector-widget" },
    .{ .major = 1, .minor = 5, .name = "inspector-window" },
    .{ .major = 1, .minor = 2, .name = "resize-overlay" },
    .{ .major = 1, .minor = 2, .name = "search-overlay" },
    .{ .major = 1, .minor = 2, .name = "key-state-overlay" },
    .{ .major = 1, .minor = 5, .name = "split-tree" },
    .{ .major = 1, .minor = 2, .name = "surface" },
    .{ .major = 1, .minor = 5, .name = "surface-scrolled-window" },
    .{ .major = 1, .minor = 3, .name = "surface-child-exited" },
    .{ .major = 1, .minor = 5, .name = "tab" },
    .{ .major = 1, .minor = 5, .name = "title-dialog" },
    .{ .major = 1, .minor = 5, .name = "window" },
    .{ .major = 1, .minor = 5, .name = "command-palette" },
};

/// CSS files in css_path
pub const css = [_][]const u8{
    "style.css",
    "style-dark.css",
    "style-hc.css",
    "style-hc-dark.css",
};

pub const Blueprint = struct {
    major: u16,
    minor: u16,
    name: []const u8,
};

/// The list of filepaths that we depend on. Used for the build
/// system to have proper caching.
pub const file_inputs = deps: {
    const total = icon_sizes.len * icon_variants.len + symbolic_icons.len + blueprints.len + css.len;
    var deps: [total][]const u8 = undefined;
    var index: usize = 0;
    for (icon_variants) |variant| {
        for (icon_sizes) |size| {
            deps[index] = std.fmt.comptimePrint("images/colm{s}/{d}.png", .{ variant, size });
            index += 1;
        }
    }
    for (symbolic_icons) |name| {
        deps[index] = std.fmt.comptimePrint("{s}/{s}-symbolic.svg", .{ icons_path, name });
        index += 1;
    }
    for (blueprints) |bp| {
        deps[index] = std.fmt.comptimePrint("{s}/{d}.{d}/{s}.blp", .{
            ui_path,
            bp.major,
            bp.minor,
            bp.name,
        });
        index += 1;
    }
    for (css) |name| {
        deps[index] = std.fmt.comptimePrint("{s}/{s}", .{ css_path, name });
        index += 1;
    }
    break :deps deps;
};

/// Returns the matching blueprint resource path for the given blueprint
/// definition. This will fail at compile time if the blueprint is not
/// found.
///
/// Must be called at comptime.
pub fn blueprint(comptime bp: Blueprint) [:0]const u8 {
    // The comptime block around this whole thing forces an error if
    // the caller attempts to call this function at runtime.
    comptime {
        for (blueprints) |candidate| {
            if (candidate.major == bp.major and
                candidate.minor == bp.minor and
                std.mem.eql(u8, candidate.name, bp.name))
            {
                return std.fmt.comptimePrint("{s}/ui/{d}.{d}/{s}.ui", .{
                    prefix,
                    candidate.major,
                    candidate.minor,
                    candidate.name,
                });
            }
        }

        @compileError("invalid blueprint");
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    // Collect the UI files that are passed in as arguments.
    var ui_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (ui_files.items) |item| alloc.free(item);
        ui_files.deinit(alloc);
    }
    var it = try std.process.argsWithAllocator(alloc);
    defer it.deinit();
    while (it.next()) |arg| {
        if (!std.mem.endsWith(u8, arg, ".ui")) continue;
        try ui_files.append(
            alloc,
            try alloc.dupe(u8, arg),
        );
    }

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const writer = &stdout.interface;
    try writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<gresources>
        \\
    );

    try genRoot(writer);
    try genIcons(writer);
    try genUi(alloc, writer, &ui_files);

    try writer.writeAll(
        \\</gresources>
        \\
    );

    try stdout.end();
}

/// Embed the default light icon and the alternative dark artwork.
fn genIcons(writer: *std.Io.Writer) !void {
    try writer.print("  <gresource prefix=\"{s}/icons\">\n", .{prefix});
    for (icon_variants) |variant| {
        for (icon_sizes) |size| {
            try writer.print(
                "    <file alias=\"{d}x{d}/apps/{s}{s}.png\">images/colm{s}/{d}.png</file>\n",
                .{ size, size, app_id, variant, variant, size },
            );
        }
    }
    for (symbolic_icons) |name| {
        try writer.print(
            "    <file compressed=\"true\" alias=\"scalable/actions/{s}-symbolic.svg\">{s}/{s}-symbolic.svg</file>\n",
            .{ name, icons_path, name },
        );
    }
    try writer.writeAll("  </gresource>\n");
}

/// Generate the resources at the root prefix.
fn genRoot(writer: *std.Io.Writer) !void {
    try writer.print(
        \\  <gresource prefix="{s}">
        \\
    , .{prefix});

    const cwd = std.fs.cwd();
    inline for (css) |name| {
        const source = std.fmt.comptimePrint(
            "{s}/{s}",
            .{ css_path, name },
        );
        try cwd.access(source, .{});
        try writer.print(
            \\    <file compressed="true" alias="{s}">{s}</file>
            \\
        ,
            .{ name, source },
        );
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}

/// Generate all the UI resources. This works by looking up all the
/// blueprint files in `${ui_path}/{major}.{minor}/{name}.blp` and
/// assuming these will be
fn genUi(
    alloc: Allocator,
    writer: *std.Io.Writer,
    files: *const std.ArrayListUnmanaged([]const u8),
) !void {
    try writer.print(
        \\  <gresource prefix="{s}/ui">
        \\
    , .{prefix});

    for (files.items) |ui_file| {
        for (blueprints) |bp| {
            const expected = try std.fmt.allocPrint(
                alloc,
                "/{d}.{d}/{s}.ui",
                .{ bp.major, bp.minor, bp.name },
            );
            defer alloc.free(expected);
            if (!std.mem.endsWith(u8, ui_file, expected)) continue;
            try writer.print(
                "    <file compressed=\"true\" preprocess=\"xml-stripblanks\" alias=\"{d}.{d}/{s}.ui\">{s}</file>\n",
                .{ bp.major, bp.minor, bp.name, ui_file },
            );
            break;
        } else {
            // The for loop never broke which means it didn't find
            // a matching blueprint for this input.
            return error.BlueprintNotFound;
        }
    }

    try writer.writeAll(
        \\  </gresource>
        \\
    );
}
