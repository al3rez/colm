const std = @import("std");
const p = @import("../../control/protocol.zig");

const max_bytes = 16 * 1024 * 1024;

fn detected(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown")) return "markdown";
    if (std.ascii.eqlIgnoreCase(ext, ".diff") or std.ascii.eqlIgnoreCase(ext, ".patch")) return "diff";
    inline for (.{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg" }) |image|
        if (std.ascii.eqlIgnoreCase(ext, image)) return "image";
    return "text";
}

fn escaped(alloc: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (bytes) |byte| switch (byte) {
        '&' => try out.writer.writeAll("&amp;"),
        '<' => try out.writer.writeAll("&lt;"),
        '>' => try out.writer.writeAll("&gt;"),
        '"' => try out.writer.writeAll("&quot;"),
        else => try out.writer.writeByte(byte),
    };
    return out.toOwnedSlice();
}

fn markdown(alloc: std.mem.Allocator, content: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("<!doctype html><meta charset=utf-8><style>body{font:16px system-ui;max-width:900px;margin:2rem auto;padding:0 1rem}pre{white-space:pre-wrap}</style><article>");
    var lines = std.mem.splitScalar(u8, content, '\n');
    var code = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            try out.writer.writeAll(if (code) "</code></pre>" else "<pre><code>");
            code = !code;
            continue;
        }
        const text = try escaped(alloc, if (!code) std.mem.trimRight(u8, line, "\r") else line);
        if (code) try out.writer.print("{s}\n", .{text}) else if (std.mem.startsWith(u8, line, "### "))
            try out.writer.print("<h3>{s}</h3>", .{text[4..]})
        else if (std.mem.startsWith(u8, line, "## "))
            try out.writer.print("<h2>{s}</h2>", .{text[3..]})
        else if (std.mem.startsWith(u8, line, "# "))
            try out.writer.print("<h1>{s}</h1>", .{text[2..]})
        else if (line.len == 0)
            try out.writer.writeAll("<br>")
        else
            try out.writer.print("<p>{s}</p>", .{text});
    }
    if (code) try out.writer.writeAll("</code></pre>");
    try out.writer.writeAll("</article>");
    return out.toOwnedSlice();
}

fn diff(alloc: std.mem.Allocator, content: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("<!doctype html><meta charset=utf-8><style>body{font:14px monospace;background:#111;color:#ddd}pre{white-space:pre-wrap}.add{background:#15351f}.del{background:#401b1b}.meta{color:#7aa2f7}</style><pre>");
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const class = if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) "add" else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) "del" else if (std.mem.startsWith(u8, line, "@@")) "meta" else "";
        const text = try escaped(alloc, line);
        try out.writer.print("<span class=\"{s}\">{s}</span>\n", .{ class, text });
    }
    try out.writer.writeAll("</pre>");
    return out.toOwnedSlice();
}

pub fn render(alloc: std.mem.Allocator, path: []const u8, requested: ?[]const u8) !p.Value {
    if (!std.fs.path.isAbsolute(path)) return error.AbsolutePathRequired;
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.kind != .file or stat.size > max_bytes) return error.InvalidViewerFile;
    const kind = requested orelse detected(path);
    if (!std.mem.eql(u8, kind, "markdown") and !std.mem.eql(u8, kind, "diff") and !std.mem.eql(u8, kind, "text") and !std.mem.eql(u8, kind, "image")) return error.InvalidViewerType;
    if (std.mem.eql(u8, kind, "image")) return p.object(alloc, .{
        .path = p.str(path),
        .type = p.str(kind),
        .bytes = p.integer(stat.size),
        .live = p.boolean(true),
    });
    const content = try file.readToEndAlloc(alloc, max_bytes);
    if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUTF8;
    const html = if (std.mem.eql(u8, kind, "markdown")) try markdown(alloc, content) else if (std.mem.eql(u8, kind, "diff")) try diff(alloc, content) else null;
    return p.object(alloc, .{
        .path = p.str(path),
        .type = p.str(kind),
        .bytes = p.integer(stat.size),
        .live = p.boolean(true),
        .content = p.str(content),
        .html = if (html) |value| p.str(value) else .null,
    });
}
