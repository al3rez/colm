//! Native WebKitGTK 6 panes. All entry points and callbacks run on the GTK thread.
//! The owner must call destroy before releasing the workspace box. close detaches
//! the UI but retains the owner handle; destroy also releases that handle. Pending
//! native callbacks hold their own references, so closing never frees their data.
//!
//! dispatch params: navigate {uri, timeout_ms?}; snapshot {timeout_ms?};
//! click {generation, ref, timeout_ms?}; fill adds {value}; evaluate
//! {script, generation?, timeout_ms?}; status {}. Generation is a JSON integer.
//! evaluate uses JS eval completion semantics and awaits promises in an isolated
//! world. Results must be JSON-serializable. snapshot replaces the reference set;
//! detached nodes, older snapshots, and changed documents are explicitly rejected.
//! Async requests have a 30s default timeout, configurable from 1 to 120000ms.
const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const gobject = @import("gobject");

const protocol = @import("../../control/protocol.zig");
const SplitTree = @import("class/split_tree.zig").SplitTree;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;


/// automation.zig sets this so a pane can open another column without a cycle.
pub var spawnColumn: ?*const fn (*Pane, []const u8) void = null;

const automation = @embedFile("browser_automation.js");
const world = "colm-automation";
const permission_camera: u8 = 1 << 0;
const permission_microphone: u8 = 1 << 1;
const permission_geolocation: u8 = 1 << 2;
const permission_notifications: u8 = 1 << 3;
const permission_clipboard: u8 = 1 << 4;

const Error = extern struct { domain: u32, code: c_int, message: [*:0]u8 };
const Ready = *const fn (?*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void;
extern fn webkit_network_session_new_ephemeral() *anyopaque;
extern fn webkit_network_session_new([*:0]const u8, [*:0]const u8) *anyopaque;
extern fn webkit_network_session_set_proxy_settings(*anyopaque, c_int, ?*anyopaque) void;
extern fn webkit_network_session_get_cookie_manager(*anyopaque) *anyopaque;
extern fn webkit_cookie_manager_set_persistent_storage(*anyopaque, [*:0]const u8, c_int) void;
extern fn webkit_network_session_set_persistent_credential_storage_enabled(*anyopaque, c_int) void;
extern fn webkit_network_proxy_settings_new([*:0]const u8, [*:null]const ?[*:0]const u8) *anyopaque;
extern fn webkit_network_proxy_settings_add_proxy_for_scheme(*anyopaque, [*:0]const u8, [*:0]const u8) void;
extern fn webkit_network_proxy_settings_free(*anyopaque) void;
extern fn webkit_web_view_get_type() usize;
extern fn webkit_web_view_load_uri(*anyopaque, [*:0]const u8) void;
extern fn webkit_web_view_stop_loading(*anyopaque) void;
extern fn webkit_web_view_is_loading(*anyopaque) c_int;
extern fn webkit_web_view_get_uri(*anyopaque) ?[*:0]const u8;
extern fn webkit_web_view_get_title(*anyopaque) ?[*:0]const u8;
extern fn webkit_web_view_go_back(*anyopaque) void;
extern fn webkit_permission_request_allow(*anyopaque) void;
extern fn webkit_user_media_permission_request_get_type() usize;
extern fn webkit_user_media_permission_is_for_audio_device(*anyopaque) c_int;
extern fn webkit_user_media_permission_is_for_video_device(*anyopaque) c_int;
extern fn webkit_user_media_permission_is_for_display_device(*anyopaque) c_int;
extern fn webkit_geolocation_permission_request_get_type() usize;
extern fn webkit_notification_permission_request_get_type() usize;
extern fn webkit_clipboard_permission_request_get_type() usize;
extern fn g_type_check_instance_is_a(*anyopaque, usize) c_int;
extern fn webkit_web_view_can_go_back(*anyopaque) c_int;
extern fn webkit_web_view_can_go_forward(*anyopaque) c_int;
extern fn webkit_web_view_go_forward(*anyopaque) void;
extern fn webkit_web_view_reload(*anyopaque) void;
extern fn webkit_web_view_get_settings(*anyopaque) *anyopaque;
extern fn webkit_settings_set_enable_webrtc(*anyopaque, c_int) void;
extern fn webkit_web_view_get_snapshot(*anyopaque, c_int, c_int, ?*anyopaque, Ready, ?*anyopaque) void;
extern fn webkit_web_view_get_snapshot_finish(*anyopaque, *anyopaque, *?*Error) ?*anyopaque;
extern fn gdk_texture_save_to_png(*anyopaque, [*:0]const u8) c_int;
extern fn webkit_web_view_download_uri(*anyopaque, [*:0]const u8) ?*anyopaque;
extern fn webkit_script_dialog_get_dialog_type(*anyopaque) c_int;
extern fn webkit_script_dialog_get_message(*anyopaque) [*:0]const u8;
extern fn webkit_script_dialog_confirm_set_confirmed(*anyopaque, c_int) void;
extern fn webkit_script_dialog_prompt_set_text(*anyopaque, [*:0]const u8) void;
extern fn webkit_download_cancel(*anyopaque) void;
extern fn webkit_download_set_destination(*anyopaque, [*:0]const u8) void;
extern fn webkit_settings_set_enable_developer_extras(*anyopaque, c_int) void;
extern fn webkit_web_view_get_inspector(*anyopaque) *anyopaque;
extern fn webkit_web_inspector_show(*anyopaque) void;
extern fn webkit_file_chooser_request_select_files(*anyopaque, [*:null]const ?[*:0]const u8) void;
extern fn webkit_file_chooser_request_cancel(*anyopaque) void;
extern fn webkit_settings_set_enable_media_stream(*anyopaque, c_int) void;
extern fn webkit_settings_set_javascript_can_open_windows_automatically(*anyopaque, c_int) void;
extern fn webkit_settings_set_user_agent(*anyopaque, [*:0]const u8) void;

extern fn webkit_web_view_call_async_javascript_function(*anyopaque, [*]const u8, isize, ?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?*anyopaque, Ready, ?*anyopaque) void;
extern fn webkit_web_view_call_async_javascript_function_finish(*anyopaque, *anyopaque, *?*Error) ?*anyopaque;
extern fn webkit_web_view_evaluate_javascript(*anyopaque, [*]const u8, isize, ?[*:0]const u8, ?[*:0]const u8, ?*anyopaque, ?Ready, ?*anyopaque) void;
extern fn webkit_web_view_get_user_content_manager(*anyopaque) *anyopaque;
extern fn webkit_user_script_new_for_world([*:0]const u8, c_int, c_int, [*:0]const u8, ?*anyopaque, ?*anyopaque) *anyopaque;
extern fn webkit_user_content_manager_add_script(*anyopaque, *anyopaque) void;
extern fn webkit_user_script_new([*:0]const u8, c_int, c_int, ?*anyopaque, ?*anyopaque) *anyopaque;
extern fn webkit_user_content_manager_register_script_message_handler(*anyopaque, [*:0]const u8, ?[*:0]const u8) c_int;
extern fn webkit_user_content_manager_unregister_script_message_handler(*anyopaque, [*:0]const u8, ?[*:0]const u8) void;
extern fn webkit_user_script_unref(*anyopaque) void;
extern fn webkit_navigation_policy_decision_get_navigation_action(*anyopaque) *anyopaque;
extern fn webkit_navigation_action_get_request(*anyopaque) *anyopaque;
extern fn webkit_navigation_action_get_mouse_button(*anyopaque) c_uint;
extern fn webkit_navigation_action_get_modifiers(*anyopaque) c_uint;
extern fn webkit_uri_request_get_uri(*anyopaque) [*:0]const u8;
extern fn webkit_policy_decision_ignore(*anyopaque) void;

extern fn webkit_permission_request_deny(*anyopaque) void;
extern fn jsc_value_to_string(*anyopaque) ?[*:0]u8;
extern fn g_object_new(usize, ?[*:0]const u8, ...) *anyopaque;
extern fn g_object_ref_sink(*anyopaque) *anyopaque;
extern fn g_object_unref(*anyopaque) void;
extern fn g_object_run_dispose(*anyopaque) void;
const console_bridge =
    \\(() => {
    \\  if (globalThis.__colmConsoleBridge) return;
    \\  globalThis.__colmConsoleBridge = true;
    \\  const send = (level, values) => {
    \\    const text = values.map((value) => {
    \\      if (typeof value === "string") return value;
    \\      try { return JSON.stringify(value) ?? String(value); }
    \\      catch { return String(value); }
    \\    }).join(" ").slice(0, 65536);
    \\    window.webkit.messageHandlers.colmConsole.postMessage(level + "\n" + text);
    \\  };
    \\  for (const level of ["debug", "log", "info", "warn", "error"]) {
    \\    const original = console[level];
    \\    console[level] = function(...values) {
    \\      send(level, values);
    \\      return original.apply(this, values);
    \\    };
    \\  }
    \\  addEventListener("error", (event) => send("error", [event.message]));
    \\  addEventListener("unhandledrejection", (event) => send("error", [event.reason]));
    \\})();
;
extern fn g_signal_connect_data(*anyopaque, [*:0]const u8, *const fn () callconv(.c) void, ?*anyopaque, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, c_uint) c_ulong;
extern fn g_signal_handler_disconnect(*anyopaque, c_ulong) void;
extern fn g_cancellable_new() *anyopaque;
extern fn g_cancellable_cancel(*anyopaque) void;
extern fn g_timeout_add(c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) c_uint;
extern fn g_source_remove(c_uint) c_int;
extern fn g_error_free(*Error) void;
extern fn g_free(?*anyopaque) void;

// One isolated session per workspace and route. Ephemeral is the default;
// named profiles persist only inside a route-specific XDG state directory.
// A workspace cannot silently switch proxy or storage profile while panes live.
var sessions: ?*Session = null;
const Session = struct {
    next: ?*Session,
    workspace: *gtk.Box,
    native: *anyopaque,
    proxy: ?[]const u8,
    profile: ?[]const u8,
    refs: usize = 1,
    active: usize = 1,

    fn acquire(workspace: *gtk.Box, proxy: ?[]const u8, profile: ?[]const u8, route_key: []const u8) !*Session {
        var current = sessions;
        while (current) |session| : (current = session.next) {
            if (session.workspace != workspace) continue;
            const same_proxy = if (session.proxy) |old| if (proxy) |new| std.mem.eql(u8, old, new) else false else proxy == null;
            const same_profile = if (session.profile) |old| if (profile) |new| std.mem.eql(u8, old, new) else false else profile == null;
            if (!same_proxy) return error.WorkspaceProxyMismatch;
            if (!same_profile) return error.WorkspaceProfileMismatch;
            session.refs += 1;
            session.active += 1;
            return session;
        }
        const alloc = std.heap.c_allocator;
        const owned_proxy = if (proxy) |uri| try alloc.dupe(u8, uri) else null;
        errdefer if (owned_proxy) |uri| alloc.free(uri);
        const owned_profile = if (profile) |name| try alloc.dupe(u8, name) else null;
        errdefer if (owned_profile) |name| alloc.free(name);
        const session = try alloc.create(Session);
        errdefer alloc.destroy(session);
        const native = if (profile) |name| persistent: {
            if (!validProfile(name)) return error.InvalidProfile;
            const xdg = @import("../../os/xdg.zig");
            const route = std.hash.Wyhash.hash(0, route_key);
            const state_root = try xdg.state(alloc, .{ .subdir = "colm/browser-profiles" });
            defer alloc.free(state_root);
            const cache_root = try xdg.cache(alloc, .{ .subdir = "colm/browser-profiles" });
            defer alloc.free(cache_root);
            const data_path = try std.fmt.allocPrint(alloc, "{s}/{s}/{x}", .{ state_root, name, route });
            defer alloc.free(data_path);
            const cache_path = try std.fmt.allocPrint(alloc, "{s}/{s}/{x}", .{ cache_root, name, route });
            defer alloc.free(cache_path);
            try std.fs.cwd().makePath(data_path);
            try std.fs.cwd().makePath(cache_path);
            const data_z = try alloc.dupeZ(u8, data_path);
            defer alloc.free(data_z);
            const cache_z = try alloc.dupeZ(u8, cache_path);
            defer alloc.free(cache_z);
            const cookie_path = try std.fmt.allocPrint(alloc, "{s}/cookies.sqlite", .{data_path});
            defer alloc.free(cookie_path);
            const cookie_z = try alloc.dupeZ(u8, cookie_path);
            defer alloc.free(cookie_z);
            const persistent_session = webkit_network_session_new(data_z, cache_z);
            webkit_cookie_manager_set_persistent_storage(
                webkit_network_session_get_cookie_manager(persistent_session),
                cookie_z,
                1,
            );
            break :persistent persistent_session;
        } else webkit_network_session_new_ephemeral();
        errdefer g_object_unref(native);
        webkit_network_session_set_persistent_credential_storage_enabled(native, @intFromBool(profile != null));
        if (proxy) |uri| {
            // Only managed loopback SOCKS listeners are permitted. A CUSTOM
            // resolver with an empty exclusion list has NO localhost bypass and
            // NO direct fallback. SOCKS5 resolves destination names remotely.
            const port_text = if (std.mem.startsWith(u8, uri, "socks://127.0.0.1:"))
                uri["socks://127.0.0.1:".len..]
            else if (std.mem.startsWith(u8, uri, "socks5://127.0.0.1:"))
                uri["socks5://127.0.0.1:".len..]
            else
                return error.InvalidProxy;
            const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidProxy;
            if (port == 0) return error.InvalidProxy;
            const normalized = try std.fmt.allocPrintSentinel(alloc, "socks5://127.0.0.1:{d}", .{port}, 0);
            defer alloc.free(normalized);
            const ignore = [_:null]?[*:0]const u8{};
            const settings = webkit_network_proxy_settings_new(normalized, &ignore);
            defer webkit_network_proxy_settings_free(settings);
            inline for (.{ "http", "https", "ws", "wss" }) |scheme|
                webkit_network_proxy_settings_add_proxy_for_scheme(settings, scheme, normalized);
            webkit_network_session_set_proxy_settings(native, 2, settings);
        } else {
            // Do not inherit another desktop/browser profile or proxy settings.
            webkit_network_session_set_proxy_settings(native, 1, null);
        }
        session.* = .{ .next = sessions, .workspace = workspace, .native = native, .proxy = owned_proxy, .profile = owned_profile };
        sessions = session;
        return session;
    }

    fn detach(self: *Session) void {
        self.active -= 1;
        if (self.active != 0) return;
        var link = &sessions;
        while (link.*) |item| {
            if (item == self) {
                link.* = self.next;
                return;
            }
            link = &item.next;
        }
    }

    fn release(self: *Session) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        var link = &sessions;
        while (link.*) |item| {
            if (item == self) {
                link.* = self.next;
                break;
            }
            link = &item.next;
        }
        g_object_unref(self.native);
        if (self.proxy) |uri| std.heap.c_allocator.free(uri);
        if (self.profile) |name| std.heap.c_allocator.free(name);
        std.heap.c_allocator.destroy(self);
    }
};
const DownloadJob = struct {
    item: *anyopaque,
    done: bool = false,

    fn finish(self: *DownloadJob) void {
        if (self.done) return;
        self.done = true;
        g_object_unref(self.item);
        std.heap.c_allocator.destroy(self);
    }
};

