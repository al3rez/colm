const std = @import("std");
pub const Value = std.json.Value;
pub const Result = union(enum) { ok: Value, err: []const u8 };
pub const Callback = *const fn (*anyopaque, Result) void;

pub fn string(value: Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidParams;
    const field = value.object.get(name) orelse return error.MissingParameter;
    if (field != .string) return error.InvalidParams;
    if (std.mem.indexOfScalar(u8, field.string, 0) != null) return error.InvalidParams;
    return field.string;
}
pub fn optionalString(value: Value, name: []const u8) !?[]const u8 {
    if (value != .object) return error.InvalidParams;
    const field = value.object.get(name) orelse return null;
    if (field == .null) return null;
    if (field != .string or std.mem.indexOfScalar(u8, field.string, 0) != null)
        return error.InvalidParams;
    return field.string;
}
pub fn object(alloc: std.mem.Allocator, fields: anytype) !Value {
    var result: std.json.ObjectMap = .init(alloc);
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
        try result.put(field.name, @field(fields, field.name));
    }
    return .{ .object = result };
}
pub fn str(value: []const u8) Value {
    return .{ .string = value };
}
pub fn boolean(value: bool) Value {
    return .{ .bool = value };
}
pub fn integer(value: anytype) Value {
    return .{ .integer = @intCast(value) };
}
