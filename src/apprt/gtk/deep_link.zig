const std = @import("std");
const p = @import("../../control/protocol.zig");

pub const Parsed = struct {
    method: []const u8,
    params: p.Value,
    summary: []const u8,
};

fn decode(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    var result = try alloc.alloc(u8, value.len);
    errdefer alloc.free(result);
    var read: usize = 0;
    var write: usize = 0;
    while (read < value.len) : (read += 1) {
        const byte = value[read];
        if (byte == '%') {
            if (read + 2 >= value.len) return error.InvalidPercentEncoding;
            const high = std.fmt.charToDigit(value[read + 1], 16) catch return error.InvalidPercentEncoding;
            const low = std.fmt.charToDigit(value[read + 2], 16) catch return error.InvalidPercentEncoding;
            result[write] = (high << 4) | low;
            read += 2;
        } else if (byte == '+') {
            result[write] = ' ';
        } else {
            result[write] = byte;
        }
        if (result[write] < 0x20 or result[write] == 0x7f) return error.InvalidCharacter;
        write += 1;
    }
    if (!std.unicode.utf8ValidateSlice(result[0..write])) return error.InvalidUTF8;
    return result[0..write];
}

fn validName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    return true;
}

fn allowed(action: []const u8, key: []const u8) bool {
    if (std.mem.eql(u8, action, "prompt") or std.mem.eql(u8, action, "rule"))
        return std.mem.eql(u8, key, "window_id") or std.mem.eql(u8, key, "workspace_id") or
            std.mem.eql(u8, key, "terminal_id") or std.mem.eql(u8, key, "surface_id") or
            std.mem.eql(u8, key, "submit");
    return std.mem.eql(u8, key, "window_id") or std.mem.eql(u8, key, "workspace_id") or
        std.mem.eql(u8, key, "terminal_id") or std.mem.eql(u8, key, "surface_id") or
        std.mem.eql(u8, key, "prompt") or std.mem.eql(u8, key, "resume") or
        std.mem.eql(u8, key, "team") or std.mem.eql(u8, key, "cwd") or
        std.mem.eql(u8, key, "new_pane");
}

fn putQuery(params: *std.json.ObjectMap, action: []const u8, key: []const u8, value: []const u8) !void {
    if (!allowed(action, key)) return error.UnknownParameter;
    if (params.contains(key)) return error.DuplicateParameter;
    if (std.mem.eql(u8, key, "submit") or std.mem.eql(u8, key, "new_pane")) {
        const enabled = if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false"))
            false
        else
            return error.InvalidBoolean;
        try params.put(key, p.boolean(enabled));
    } else {
        if (value.len == 0 or value.len > 1024 * 1024) return error.InvalidValue;
        if (std.mem.eql(u8, key, "cwd") and !std.fs.path.isAbsolute(value)) return error.AbsoluteDirectoryRequired;
        try params.put(key, p.str(value));
    }
}

pub fn parse(alloc: std.mem.Allocator, raw: []const u8) !Parsed {
    if (raw.len == 0 or raw.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(raw)) return error.InvalidURI;
    const scheme_end = std.mem.indexOf(u8, raw, "://") orelse return error.InvalidURI;
    const scheme = raw[0..scheme_end];
    if (!std.mem.eql(u8, scheme, "colm") and !std.mem.eql(u8, scheme, "cmux")) return error.InvalidScheme;
    const remainder = raw[scheme_end + 3 ..];
    const query_start = std.mem.indexOfScalar(u8, remainder, '?');
    const route = if (query_start) |index| remainder[0..index] else remainder;
    const slash = std.mem.indexOfScalar(u8, route, '/') orelse return error.InvalidRoute;
    if (std.mem.indexOfScalar(u8, route[slash + 1 ..], '/') != null) return error.InvalidRoute;
    const action = route[0..slash];
    const encoded_name = route[slash + 1 ..];
    if (!std.mem.eql(u8, action, "prompt") and !std.mem.eql(u8, action, "rule") and !std.mem.eql(u8, action, "agent"))
        return error.InvalidAction;
    const name = try decode(alloc, encoded_name);
    if (!validName(name)) return error.InvalidName;

    var params: std.json.ObjectMap = .init(alloc);
    if (std.mem.eql(u8, action, "agent"))
        try params.put("provider", p.str(name))
    else
        try params.put("name", p.str(name));
    if (query_start) |index| {
        var fields = std.mem.splitScalar(u8, remainder[index + 1 ..], '&');
        while (fields.next()) |field| {
            if (field.len == 0) continue;
            const equal = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidQuery;
            const key = try decode(alloc, field[0..equal]);
            const value = try decode(alloc, field[equal + 1 ..]);
            try putQuery(&params, action, key, value);
        }
    }
    const method = if (std.mem.eql(u8, action, "agent")) "agent.launch" else if (std.mem.eql(u8, action, "prompt")) "prompt.run" else "rule.run";
    const summary = try std.fmt.allocPrint(alloc, "Run {s} {s}", .{ action, name });
    return .{ .method = method, .params = .{ .object = params }, .summary = summary };
}

pub fn confirmationToken(raw: []const u8) [24]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &digest, .{});
    var result: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{x}", .{digest[0..12]}) catch unreachable;
    return result;
}