const LogEntry = struct {
    text: []const u8,
    source: []const u8,
    level: c_int,
    line: c_uint,
};

pub const Pane = struct {
    alloc: Allocator,
    id: []const u8,
    widget: *gtk.Box,
    entry: *gtk.Entry,
    message: *gtk.Label,
    view: *anyopaque,
    session: *Session,
    disposed: bool = false,
    refs: usize = 1,
    generation: u64 = 0,
    manager: *anyopaque,
    manager_signal: c_ulong,
    last_uri: ?[]const u8 = null,
    last_error: ?[]const u8 = null,
    pending: ?*Operation = null,
    navigation: ?*Operation = null,
    permission_origin: ?[]const u8 = null,
    permissions: u8 = 0,
    pending_upload: ?[:0]u8 = null,
    logs: std.ArrayListUnmanaged(LogEntry) = .empty,
    dialog_accept: bool = false,
    dialog_prompt: ?[:0]u8 = null,
    signals: [9]c_ulong,

    pub fn close(self: *Pane) void {
        if (self.disposed) return;
        self.refs += 1;
        defer self.release();
        self.disposed = true;
        for (self.signals) |signal| g_signal_handler_disconnect(self.view, signal);
        g_signal_handler_disconnect(self.manager, self.manager_signal);
        webkit_user_content_manager_unregister_script_message_handler(self.manager, "colmConsole", null);
        while (self.pending) |op| {
            op.complete(.{ .err = "pane_closed" });
            if (op.kind != .navigation) g_cancellable_cancel(op.cancellable.?) else op.release();
        }
        if (self.widget.as(gtk.Widget).getParent()) |parent| {
            if (gobject.ext.cast(gtk.Box, parent)) |box| {
                box.remove(self.widget.as(gtk.Widget));
                if (parent.hasCssClass("guest-column") != 0) {
                    if (parent.getParent()) |grand| {
                        if (gobject.ext.cast(gtk.Box, grand)) |columns| columns.remove(parent);
                    }
                }
            }
        }

        // Signal data for toolbar controls remains valid until the root widget
        // is destroyed. Pending operations separately retain the WebView.
        g_object_unref(self.widget);
        g_object_run_dispose(self.view);
        self.session.detach();
    }

    pub fn destroy(self: *Pane) void {
        self.close();
        self.release();
    }

    fn release(self: *Pane) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        g_object_unref(self.view);
        g_object_unref(self.entry);
        self.session.release();

        self.alloc.free(self.id);
        if (self.last_uri) |uri| self.alloc.free(uri);
        if (self.last_error) |message| self.alloc.free(message);
        if (self.pending_upload) |path| self.alloc.free(path);
        if (self.permission_origin) |origin| self.alloc.free(origin);
        for (self.logs.items) |entry| {
            self.alloc.free(entry.text);
            self.alloc.free(entry.source);
        }
        self.logs.deinit(self.alloc);
        if (self.dialog_prompt) |text| self.alloc.free(text);
        self.alloc.destroy(self);
    }

    pub fn focus(self: *Pane) bool {
        if (self.disposed) return false;
        const widget: *gtk.Widget = @ptrCast(@alignCast(self.view));
        return widget.grabFocus() != 0;
    }

    fn fail(self: *Pane, message: []const u8) void {
        if (self.last_error) |old| self.alloc.free(old);
        self.last_error = self.alloc.dupe(u8, message) catch null;
        const text = self.alloc.dupeZ(u8, message) catch return;
        defer self.alloc.free(text);
        self.message.setText(text);
        self.message.as(gtk.Widget).setVisible(1);

    }

    fn stageUpload(self: *Pane, path: []const u8) !void {
        if (self.disposed) return error.PaneClosed;
        if (self.pending_upload != null) return error.UploadInProgress;
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null)
            return error.InvalidPath;
        const stat = std.fs.cwd().statFile(path) catch return error.InvalidPath;
        if (stat.kind != .file) return error.InvalidPath;
        self.pending_upload = try self.alloc.dupeZ(u8, path);
    }

    fn appendLog(self: *Pane, text: []const u8, source: []const u8, level: c_int, line: c_uint) void {
        const owned_text = self.alloc.dupe(u8, text) catch return;
        errdefer self.alloc.free(owned_text);
        const owned_source = self.alloc.dupe(u8, source) catch return;
        if (self.logs.items.len == 256) {
            const old = self.logs.orderedRemove(0);
            self.alloc.free(old.text);
            self.alloc.free(old.source);
        }
        self.logs.append(self.alloc, .{
            .text = owned_text,
            .source = owned_source,
            .level = level,
            .line = line,
        }) catch {
            self.alloc.free(owned_text);
            self.alloc.free(owned_source);
        };
    }

    fn logsValue(self: *Pane, alloc: Allocator) !Value {
        var entries: std.array_list.Managed(Value) = .init(alloc);
        for (self.logs.items) |entry| try entries.append(try protocol.object(alloc, .{
            .text = protocol.str(entry.text),
            .source = protocol.str(entry.source),
            .level = protocol.str(consoleLevel(entry.level)),
            .line = protocol.integer(entry.line),
        }));
        return .{ .array = entries };
    }

    fn clearLogs(self: *Pane) void {
        for (self.logs.items) |entry| {
            self.alloc.free(entry.text);
            self.alloc.free(entry.source);
        }
        self.logs.clearRetainingCapacity();
    }

    fn setDialogPolicy(self: *Pane, accept: bool, prompt: ?[]const u8) !void {
        if (self.dialog_prompt) |text| self.alloc.free(text);
        self.dialog_prompt = null;
        self.dialog_accept = accept;
        if (prompt) |text| self.dialog_prompt = try self.alloc.dupeZ(u8, text);
    }

    fn clearUpload(self: *Pane) void {
        if (self.pending_upload) |path| self.alloc.free(path);
        self.pending_upload = null;
    }

    pub fn status(self: *Pane, alloc: Allocator) !Value {
        var result = std.json.ObjectMap.init(alloc);
        try result.put("id", .{ .string = try alloc.dupe(u8, self.id) });
        try result.put("uri", .{ .string = try alloc.dupe(u8, if (self.disposed) self.last_uri orelse "" else zslice(webkit_web_view_get_uri(self.view))) });
        try result.put("title", .{ .string = try alloc.dupe(u8, if (self.disposed) "" else zslice(webkit_web_view_get_title(self.view))) });
        try result.put("generation", .{ .integer = @intCast(self.generation) });
        try result.put("loading", .{ .bool = !self.disposed and webkit_web_view_is_loading(self.view) != 0 });
        try result.put("closed", .{ .bool = self.disposed });
        try result.put("remote", .{ .bool = self.session.proxy != null });
        try result.put("profile", .{ .string = try alloc.dupe(u8, self.session.profile orelse "ephemeral") });
        try result.put("error", if (self.last_error) |message| .{ .string = try alloc.dupe(u8, message) } else .null);
        return .{ .object = result };
    }

    fn permissionValue(self: *Pane, alloc: Allocator) !Value {
        return protocol.object(alloc, .{
            .origin = if (self.permission_origin) |origin| protocol.str(origin) else @as(Value, .null),
            .camera = protocol.str(if (self.permissions & permission_camera != 0) "allowed" else "denied"),
            .microphone = protocol.str(if (self.permissions & permission_microphone != 0) "allowed" else "denied"),
            .geolocation = protocol.str(if (self.permissions & permission_geolocation != 0) "allowed" else "denied"),
            .notifications = protocol.str(if (self.permissions & permission_notifications != 0) "allowed" else "denied"),
            .clipboard = protocol.str(if (self.permissions & permission_clipboard != 0) "allowed" else "denied"),
        });
    }

    fn setPermission(self: *Pane, alloc: Allocator, name: []const u8, allow: bool) !Value {
        const bit = permissionBit(name) orelse return error.InvalidPermission;
        if (allow and self.session.proxy != null and
            (bit == permission_camera or bit == permission_microphone))
            return error.ProxyMediaBlocked;
        if (allow) {
            const uri = zslice(webkit_web_view_get_uri(self.view));
            const origin = uriOrigin(uri) orelse return error.InvalidOrigin;
            if (self.permission_origin == null or
                !std.mem.eql(u8, self.permission_origin.?, origin))
            {
                if (self.permission_origin) |old| self.alloc.free(old);
                self.permission_origin = try self.alloc.dupe(u8, origin);
                self.permissions = 0;
            }
            self.permissions |= bit;
        } else {
            self.permissions &= ~bit;
        }
        const media = self.permissions & (permission_camera | permission_microphone) != 0;
        const settings = webkit_web_view_get_settings(self.view);
        webkit_settings_set_enable_webrtc(settings, @intFromBool(media));
        webkit_settings_set_enable_media_stream(settings, @intFromBool(media));
        return self.permissionValue(alloc);
    }

    pub fn download(self: *Pane, alloc: Allocator, uri: []const u8, path: []const u8) !Value {
        if (self.disposed) return error.PaneClosed;
        if (!allowedUri(uri) or std.mem.indexOfScalar(u8, uri, 0) != null)
            return error.InvalidURI;
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null)
            return error.InvalidPath;
        const uri_z = try alloc.dupeZ(u8, uri);
        defer alloc.free(uri_z);
        const path_z = try alloc.dupeZ(u8, path);
        defer alloc.free(path_z);
        const item = webkit_web_view_download_uri(self.view, uri_z) orelse
            return error.DownloadFailed;
        const job = std.heap.c_allocator.create(DownloadJob) catch {
            webkit_download_cancel(item);
            g_object_unref(item);
            return error.OutOfMemory;
        };
        job.* = .{ .item = item };
        _ = g_signal_connect_data(item, "finished", @ptrCast(&downloadFinished), job, null, 0);
        _ = g_signal_connect_data(item, "failed", @ptrCast(&downloadFailed), job, null, 0);
        webkit_download_set_destination(item, path_z);
        return protocol.object(alloc, .{
            .uri = protocol.str(uri),
            .path = protocol.str(path),
            .started = protocol.boolean(true),
        });
    }

    pub fn showDevtools(self: *Pane) bool {
        if (self.disposed) return false;
        webkit_settings_set_enable_developer_extras(
            webkit_web_view_get_settings(self.view),
            1,
        );
        webkit_web_inspector_show(webkit_web_view_get_inspector(self.view));
        return true;
    }

    pub fn currentUri(self: *const Pane) []const u8 {
        if (self.last_uri) |uri| return uri;
        return "";
    }

    pub fn loadUri(self: *Pane, uri: []const u8) void {
        if (self.disposed) return;
        if (!allowedUri(uri) or std.mem.indexOfScalar(u8, uri, 0) != null) return;
        const uri_z = self.alloc.dupeZ(u8, uri) catch return;
        defer self.alloc.free(uri_z);
        webkit_web_view_load_uri(self.view, uri_z);
    }

    pub fn setDevice(self: *Pane, width: c_int, height: c_int, user_agent: ?[]const u8) void {
        if (self.disposed) return;
        self.widget.as(gtk.Widget).setSizeRequest(width, height);
        if (user_agent) |agent| {
            const agent_z = self.alloc.dupeZ(u8, agent) catch return;
            defer self.alloc.free(agent_z);
            webkit_settings_set_user_agent(webkit_web_view_get_settings(self.view), agent_z);
        }
    }


};

