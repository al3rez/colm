const std = @import("std");
const xdg = @import("../../os/xdg.zig");
const p = @import("../../control/protocol.zig");

const filename = "features-v1.json";
const max_bytes = 16 * 1024 * 1024;
const collections = [_][]const u8{
    "groups",  "todos",  "lanes",   "actions",  "layouts",    "trust",    "dock",     "sidebars",
    "feed",    "events", "viewers", "vault",    "tasks",      "sessions", "machines", "publications",
    "devices", "rules",  "agents",  "canvases", "simulators", "policies",
};

fn validCollection(name: []const u8) bool {
    for (collections) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128 or !std.unicode.utf8ValidateSlice(key)) return false;
    for (key) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn empty(alloc: std.mem.Allocator) !p.Value {
    var root: std.json.ObjectMap = .init(alloc);
    try root.put("version", p.integer(1));
    for (collections) |name| try root.put(name, .{ .object = .init(alloc) });
    return .{ .object = root };
}

fn load(alloc: std.mem.Allocator) !p.Value {
    const path = try xdg.state(alloc, .{ .subdir = "colm" });
    defer alloc.free(path);
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return empty(alloc),
        else => return err,
    };
    defer dir.close();
    var file = dir.openFile(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => return empty(alloc),
        else => return err,
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(alloc, max_bytes);
    var value = try std.json.parseFromSliceLeaky(p.Value, alloc, bytes, .{ .allocate = .alloc_always });
    if (value != .object or value.object.get("version") == null or value.object.get("version").? != .integer or value.object.get("version").?.integer != 1)
        return error.InvalidFeatureStore;
    for (collections) |name| {
        if (value.object.get(name)) |collection| {
            if (collection != .object) return error.InvalidFeatureStore;
        } else {
            try value.object.put(name, .{ .object = .init(alloc) });
        }
    }
    return value;
}

fn save(alloc: std.mem.Allocator, value: p.Value) !void {
    const path = try xdg.state(alloc, .{ .subdir = "colm" });
    defer alloc.free(path);
    try std.fs.cwd().makePath(path);
    var dir = try std.fs.openDirAbsolute(path, .{});
    defer dir.close();
    const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{ .whitespace = .indent_2 });
    defer alloc.free(bytes);
    if (bytes.len > max_bytes) return error.FeatureStoreTooLarge;
    var buffer: [4096]u8 = undefined;
    var atomic = try dir.atomicFile(filename, .{ .mode = 0o600, .write_buffer = &buffer });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.finish();
}

pub fn list(alloc: std.mem.Allocator, collection: []const u8) !p.Value {
    if (!validCollection(collection)) return error.InvalidCollection;
    const value = try load(alloc);
    var result: std.array_list.Managed(p.Value) = .init(alloc);
    var iterator = value.object.get(collection).?.object.iterator();
    while (iterator.next()) |entry| try result.append(try p.object(alloc, .{
        .key = p.str(entry.key_ptr.*),
        .value = entry.value_ptr.*,
    }));
    std.mem.sort(p.Value, result.items, {}, struct {
        fn less(_: void, left: p.Value, right: p.Value) bool {
            return std.mem.lessThan(u8, left.object.get("key").?.string, right.object.get("key").?.string);
        }
    }.less);
    return .{ .array = result };
}

pub fn get(alloc: std.mem.Allocator, collection: []const u8, key: []const u8) !p.Value {
    if (!validCollection(collection) or !validKey(key)) return error.InvalidFeatureKey;
    const value = try load(alloc);
    return value.object.get(collection).?.object.get(key) orelse error.NotFound;
}

pub fn set(alloc: std.mem.Allocator, collection: []const u8, key: []const u8, item: p.Value) !void {
    if (!validCollection(collection) or !validKey(key)) return error.InvalidFeatureKey;
    if (item != .object) return error.InvalidFeatureValue;
    var value = try load(alloc);
    try value.object.getPtr(collection).?.object.put(key, item);
    try save(alloc, value);
}

pub fn remove(alloc: std.mem.Allocator, collection: []const u8, key: []const u8) !void {
    if (!validCollection(collection) or !validKey(key)) return error.InvalidFeatureKey;
    var value = try load(alloc);
    if (!value.object.getPtr(collection).?.object.swapRemove(key)) return error.NotFound;
    try save(alloc, value);
}

fn hashPath(path: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &result, .{});
    return result;
}

pub fn trustKey(alloc: std.mem.Allocator, path: []const u8) ![64]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.AbsoluteDirectoryRequired;
    const canonical = try std.fs.realpathAlloc(alloc, path);
    defer alloc.free(canonical);
    if ((try std.fs.cwd().statFile(canonical)).kind != .directory) return error.NotADirectory;
    return std.fmt.bytesToHex(hashPath(canonical), .lower);
}

pub fn trustFingerprint(alloc: std.mem.Allocator, path: []const u8) ![64]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.AbsoluteDirectoryRequired;
    const canonical = try std.fs.realpathAlloc(alloc, path);
    defer alloc.free(canonical);
    if ((try std.fs.cwd().statFile(canonical)).kind != .directory) return error.NotADirectory;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(canonical);
    hash.update(&.{0});
    const config_path = try std.fs.path.join(alloc, &.{ canonical, "cmux.json" });
    defer alloc.free(config_path);
    if (std.fs.openFileAbsolute(config_path, .{})) |file_value| {
        var file = file_value;
        defer file.close();
        if ((try file.stat()).size > 4 * 1024 * 1024) return error.ProjectConfigTooLarge;
        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const count = try file.read(&buffer);
            if (count == 0) break;
            hash.update(buffer[0..count]);
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}