const Operation = struct {
    pane: *Pane,
    next: ?*Operation,
    alloc: Allocator,
    ctx: *anyopaque,
    callback: protocol.Callback,
    kind: enum { navigation, javascript, screenshot, upload },
    generation: u64,
    timer: c_uint = 0,
    cancellable: ?*anyopaque = null,
    done: bool = false,
    started: bool = false,
    same_document: bool = false,
    destination: ?[]const u8 = null,

    fn new(pane: *Pane, alloc: Allocator, ctx: *anyopaque, callback: protocol.Callback, kind: @FieldType(Operation, "kind"), timeout: u32) !*Operation {
        const op = try pane.alloc.create(Operation);
        op.* = .{ .pane = pane, .next = pane.pending, .alloc = alloc, .ctx = ctx, .callback = callback, .kind = kind, .generation = pane.generation };
        pane.refs += 1;
        pane.pending = op;
        op.timer = g_timeout_add(timeout, timedOut, op);
        return op;
    }

    fn complete(self: *Operation, result: protocol.Result) void {
        if (self.done) return;
        self.done = true;
        if (self.timer != 0) {
            _ = g_source_remove(self.timer);
            self.timer = 0;
        }
        if (self.pane.navigation == self) self.pane.navigation = null;
        if (self.kind == .upload) self.pane.clearUpload();
        var link = &self.pane.pending;
        while (link.*) |item| {
            if (item == self) {
                link.* = self.next;
                break;
            }
            link = &item.next;
        }
        // Callback may release the request arena. Never inspect params or
        // allocate from self.alloc after invoking it.
        self.callback(self.ctx, result);
    }

    fn release(self: *Operation) void {
        const pane = self.pane;
        if (self.cancellable) |cancel| g_object_unref(cancel);
        pane.alloc.destroy(self);
        pane.release();
    }

    fn timedOut(data: ?*anyopaque) callconv(.c) c_int {
        const op: *Operation = @ptrCast(@alignCast(data.?));
        op.timer = 0;
        op.complete(.{ .err = "timeout" });
        if (op.kind != .navigation) {
            g_cancellable_cancel(op.cancellable.?);
        } else {
            webkit_web_view_stop_loading(op.pane.view);
            op.release();
        }
        return 0;
    }
};

pub fn create(alloc: Allocator, workspace: *gtk.Box, tree: *SplitTree, id: []const u8, proxy_uri: ?[]const u8, profile: ?[]const u8, route_key: []const u8) !*Pane {

    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const session = try Session.acquire(workspace, proxy_uri, profile, route_key);
    errdefer {
        session.detach();
        session.release();
    }
    const pane = try alloc.create(Pane);
    const root = gtk.Box.new(.vertical, 0);
    _ = g_object_ref_sink(root);
    root.as(gtk.Widget).addCssClass("browser-pane");
    root.as(gtk.Widget).setHexpand(1);
    root.as(gtk.Widget).setVexpand(1);
    root.as(gtk.Widget).setHalign(.fill);
    root.as(gtk.Widget).setValign(.fill);

    // Off-tree: uriChanged still writes the buffer. No cmux URL chrome.
    const entry = gtk.Entry.new();
    _ = g_object_ref_sink(entry);


    const message = gtk.Label.new(null);
    message.setXalign(0);
    message.setWrap(1);
    message.as(gtk.Widget).addCssClass("browser-message");
    message.as(gtk.Widget).setVisible(0);
    root.append(message.as(gtk.Widget));

    const view = g_object_new(webkit_web_view_get_type(), "network-session", session.native, @as(?[*:0]const u8, null));
    _ = g_object_ref_sink(view);
    const manager = webkit_web_view_get_user_content_manager(view);
    const manager_signal = g_signal_connect_data(manager, "script-message-received::colmConsole", @ptrCast(&consoleMessage), pane, null, 0);
    if (webkit_user_content_manager_register_script_message_handler(manager, "colmConsole", null) == 0)
        return error.ConsoleBridgeUnavailable;
    const console_script = webkit_user_script_new(console_bridge, 0, 1, null, null);
    webkit_user_content_manager_add_script(manager, console_script);
    webkit_user_script_unref(console_script);
    // Retain the named world across separate async evaluations. Without a user
    // script WebKit can discard it after each call, invalidating all snapshot refs.
    const script = webkit_user_script_new_for_world("globalThis.__colmAutomation = undefined;", 1, 0, world, null, null);
    webkit_user_content_manager_add_script(manager, script);
    webkit_user_script_unref(script);
    const settings = webkit_web_view_get_settings(view);
    webkit_settings_set_enable_developer_extras(settings, 1);

    // WebRTC can bypass an HTTP/SOCKS proxy with direct UDP; disable it, deny
    // native permission prompts by default, and expose only a bounded log bridge.
    webkit_settings_set_enable_webrtc(settings, 0);
    webkit_settings_set_enable_media_stream(settings, 0);
    webkit_settings_set_javascript_can_open_windows_automatically(settings, 0);
    const view_widget: *gtk.Widget = @ptrCast(@alignCast(view));
    view_widget.setHexpand(1);
    view_widget.setVexpand(1);
    view_widget.setHalign(.fill);
    view_widget.setValign(.fill);
    const stage = gtk.Overlay.new();
    stage.as(gtk.Widget).setHexpand(1);
    stage.as(gtk.Widget).setVexpand(1);
    stage.as(gtk.Widget).setHalign(.fill);
    stage.as(gtk.Widget).setValign(.fill);
    stage.setChild(view_widget);
    root.append(stage.as(gtk.Widget));


    pane.* = .{ .alloc = alloc, .id = owned_id, .widget = root, .entry = entry, .message = message, .view = view, .manager = manager, .manager_signal = manager_signal, .session = session, .signals = .{
        connect(view, "load-changed", &loadChanged, pane),
        connect(view, "load-failed", &loadFailed, pane),
        connect(view, "notify::uri", &uriChanged, pane),
        connect(view, "script-dialog", &scriptDialog, pane),
        connect(view, "notify::is-loading", &loadingChanged, pane),
        connect(view, "decide-policy", &decidePolicy, pane),
        connect(view, "permission-request", &permissionRequested, pane),
        connect(view, "web-process-terminated", &processTerminated, pane),
        connect(view, "run-file-chooser", &runFileChooser, pane),
    } };
    _ = connect(entry, "activate", &entryActivated, pane);
    const keys = gtk.EventControllerKey.new();
    keys.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.EventControllerKey.signals.key_pressed.connect(keys, *Pane, columnKey, pane, .{});
    root.as(gtk.Widget).addController(keys.as(gtk.EventController));
    const right = gtk.GestureClick.new();
    right.as(gtk.GestureSingle).setButton(3);
    right.as(gtk.EventController).setPropagationPhase(.capture);
    _ = gtk.GestureClick.signals.pressed.connect(right, *Pane, showColumnMenu, pane, .{});
    root.as(gtk.Widget).addController(right.as(gtk.EventController));


    tree.appendGuestColumn(root.as(gtk.Widget));

    return pane;
}

pub fn dispatch(pane: *Pane, alloc: Allocator, method: []const u8, params: Value, ctx: *anyopaque, callback: protocol.Callback) void {
    if (std.mem.eql(u8, method, "browser.status")) {
        const value = pane.status(alloc) catch return callback(ctx, .{ .err = "out_of_memory" });
        return callback(ctx, .{ .ok = value });
    }
    if (std.mem.eql(u8, method, "browser.permissions")) {
        const value = pane.permissionValue(alloc) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        return callback(ctx, .{ .ok = value });
    }
    if (std.mem.eql(u8, method, "browser.permission")) {
        if (pane.disposed) return callback(ctx, .{ .err = "pane_closed" });
        const name = stringParam(params, "name") orelse
            return callback(ctx, .{ .err = "invalid_params: permission name required" });
        const allow = if (params == .object and params.object.get("allow") != null)
            params.object.get("allow").? == .bool and params.object.get("allow").?.bool
        else
            false;
        const deny = if (params == .object and params.object.get("deny") != null)
            params.object.get("deny").? == .bool and params.object.get("deny").?.bool
        else
            false;
        if (allow == deny)
            return callback(ctx, .{ .err = "invalid_params: exactly one of allow or deny is required" });
        const value = pane.setPermission(alloc, name, allow) catch |err|
            return callback(ctx, .{ .err = switch (err) {
                error.InvalidPermission => "invalid_permission",
                error.InvalidOrigin => "invalid_origin",
                error.ProxyMediaBlocked => "proxy_media_blocked",
                else => "out_of_memory",
            } });
        return callback(ctx, .{ .ok = value });
    }
    if (std.mem.eql(u8, method, "browser.download")) {
        const uri = stringParam(params, "uri") orelse
            return callback(ctx, .{ .err = "invalid_params: uri required" });
        const path = stringParam(params, "path") orelse
            return callback(ctx, .{ .err = "invalid_params: path required" });
        const value = pane.download(alloc, uri, path) catch |err|
            return callback(ctx, .{ .err = switch (err) {
                error.InvalidURI => "invalid_uri",
                error.InvalidPath => "invalid_path",
                error.PaneClosed => "pane_closed",
                error.DownloadFailed => "download_failed",
                else => "out_of_memory",
            } });
        return callback(ctx, .{ .ok = value });
    }
    if (std.mem.eql(u8, method, "browser.devtools")) {
        if (!pane.showDevtools()) return callback(ctx, .{ .err = "pane_closed" });
        const value = pane.status(alloc) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        return callback(ctx, .{ .ok = value });
    }
    if (pane.disposed) return callback(ctx, .{ .err = "pane_closed" });
    if (params != .object) return callback(ctx, .{ .err = "invalid_params: expected object" });
    if (std.mem.eql(u8, method, "browser.logs")) {
        const value = pane.logsValue(alloc) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        return callback(ctx, .{ .ok = value });
    }
    if (std.mem.eql(u8, method, "browser.logs-clear")) {
        pane.clearLogs();
        return callback(ctx, .{ .ok = .null });
    }
    if (std.mem.eql(u8, method, "browser.dialog-policy")) {
        const action = stringParam(params, "action") orelse
            return callback(ctx, .{ .err = "invalid_params: action required" });
        const accept = if (std.mem.eql(u8, action, "accept"))
            true
        else if (std.mem.eql(u8, action, "dismiss"))
            false
        else
            return callback(ctx, .{ .err = "invalid_params: action must be accept or dismiss" });
        pane.setDialogPolicy(accept, stringParam(params, "prompt")) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        const value = protocol.object(alloc, .{
            .action = protocol.str(action),
            .prompt = if (pane.dialog_prompt) |text| protocol.str(text) else @as(Value, .null),
        }) catch return callback(ctx, .{ .err = "out_of_memory" });
        return callback(ctx, .{ .ok = value });
    }
    if (std.mem.eql(u8, method, "browser.viewport")) {
        const width = params.object.get("width") orelse
            return callback(ctx, .{ .err = "invalid_params: width required" });
        const height = params.object.get("height") orelse
            return callback(ctx, .{ .err = "invalid_params: height required" });
        if (width != .integer or height != .integer or width.integer < 240 or
            height.integer < 200 or width.integer > 8192 or height.integer > 8192)
            return callback(ctx, .{ .err = "invalid_params: viewport must be 240..8192 by 200..8192" });
        pane.widget.as(gtk.Widget).setSizeRequest(@intCast(width.integer), @intCast(height.integer));
        const value = protocol.object(alloc, .{
            .width = protocol.integer(width.integer),
            .height = protocol.integer(height.integer),
        }) catch return callback(ctx, .{ .err = "out_of_memory" });
        return callback(ctx, .{ .ok = value });
    }
    const timeout: u32 = if (params.object.get("timeout_ms")) |value| timeout: {
        if (value != .integer or value.integer < 1 or value.integer > 120000) return callback(ctx, .{ .err = "invalid_params: timeout_ms must be 1..120000" });
        break :timeout @intCast(value.integer);
    } else 30000;
    if (std.mem.eql(u8, method, "browser.navigate")) {
        const uri = stringParam(params, "uri") orelse return callback(ctx, .{ .err = "invalid_params: uri required" });
        if (!allowedUri(uri) or std.mem.indexOfScalar(u8, uri, 0) != null) return callback(ctx, .{ .err = "invalid_uri: only http, https and about:blank are allowed" });
        if (pane.navigation != null) return callback(ctx, .{ .err = "navigation_in_progress" });
        const current = zslice(webkit_web_view_get_uri(pane.view));
        const current_base = current[0 .. std.mem.indexOfScalar(u8, current, '#') orelse current.len];
        const same_document = if (std.mem.indexOfScalar(u8, uri, '#')) |fragment|
            webkit_web_view_is_loading(pane.view) == 0 and std.mem.eql(u8, current_base, uri[0..fragment])
        else
            false;
        if (same_document and std.mem.eql(u8, current, uri)) {
            const value = pane.status(alloc) catch return callback(ctx, .{ .err = "out_of_memory" });
            return callback(ctx, .{ .ok = value });
        }
        const uri_z = alloc.dupeZ(u8, uri) catch return callback(ctx, .{ .err = "out_of_memory" });
        // Stop an older UI/page-initiated load before installing the new waiter.
        webkit_web_view_stop_loading(pane.view);
        const op = Operation.new(pane, alloc, ctx, callback, .navigation, timeout) catch return callback(ctx, .{ .err = "out_of_memory" });
        op.same_document = same_document;
        op.destination = uri;
        pane.navigation = op;
        webkit_web_view_load_uri(pane.view, uri_z);
        return;
    }
    const back = std.mem.eql(u8, method, "browser.back");
    const forward = std.mem.eql(u8, method, "browser.forward");
    const reload = std.mem.eql(u8, method, "browser.reload");
    if (std.mem.eql(u8, method, "browser.stop")) {
        webkit_web_view_stop_loading(pane.view);
        const value = pane.status(alloc) catch return callback(ctx, .{ .err = "out_of_memory" });
        return callback(ctx, .{ .ok = value });
    }
    if (back or forward or reload) {
        if (pane.navigation != null) return callback(ctx, .{ .err = "navigation_in_progress" });
        if (back and webkit_web_view_can_go_back(pane.view) == 0)
            return callback(ctx, .{ .err = "no_back_history" });
        if (forward and webkit_web_view_can_go_forward(pane.view) == 0)
            return callback(ctx, .{ .err = "no_forward_history" });
        const op = Operation.new(pane, alloc, ctx, callback, .navigation, timeout) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        pane.navigation = op;
        if (back) webkit_web_view_go_back(pane.view) else if (forward)
            webkit_web_view_go_forward(pane.view)
        else
            webkit_web_view_reload(pane.view);
        return;
    }
    if (std.mem.eql(u8, method, "browser.screenshot")) {
        const path = stringParam(params, "path") orelse
            return callback(ctx, .{ .err = "invalid_params: path required" });
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null)
            return callback(ctx, .{ .err = "invalid_params: screenshot path must be absolute" });
        const path_z = alloc.dupeZ(u8, path) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        const op = Operation.new(pane, alloc, ctx, callback, .screenshot, timeout) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        op.destination = path_z;
        op.cancellable = g_cancellable_new();
        const region: c_int = if (params.object.get("full_page")) |value|
            if (value == .bool and value.bool) 1 else 0
        else
            0;
        webkit_web_view_get_snapshot(pane.view, region, 0, op.cancellable, screenshotReady, op);
        return;
    }
    if (std.mem.eql(u8, method, "browser.script")) {
        const source = stringParam(params, "script") orelse
            return callback(ctx, .{ .err = "invalid_params: script required" });
        const source_json = std.json.Stringify.valueAlloc(alloc, source, .{}) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        const body = std.fmt.allocPrint(alloc, "const value = await (0,eval)({s}); return JSON.stringify({{value: value === undefined ? null : value}});", .{source_json}) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        const op = Operation.new(pane, alloc, ctx, callback, .javascript, timeout) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        op.cancellable = g_cancellable_new();
        webkit_web_view_call_async_javascript_function(pane.view, body.ptr, @intCast(body.len), null, null, null, op.cancellable, javascriptReady, op);
        return;
    }
    if (std.mem.eql(u8, method, "browser.network")) {
        const mode = stringParam(params, "mode") orelse
            return callback(ctx, .{ .err = "invalid_params: mode required" });
        const offline = if (std.mem.eql(u8, mode, "offline"))
            true
        else if (std.mem.eql(u8, mode, "online"))
            false
        else
            return callback(ctx, .{ .err = "invalid_params: mode must be online or offline" });
        const body = std.fmt.allocPrint(alloc,
            \\const offline = {};
            \\const state = globalThis.__colmNetwork ??= {{
            \\  fetch: globalThis.fetch,
            \\  xhrOpen: XMLHttpRequest.prototype.open,
            \\  online: Object.getOwnPropertyDescriptor(Navigator.prototype, "onLine")
            \\}};
            \\if (offline) {{
            \\  globalThis.fetch = () => Promise.reject(new TypeError("Network is offline"));
            \\  XMLHttpRequest.prototype.open = function() {{ throw new DOMException("Network is offline", "NetworkError"); }};
            \\  Object.defineProperty(Navigator.prototype, "onLine", {{ configurable: true, get: () => false }});
            \\}} else {{
            \\  globalThis.fetch = state.fetch;
            \\  XMLHttpRequest.prototype.open = state.xhrOpen;
            \\  if (state.online) Object.defineProperty(Navigator.prototype, "onLine", state.online);
            \\}}
            \\dispatchEvent(new Event(offline ? "offline" : "online"));
            \\return JSON.stringify({{offline}});
        , .{offline}) catch return callback(ctx, .{ .err = "out_of_memory" });
        const op = Operation.new(pane, alloc, ctx, callback, .javascript, timeout) catch
            return callback(ctx, .{ .err = "out_of_memory" });
        op.cancellable = g_cancellable_new();
        webkit_web_view_call_async_javascript_function(pane.view, body.ptr, @intCast(body.len), null, null, null, op.cancellable, javascriptReady, op);
        return;
    }
    const snapshot = std.mem.eql(u8, method, "browser.snapshot");
    const click = std.mem.eql(u8, method, "browser.click");
    const fill = std.mem.eql(u8, method, "browser.fill");
    const get = std.mem.eql(u8, method, "browser.get");
    const find = std.mem.eql(u8, method, "browser.find");
    const wait = std.mem.eql(u8, method, "browser.wait");
    const select = std.mem.eql(u8, method, "browser.select");
    const press = std.mem.eql(u8, method, "browser.press");
    const upload = std.mem.eql(u8, method, "browser.upload");
    const frames = std.mem.eql(u8, method, "browser.frames");
    const style = std.mem.eql(u8, method, "browser.style");
    const annotate = std.mem.eql(u8, method, "browser.annotate");
    const clear_annotations = std.mem.eql(u8, method, "browser.annotations-clear");
    const state_export = std.mem.eql(u8, method, "browser.state-export");
    const state_import = std.mem.eql(u8, method, "browser.state-import");
    const evaluate = std.mem.eql(u8, method, "browser.evaluate");
    if (!snapshot and !click and !fill and !get and !find and !wait and !select and !press and !upload and !frames and !style and !annotate and !clear_annotations and !state_export and !state_import and !evaluate)
        return callback(ctx, .{ .err = "unknown_method" });
    if (webkit_web_view_is_loading(pane.view) != 0) return callback(ctx, .{ .err = "page_loading" });
    if (params.object.get("generation")) |generation| {
        if (generation != .integer or generation.integer < 0 or generation.integer != pane.generation) return callback(ctx, .{ .err = "stale_generation" });
    } else if (click or fill or get or select or press or upload or annotate or state_import) return callback(ctx, .{ .err = "invalid_params: generation required" });
    if (upload) {
        const path = stringParam(params, "path") orelse
            return callback(ctx, .{ .err = "invalid_params: path required" });
        pane.stageUpload(path) catch |err| return callback(ctx, .{ .err = switch (err) {
            error.InvalidPath => "invalid_path",
            error.PaneClosed => "pane_closed",
            error.UploadInProgress => "upload_in_progress",
            else => "out_of_memory",
        } });
    }
    const script = makeScript(pane, alloc, params, method) catch |err| {
        if (upload) pane.clearUpload();
        return callback(ctx, .{ .err = switch (err) {
            error.MissingRef => "invalid_params: ref required",
            error.MissingValue => "invalid_params: value required",
            error.MissingScript => "invalid_params: script required",
            error.MissingQuery => "invalid_params: query required",
            error.MissingKey => "invalid_params: key required",
            error.MissingState => "invalid_params: state required",
            error.MissingCss => "invalid_params: css required",
            error.MissingText => "invalid_params: text required",
            else => "out_of_memory",
        } });
    };
    const op = Operation.new(pane, alloc, ctx, callback, if (upload) .upload else .javascript, timeout) catch {
        if (upload) pane.clearUpload();
        return callback(ctx, .{ .err = "out_of_memory" });
    };
    op.cancellable = g_cancellable_new();
    webkit_web_view_call_async_javascript_function(pane.view, script.ptr, @intCast(script.len), null, world, null, op.cancellable, javascriptReady, op);
}

fn makeScript(pane: *Pane, alloc: Allocator, params: Value, method: []const u8) ![]const u8 {
    if (std.mem.eql(u8, method, "browser.snapshot"))
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.snapshot({d}));", .{ automation, pane.generation });
    if (std.mem.eql(u8, method, "browser.frames"))
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.frames());", .{automation});
    if (std.mem.eql(u8, method, "browser.style")) {
        const css = stringParam(params, "css") orelse return error.MissingCss;
        const css_json = try std.json.Stringify.valueAlloc(alloc, css, .{});
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.style({s}));", .{ automation, css_json });
    }
    if (std.mem.eql(u8, method, "browser.annotate")) {
        const ref = stringParam(params, "ref") orelse return error.MissingRef;
        const text = stringParam(params, "text") orelse return error.MissingText;
        const ref_json = try std.json.Stringify.valueAlloc(alloc, ref, .{});
        const text_json = try std.json.Stringify.valueAlloc(alloc, text, .{});
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.annotate({d},{s},{s}));", .{ automation, pane.generation, ref_json, text_json });
    }
    if (std.mem.eql(u8, method, "browser.annotations-clear"))
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.clearAnnotations());", .{automation});
    if (std.mem.eql(u8, method, "browser.state-export"))
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.stateExport());", .{automation});
    if (std.mem.eql(u8, method, "browser.state-import")) {
        const state = stringParam(params, "state") orelse return error.MissingState;
        const state_json = try std.json.Stringify.valueAlloc(alloc, state, .{});
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.stateImport(JSON.parse({s})));", .{ automation, state_json });
    }
    if (std.mem.eql(u8, method, "browser.find") or std.mem.eql(u8, method, "browser.wait")) {
        const query = stringParam(params, "query") orelse return error.MissingQuery;
        const query_json = try std.json.Stringify.valueAlloc(alloc, query, .{});
        if (std.mem.eql(u8, method, "browser.wait")) {
            const timeout = if (params.object.get("timeout_ms")) |value| @max(@as(i64, 1), value.integer - 100) else 29900;
            return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(await globalThis.__colmApi.wait({s},{d}));", .{ automation, query_json, timeout });
        }
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.find({s}));", .{ automation, query_json });
    }
    if (std.mem.eql(u8, method, "browser.upload")) {
        const ref = stringParam(params, "ref") orelse return error.MissingRef;
        const ref_json = try std.json.Stringify.valueAlloc(alloc, ref, .{});
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.upload({d},{s}));", .{ automation, pane.generation, ref_json });
    }
    if (std.mem.eql(u8, method, "browser.click") or std.mem.eql(u8, method, "browser.fill") or
        std.mem.eql(u8, method, "browser.get") or std.mem.eql(u8, method, "browser.select") or
        std.mem.eql(u8, method, "browser.press"))
    {
        const ref = stringParam(params, "ref") orelse return error.MissingRef;
        const ref_json = try std.json.Stringify.valueAlloc(alloc, ref, .{});
        if (std.mem.eql(u8, method, "browser.click"))
            return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.click({d},{s}));", .{ automation, pane.generation, ref_json });
        if (std.mem.eql(u8, method, "browser.get"))
            return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.get({d},{s}));", .{ automation, pane.generation, ref_json });
        const field = if (std.mem.eql(u8, method, "browser.press")) "key" else "value";
        const argument = stringParam(params, field) orelse if (std.mem.eql(u8, method, "browser.press")) return error.MissingKey else return error.MissingValue;
        const argument_json = try std.json.Stringify.valueAlloc(alloc, argument, .{});
        const action = if (std.mem.eql(u8, method, "browser.fill")) "fill" else if (std.mem.eql(u8, method, "browser.select")) "select" else "press";
        return std.fmt.allocPrint(alloc, "{s}\nreturn JSON.stringify(globalThis.__colmApi.{s}({d},{s},{s}));", .{ automation, action, pane.generation, ref_json, argument_json });
    }
    const script = stringParam(params, "script") orelse return error.MissingScript;
    const script_json = try std.json.Stringify.valueAlloc(alloc, script, .{});
    return std.fmt.allocPrint(alloc, "return (async () => {{ const value = await (0,eval)({s}); return JSON.stringify({{value: value === undefined ? null : value}}); }})();", .{script_json});
}
fn screenshotReady(source: ?*anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const op: *Operation = @ptrCast(@alignCast(data.?));
    defer op.release();
    var err: ?*Error = null;
    const texture = webkit_web_view_get_snapshot_finish(source.?, result, &err);
    defer if (texture) |value| g_object_unref(value);
    defer if (err) |value| g_error_free(value);
    if (op.done) return;
    if (op.pane.disposed) return op.complete(.{ .err = "pane_closed" });
    if (err) |value| return op.complete(.{ .err = std.mem.span(value.message) });
    const native = texture orelse return op.complete(.{ .err = "screenshot_failed" });
    const path = op.destination orelse return op.complete(.{ .err = "screenshot_path_missing" });
    const path_z = op.alloc.dupeZ(u8, path) catch return op.complete(.{ .err = "out_of_memory" });
    if (gdk_texture_save_to_png(native, path_z) == 0)
        return op.complete(.{ .err = "screenshot_write_failed" });
    const value = protocol.object(op.alloc, .{
        .path = protocol.str(path),
        .generation = protocol.integer(op.generation),
    }) catch return op.complete(.{ .err = "out_of_memory" });
    op.complete(.{ .ok = value });
}

fn javascriptReady(source: ?*anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const op: *Operation = @ptrCast(@alignCast(data.?));
    defer op.release();
    var err: ?*Error = null;
    const value = webkit_web_view_call_async_javascript_function_finish(source.?, result, &err);
    defer if (value) |v| g_object_unref(v);
    defer if (err) |e| g_error_free(e);
    if (op.done) return;
    if (op.pane.disposed) return op.complete(.{ .err = "pane_closed" });
    if (op.generation != op.pane.generation) return op.complete(.{ .err = "stale_generation: document changed during operation" });
    if (err) |e| return op.complete(.{ .err = std.mem.span(e.message) });
    const native_value = value orelse return op.complete(.{ .err = "javascript_error: missing result" });
    const json = jsc_value_to_string(native_value) orelse return op.complete(.{ .err = "javascript_error: result is not serializable" });
    defer g_free(json);
    var parsed = std.json.parseFromSliceLeaky(Value, op.alloc, std.mem.span(json), .{ .allocate = .alloc_always }) catch return op.complete(.{ .err = "javascript_error: result is not JSON serializable" });
    if (parsed == .object) {
        const id = op.alloc.dupe(u8, op.pane.id) catch return op.complete(.{ .err = "out_of_memory" });
        parsed.object.put("id", .{ .string = id }) catch return op.complete(.{ .err = "out_of_memory" });
        parsed.object.put("generation", .{ .integer = @intCast(op.generation) }) catch return op.complete(.{ .err = "out_of_memory" });
    }
    op.complete(.{ .ok = parsed });
}



fn loadChanged(_: *anyopaque, event: c_int, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (pane.disposed) return;
    if (event == 0) {
        pane.generation += 1;
        if (pane.last_error) |message| pane.alloc.free(message);
        pane.last_error = null;
        pane.message.setText("Loading…");
        pane.message.as(gtk.Widget).setVisible(1);

        if (pane.navigation) |op| {
            if (op.started) {
                op.complete(.{ .err = "navigation_interrupted" });
                op.release();
            } else {
                op.started = true;
                op.generation = pane.generation;
            }
        }
    } else if (event == 3) {
        webkit_web_view_evaluate_javascript(pane.view, console_bridge.ptr, @intCast(console_bridge.len), null, null, null, null, null);
        if (pane.last_error == null) {
            pane.message.setText("");
            pane.message.as(gtk.Widget).setVisible(0);
        }

        if (pane.navigation) |op| {
            const value = pane.status(op.alloc) catch {
                op.complete(.{ .err = "out_of_memory" });
                op.release();
                return;
            };
            op.complete(.{ .ok = value });
            op.release();
        }
    }
}

fn downloadFinished(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const job: *DownloadJob = @ptrCast(@alignCast(data.?));
    job.finish();
}

fn downloadFailed(_: *anyopaque, _: *Error, data: ?*anyopaque) callconv(.c) void {
    // WebKit emits `failed` then `finished` for errored downloads.
    // Only `finished` destroys the job so the second callback is not UAF.
    _ = data;
}

fn loadFailed(_: *anyopaque, _: c_int, _: [*:0]const u8, err: *Error, data: ?*anyopaque) callconv(.c) c_int {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (pane.disposed) return 1;
    const message = std.mem.span(err.message);
    pane.fail(message);
    if (pane.navigation) |op| {
        op.complete(.{ .err = message });
        op.release();
    }
    // The native toolbar and automation expose the error; avoid WebKit's
    // alternate error-page load, which would invalidate refs a second time.
    return 1;
}

fn uriChanged(_: *anyopaque, _: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (pane.disposed) return;
    const uri = webkit_web_view_get_uri(pane.view) orelse return;
    const text = std.mem.span(uri);
    const changed = if (pane.last_uri) |old| !std.mem.eql(u8, old, text) else true;
    if (changed) pane.generation += 1;
    if (pane.last_uri) |old| pane.alloc.free(old);
    pane.last_uri = pane.alloc.dupe(u8, text) catch null;
    pane.entry.getBuffer().setText(uri, -1);
    // Fragment/history navigations do not necessarily emit load-changed.
    if (changed and webkit_web_view_is_loading(pane.view) == 0) {
        if (pane.navigation) |op| {
            if (!op.same_document) return;
            const value = pane.status(op.alloc) catch {
                op.complete(.{ .err = "out_of_memory" });

                op.release();
                return;
            };
            op.complete(.{ .ok = value });
            op.release();
        }
    }
}
fn runFileChooser(_: *anyopaque, request: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    const path = pane.pending_upload orelse {
        webkit_file_chooser_request_cancel(request);
        return 1;
    };
    const files = [_:null]?[*:0]const u8{path.ptr};
    webkit_file_chooser_request_select_files(request, &files);
    return 1;
}

fn consoleMessage(_: *anyopaque, message: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (pane.disposed) return;
    const raw = jsc_value_to_string(message) orelse return;
    defer g_free(raw);
    const text = std.mem.span(raw);
    const separator = std.mem.indexOfScalar(u8, text, '\n') orelse return;
    const level: c_int = if (std.mem.eql(u8, text[0..separator], "error"))
        3
    else if (std.mem.eql(u8, text[0..separator], "warn"))
        2
    else if (std.mem.eql(u8, text[0..separator], "debug"))
        4
    else if (std.mem.eql(u8, text[0..separator], "info"))
        0
    else
        1;
    pane.appendLog(text[separator + 1 ..], "console", level, 0);
}

fn scriptDialog(_: *anyopaque, dialog: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (pane.disposed) return 0;
    pane.appendLog(std.mem.span(webkit_script_dialog_get_message(dialog)), "dialog", 2, 0);
    const kind = webkit_script_dialog_get_dialog_type(dialog);
    if (kind == 1 or kind == 3)
        webkit_script_dialog_confirm_set_confirmed(dialog, @intFromBool(pane.dialog_accept))
    else if (kind == 2 and pane.dialog_accept)
        webkit_script_dialog_prompt_set_text(dialog, if (pane.dialog_prompt) |text| text.ptr else "");
    return 1;
}

fn loadingChanged(_: *anyopaque, _: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (pane.disposed or webkit_web_view_is_loading(pane.view) != 0) return;
    const op = pane.navigation orelse return;
    if (!op.same_document) return;
    const destination = op.destination orelse return;
    if (!std.mem.eql(u8, destination, zslice(webkit_web_view_get_uri(pane.view)))) return;
    const value = pane.status(op.alloc) catch {
        op.complete(.{ .err = "out_of_memory" });
        op.release();
        return;
    };
    op.complete(.{ .ok = value });
    op.release();
}

fn processTerminated(_: *anyopaque, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (pane.disposed) return;
    pane.refs += 1;
    defer pane.release();
    pane.generation += 1;
    pane.fail("web_process_terminated");
    while (pane.pending) |op| {
        op.complete(.{ .err = "web_process_terminated" });
        if (op.kind != .navigation) g_cancellable_cancel(op.cancellable.?) else op.release();
    }
}

fn decidePolicy(_: *anyopaque, decision: *anyopaque, kind: c_int, data: ?*anyopaque) callconv(.c) c_int {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (pane.disposed) {
        webkit_policy_decision_ignore(decision);
        return 1;
    }
    // 0 = navigation, 1 = new-window (target=_blank, window.open).
    if (kind == 0 or kind == 1) {
        const action = webkit_navigation_policy_decision_get_navigation_action(decision);
        const request = webkit_navigation_action_get_request(action);
        const uri = std.mem.span(webkit_uri_request_get_uri(request));
        if (!allowedUri(uri)) {
            webkit_policy_decision_ignore(decision);
            pane.fail("Navigation blocked: only HTTP and HTTPS pages are allowed.");
            if (pane.navigation) |op| {
                op.complete(.{ .err = "navigation_blocked" });
                op.release();
            }
            return 1;
        }
        const button = webkit_navigation_action_get_mouse_button(action);
        const mods = webkit_navigation_action_get_modifiers(action);
        const new_column = button == 2 or mods & 4 != 0;
        if (new_column) {
            var copy: [2048]u8 = undefined;
            if (uri.len >= copy.len) {
                webkit_policy_decision_ignore(decision);
                return 1;
            }
            @memcpy(copy[0..uri.len], uri);
            webkit_policy_decision_ignore(decision);
            if (spawnColumn) |f| f(pane, copy[0..uri.len]);
            return 1;
        }
        if (kind == 1) {
            var copy: [2048]u8 = undefined;
            if (uri.len >= copy.len) {
                webkit_policy_decision_ignore(decision);
                return 1;
            }
            @memcpy(copy[0..uri.len], uri);
            webkit_policy_decision_ignore(decision);
            pane.loadUri(copy[0..uri.len]);
            return 1;
        }
    }
    return 0;
}



fn permissionRequested(_: *anyopaque, request: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    var allowed = false;
    if (!pane.disposed and permissionOriginMatches(pane)) {
        if (g_type_check_instance_is_a(request, webkit_user_media_permission_request_get_type()) != 0) {
            const audio = webkit_user_media_permission_is_for_audio_device(request) != 0;
            const video = webkit_user_media_permission_is_for_video_device(request) != 0;
            const display = webkit_user_media_permission_is_for_display_device(request) != 0;
            allowed = !display and
                (!audio or pane.permissions & permission_microphone != 0) and
                (!video or pane.permissions & permission_camera != 0);
        } else if (g_type_check_instance_is_a(request, webkit_geolocation_permission_request_get_type()) != 0) {
            allowed = pane.permissions & permission_geolocation != 0;
        } else if (g_type_check_instance_is_a(request, webkit_notification_permission_request_get_type()) != 0) {
            allowed = pane.permissions & permission_notifications != 0;
        } else if (g_type_check_instance_is_a(request, webkit_clipboard_permission_request_get_type()) != 0) {
            allowed = pane.permissions & permission_clipboard != 0;
        }
    }
    if (allowed) webkit_permission_request_allow(request) else webkit_permission_request_deny(request);
    return 1;
}

fn entryActivated(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (pane.disposed) return;
    const text = std.mem.span(pane.entry.as(gtk.Editable).getText());
    if (text.len == 0) return;
    pane.loadUri(text);
}
fn closeClicked(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    pane.close();
}

fn columnKey(
    controller: *gtk.EventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    mods: gdk.ModifierType,
    pane: *Pane,
) callconv(.c) c_int {
    if ((keyval == gdk.KEY_w or keyval == gdk.KEY_W) and mods.control_mask and mods.shift_mask) {
        pane.close();
        return 1;
    }
    return devtoolsKey(controller, keyval, keycode, mods, pane);
}

fn showColumnMenu(gesture: *gtk.GestureClick, _: c_int, x: f64, y: f64, pane: *Pane) callconv(.c) void {
    if (pane.disposed) return;
    _ = gesture.as(gtk.Gesture).setState(.claimed);
    const popover = gtk.Popover.new();
    popover.as(gtk.Widget).setParent(pane.widget.as(gtk.Widget));
    popover.setHasArrow(0);
    const rect: gdk.Rectangle = .{
        .f_x = @intFromFloat(x),
        .f_y = @intFromFloat(y),
        .f_width = 1,
        .f_height = 1,
    };
    popover.setPointingTo(&rect);
    const box = gtk.Box.new(.vertical, 0);
    const newer = gtk.Button.newWithLabel("New Column");
    const closer = gtk.Button.newWithLabel("Close");
    newer.as(gtk.Widget).addCssClass("flat");
    closer.as(gtk.Widget).addCssClass("flat");
    _ = gtk.Button.signals.clicked.connect(newer, *Pane, menuNewColumn, pane, .{});
    _ = gtk.Button.signals.clicked.connect(closer, *Pane, menuClose, pane, .{});
    box.append(newer.as(gtk.Widget));
    box.append(closer.as(gtk.Widget));
    popover.setChild(box.as(gtk.Widget));
    _ = gtk.Popover.signals.closed.connect(popover, *gtk.Popover, menuClosed, popover, .{});
    popover.popup();
}

fn menuClosed(popover: *gtk.Popover, _: *gtk.Popover) callconv(.c) void {
    popover.as(gtk.Widget).unparent();
}

fn menuPopover(button: *gtk.Button) ?*gtk.Popover {
    var widget: ?*gtk.Widget = button.as(gtk.Widget);
    while (widget) |w| {
        if (gobject.ext.cast(gtk.Popover, w)) |popover| return popover;
        widget = w.getParent();
    }
    return null;
}

fn menuNewColumn(button: *gtk.Button, pane: *Pane) callconv(.c) void {
    if (menuPopover(button)) |popover| popover.popdown();
    if (pane.disposed) return;
    if (spawnColumn) |f| f(pane, "about:blank");
}

fn menuClose(button: *gtk.Button, pane: *Pane) callconv(.c) void {
    if (menuPopover(button)) |popover| popover.popdown();
    pane.close();
}

fn devtoolsClicked(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    _ = pane.showDevtools();
}
fn devtoolsKey(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint,
    mods: gdk.ModifierType,
    pane: *Pane,
) callconv(.c) c_int {
    const f12 = keyval == gdk.KEY_F12;
    const ctrl_shift_i = (keyval == gdk.KEY_i or keyval == gdk.KEY_I) and
        mods.control_mask and mods.shift_mask;
    if (!f12 and !ctrl_shift_i) return 0;
    _ = pane.showDevtools();
    return 1;
}


fn backClicked(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (!pane.disposed) webkit_web_view_go_back(pane.view);
}
fn forwardClicked(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (!pane.disposed) webkit_web_view_go_forward(pane.view);
}
fn reloadClicked(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const pane: *Pane = @ptrCast(@alignCast(data.?));
    if (!pane.disposed) webkit_web_view_reload(pane.view);
}
fn connect(instance: anytype, signal: [*:0]const u8, handler: anytype, pane: *Pane) c_ulong {
    return g_signal_connect_data(@ptrCast(instance), signal, @ptrCast(handler), pane, null, 0);
}
fn consoleSource(source: c_int) []const u8 {
    return switch (source) {
        0 => "javascript",
        1 => "network",
        2 => "console",
        3 => "security",
        else => "other",
    };
}
fn consoleLevel(level: c_int) []const u8 {
    return switch (level) {
        0 => "info",
        1 => "log",
        2 => "warning",
        3 => "error",
        else => "debug",
    };
}
fn allowedUri(uri: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(uri, "http://") or
        std.ascii.startsWithIgnoreCase(uri, "https://") or
        std.mem.eql(u8, uri, "about:blank") or
        std.mem.eql(u8, uri, "about:srcdoc");
}
fn permissionBit(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "camera")) return permission_camera;
    if (std.mem.eql(u8, name, "microphone")) return permission_microphone;
    if (std.mem.eql(u8, name, "geolocation")) return permission_geolocation;
    if (std.mem.eql(u8, name, "notifications")) return permission_notifications;
    if (std.mem.eql(u8, name, "clipboard")) return permission_clipboard;
    return null;
}
fn uriOrigin(uri: []const u8) ?[]const u8 {
    const scheme = std.mem.indexOf(u8, uri, "://") orelse return null;
    if (scheme == 0) return null;
    const authority = scheme + 3;
    if (authority >= uri.len) return null;
    const end = std.mem.indexOfAnyPos(u8, uri, authority, "/?#") orelse uri.len;
    if (end == authority) return null;
    return uri[0..end];
}
fn permissionOriginMatches(pane: *Pane) bool {
    const expected = pane.permission_origin orelse return false;
    const current = uriOrigin(zslice(webkit_web_view_get_uri(pane.view))) orelse return false;
    return std.mem.eql(u8, expected, current);
}
fn validProfile(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or std.mem.eql(u8, name, "ephemeral")) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    return true;
}

fn zslice(value: ?[*:0]const u8) []const u8 {
    return if (value) |text| std.mem.span(text) else "";
}
fn stringParam(params: Value, name: []const u8) ?[]const u8 {
    if (params != .object) return null;
    const value = params.object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}
