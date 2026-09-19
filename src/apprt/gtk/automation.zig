const std = @import("std");
const gtk = @import("gtk");
const gdk = @import("gdk");
const glib = @import("glib");
const gio = @import("gio");
const gobject = @import("gobject");
const p = @import("../../control/protocol.zig");
const Application = @import("class/application.zig").Application;
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;
const ext = @import("ext.zig");
const input = @import("../../input.zig");
const Config = @import("../../config.zig");
const browser = @import("browser.zig");
const session_state = @import("session_state.zig");
const agent_store = @import("agent_store.zig");
const deep_link = @import("deep_link.zig");
const appearance = @import("../../config/appearance.zig");
const platform = @import("platform.zig");
const feature_store = @import("feature_store.zig");
const notify_policy = @import("notify_policy.zig");
const viewer = @import("viewer.zig");
const task_manager = @import("task_manager.zig");

const build_config = @import("../../build_config.zig");
const a = std.heap.c_allocator;
const eq = std.mem.eql;
const StatusEntry = struct {
    key: []const u8,
    text: []const u8,
    icon: ?[]const u8,
    color: ?[]const u8,
    updated_at: i64,

    fn deinit(self: StatusEntry) void {
        a.free(self.key);
        a.free(self.text);
        if (self.icon) |value| a.free(value);
        if (self.color) |value| a.free(value);
    }
};

const LogEntry = struct {
    id: [32]u8,
    text: []const u8,
    level: []const u8,
    created_at: i64,

    fn deinit(self: LogEntry) void {
        a.free(self.text);
        a.free(self.level);
    }
};

const PullRequestEntry = struct {
    number: i64,
    label: []const u8,
    url: []const u8,
    status: []const u8,
    branch: ?[]const u8,

    fn deinit(self: PullRequestEntry) void {
        a.free(self.label);
        a.free(self.url);
        a.free(self.status);
        if (self.branch) |value| a.free(value);
    }
};

const NotificationRecord = struct {
    id: [32]u8,
    window_id: [32]u8,
    workspace_id: [32]u8,
    surface_id: ?[32]u8,
    title: []const u8,
    body: []const u8,
    subtitle: []const u8,
    level: []const u8,
    tab_title: []const u8,
    category: []const u8,
    created_at: i64,
    read: bool = false,

    fn deinit(self: NotificationRecord) void {
        a.free(self.title);
        a.free(self.body);
        a.free(self.tab_title);
        a.free(self.subtitle);
        a.free(self.level);
        a.free(self.category);
    }
};

var notifications: std.ArrayList(NotificationRecord) = .empty;
/// Latest unread id marked as the jump-next cursor (cmux oldest-unread).
var oldest_unread_id: ?[32]u8 = null;

pub const FeedRecord = struct {
    id: [32]u8,
    kind: []const u8,
    workspace_id: [32]u8,
    surface_id: ?[32]u8,
    request_id: []const u8,
    title: []const u8,
    body: []const u8,
    tool: []const u8,
    status: []const u8,
    created_at: i64,
    parked_until: i64,

    fn deinit(self: FeedRecord) void {
        a.free(self.kind);
        a.free(self.request_id);
        a.free(self.title);
        a.free(self.body);
        a.free(self.tool);
        a.free(self.status);
    }
};

var feed_items: std.ArrayList(FeedRecord) = .empty;

const Metadata = struct {
    /// Lifetime-stable ordinal backing "kind:N" handles. Assigned once at
    /// metadata creation per kind; never derived from list position.
    ordinal: usize = 0,
    id: [32:0]u8,
    statuses: std.ArrayList(StatusEntry) = .empty,
    progress: ?i64 = null,
    progress_label: ?[]const u8 = null,
    logs: std.ArrayList(LogEntry) = .empty,
    git_branch: ?[]const u8 = null,
    git_dirty: bool = false,
    pull_request: ?PullRequestEntry = null,
    listening_ports: std.ArrayList(u16) = .empty,
    browsers: std.ArrayList(*browser.Pane) = .empty,
    remote: ?Remote = null,
    remote_closed: bool = false,
    local_directory: ?[:0]const u8 = null,
    remote_directory: ?[:0]const u8 = null,
    /// Last stable OSC/process title after spinner-frame filtering.
    process_title: ?[]const u8 = null,
    /// True while the process title looks like an agent is working.
    prompt_turn_busy: bool = false,
    prompt_turn_at: i64 = 0,

    pinned: bool = false,
    muted: bool = false,
    task_status: ?[]const u8 = null,
    dock: bool = false,
    group_key: ?[]const u8 = null,
    group_name: ?[]const u8 = null,
    resume_command: ?[]const u8 = null,
    tmux_session: ?[]const u8 = null,
    agent_scan_at: i64 = 0,

    fn destroy(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Metadata = @ptrCast(@alignCast(ptr.?));
        for (self.statuses.items) |entry| entry.deinit();
        self.statuses.deinit(a);
        if (self.progress_label) |value| a.free(value);
        for (self.logs.items) |entry| entry.deinit();
        self.logs.deinit(a);
        if (self.git_branch) |value| a.free(value);
        if (self.pull_request) |entry| entry.deinit();
        self.listening_ports.deinit(a);
        if (self.local_directory) |v| a.free(v);
        if (self.remote_directory) |v| a.free(v);
        if (self.process_title) |v| a.free(v);
        if (self.task_status) |v| a.free(v);
        if (self.group_key) |v| a.free(v);
        if (self.group_name) |v| a.free(v);
        if (self.resume_command) |v| a.free(v);
        if (self.tmux_session) |v| a.free(v);

        for (self.browsers.items) |pane| pane.destroy();
        self.browsers.deinit(a);
        if (self.remote) |remote| {
            a.free(remote.host);
            a.free(remote.cwd);
            a.free(remote.proxy);
            a.free(remote.terminal_transport);
            a.free(remote.terminal_profile);
            if (remote.tmux_session) |value| a.free(value);
        }
        a.destroy(self);
    }
};
fn existingMetadata(object: *gobject.Object) ?*Metadata {
    const ptr = object.getData("colm-automation") orelse return null;
    return @ptrCast(@alignCast(ptr));
}

var next_ordinal = std.enums.EnumArray(HandleKind, usize).initFill(1);
const HandleKind = enum { window, workspace, surface, pane };

fn handleKind(object: *gobject.Object) HandleKind {
    if (gobject.ext.cast(Window, object) != null) return .window;
    if (gobject.ext.cast(Tab, object) != null) return .workspace;
    if (gobject.ext.cast(Surface, object) != null) return .surface;
    return .pane;
}

fn metadata(object: *gobject.Object) *Metadata {
    if (existingMetadata(object)) |value| return value;
    const value = a.create(Metadata) catch @panic("out of memory");
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    value.* = .{ .id = undefined, .ordinal = ordinal: {
        const kind = handleKind(object);
        const ordinal = next_ordinal.get(kind);
        next_ordinal.set(kind, ordinal + 1);
        break :ordinal ordinal;
    } };
    @memcpy(value.id[0..32], &std.fmt.bytesToHex(random, .lower));
    value.id[32] = 0;
    if (gobject.ext.cast(Window, object) != null) {
        if (creating_window) |value_id| @memcpy(value.id[0..32], value_id);
    }
    if (gobject.ext.cast(Tab, object) != null) {
        if (creating_workspace) |value_id| @memcpy(value.id[0..32], value_id);
    }
    if (gobject.ext.cast(Surface, object) != null) {
        if (creating_terminal) |value_id| @memcpy(value.id[0..32], value_id);
    }
    object.setDataFull("colm-automation", value, Metadata.destroy);
    return value;
}
pub fn id(object: anytype) [:0]const u8 {
    return &metadata(object.as(gobject.Object)).id;
}

pub fn workspacePinned(tab: *Tab) bool {
    return metadata(tab.as(gobject.Object)).pinned;
}

pub fn workspaceMuted(tab: *Tab) bool {
    return metadata(tab.as(gobject.Object)).muted;
}

pub fn setWorkspacePinned(tab: *Tab, pinned: bool) void {
    const data = metadata(tab.as(gobject.Object));
    data.pinned = pinned;
    if (data.group_key) |key| {
        if (ext.getAncestor(Window, tab.as(gtk.Widget))) |win| {
            const view = win.getTabView();
            var i: c_int = 0;
            while (i < view.getNPages()) : (i += 1) {
                const other = gobject.ext.cast(Tab, view.getNthPage(i).getChild()) orelse continue;
                const meta = metadata(other.as(gobject.Object));
                if (meta.group_key) |other_key| {
                    if (std.mem.eql(u8, other_key, key)) meta.pinned = pinned;
                }
            }
        }
    }
    if (pinned) {
        const win = ext.getAncestor(Window, tab.as(gtk.Widget)) orelse {
            refreshActivities();
            return;
        };
        const view = win.getTabView();
        _ = view.reorderPage(view.getPage(tab.as(gtk.Widget)), 0);
    }
    refreshActivities();
}

pub fn setWorkspaceMuted(tab: *Tab, muted: bool) void {
    metadata(tab.as(gobject.Object)).muted = muted;
    refreshActivities();
}

pub fn workspaceTaskStatus(tab: *Tab) ?[]const u8 {
    return metadata(tab.as(gobject.Object)).task_status;
}

pub fn setWorkspaceTaskStatus(tab: *Tab, status: ?[]const u8) void {
    const data = metadata(tab.as(gobject.Object));
    const normalized: ?[]const u8 = blk: {
        const value = status orelse break :blk null;
        if (value.len == 0 or std.mem.eql(u8, value, "clear")) break :blk null;
        break :blk value;
    };
    if (data.task_status) |value| a.free(value);
    data.task_status = if (normalized) |value| a.dupe(u8, value) catch null else null;
    refreshActivities();
}

pub fn markDock(surface: *Surface) void {
    metadata(surface.as(gobject.Object)).dock = true;
}

pub fn createDockBrowser(tab: *Tab) void {
    const data = metadata(tab.as(gobject.Object));
    const pane_id = randomId();
    const pane = browser.create(
        a,
        tab.as(gtk.Box),
        tab.getSplitTree(),
        &pane_id,
        if (data.remote) |r| r.proxy else null,
        null,
        if (data.remote) |r| r.host else "local",
    ) catch return;
    data.browsers.append(a, pane) catch pane.destroy();
}

pub fn openBrowserColumn(tab: *Tab, uri: []const u8) void {
    browser.spawnColumn = spawnColumnFromPane;
    const data = metadata(tab.as(gobject.Object));
    const pane_id = randomId();
    const pane = browser.create(
        a,
        tab.as(gtk.Box),
        tab.getSplitTree(),
        &pane_id,
        if (data.remote) |r| r.proxy else null,
        null,
        if (data.remote) |r| r.host else "local",
    ) catch return;
    data.browsers.append(a, pane) catch {
        pane.destroy();
        return;
    };
    pane.loadUri(uri);
}

fn spawnColumnFromPane(pane: *browser.Pane, uri: []const u8) void {
    const tab = ext.getAncestor(Tab, pane.widget.as(gtk.Widget)) orelse return;
    openBrowserColumn(tab, uri);
}

fn openDeviceColumn(
    tab: *Tab,
    profile: []const u8,
    uri: []const u8,
    width: c_int,
    height: c_int,
    user_agent: ?[]const u8,
) !*browser.Pane {
    const data = metadata(tab.as(gobject.Object));
    const pane_id = randomId();
    const pane = try browser.create(
        a,
        tab.as(gtk.Box),
        tab.getSplitTree(),
        &pane_id,
        if (data.remote) |r| r.proxy else null,
        profile,
        if (data.remote) |r| r.host else "local",
    );
    errdefer pane.destroy();
    try data.browsers.append(a, pane);
    pane.setDevice(width, height, user_agent);
    pane.loadUri(uri);
    return pane;
}

fn currentTab(alloc: std.mem.Allocator, params: p.Value) !*Tab {
    const t = resolvedMetadataTarget(alloc, params) catch Target{
        .window = try currentWindow(alloc),
        .tab = null,
        .surface = null,
    };
    if (t.tab) |tab| return tab;
    const page = t.window.getTabView().getSelectedPage() orelse return error.TargetNotFound;
    return gobject.ext.cast(Tab, page.getChild()) orelse error.TargetNotFound;
}

pub const WorkspaceGroup = struct {
    key: []const u8,
    name: []const u8,
};

pub fn workspaceGroup(tab: *Tab) ?WorkspaceGroup {
    const data = existingMetadata(tab.as(gobject.Object)) orelse return null;
    const key = data.group_key orelse return null;
    const name = data.group_name orelse key;
    if (key.len == 0) return null;
    return .{ .key = key, .name = name };
}

pub fn assignWorkspaceGroup(tab: *Tab, key: []const u8, name: []const u8) void {
    const data = metadata(tab.as(gobject.Object));
    if (data.group_key) |value| a.free(value);
    if (data.group_name) |value| a.free(value);
    data.group_key = a.dupe(u8, key) catch null;
    data.group_name = a.dupe(u8, name) catch null;
    refreshActivities();
}

const Remote = struct {
    host: []const u8,
    cwd: []const u8,
    proxy: []const u8,
    capability: [64]u8,
    terminal_transport: []const u8,
    terminal_profile: []const u8,
    tmux_session: ?[]const u8,
};
var creating_window: ?[]const u8 = null;
var creating_workspace: ?[]const u8 = null;
var creating_terminal: ?[]const u8 = null;
var restore_attempted = false;
var restoring = false;
var session_save_source: ?c_uint = null;
pub var closing_remote: bool = false;
pub var detaching: bool = false;

/// Native controls use the same request dispatcher as the CLI.
const UiRequest = struct {
    arena: std.heap.ArenaAllocator,
    window: ?*Window = null,
    fn complete(ptr: *anyopaque, result: p.Result) void {
        const self: *UiRequest = @ptrCast(@alignCast(ptr));
        defer {
            self.arena.deinit();
            a.destroy(self);
        }
        defer if (self.window) |win| win.unref();
        if (result == .err) if (self.window) |win| {
            if (win.as(gtk.Widget).getVisible() != 0) win.addToast(self.arena.allocator().dupeZ(u8, result.err) catch "Remote operation failed");
        };
        if (result == .err) std.log.err("Colm operation failed: {s}", .{result.err});
    }
};
pub fn uploadDroppedFile(surface: *Surface, source: []const u8) bool {
    const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return false;
    if (metadata(tab.as(gobject.Object)).remote == null) return false;
    const win = ext.getAncestor(Window, surface.as(gtk.Widget)) orelse return true;
    const remote_dir = metadata(surface.as(gobject.Object)).remote_directory orelse {
        win.addToast("Remote directory is not available yet.");
        return true;
    };
    const owner = a.create(UiRequest) catch {
        win.addToast("Unable to start remote upload.");
        return true;
    };
    owner.* = .{ .arena = .init(a), .window = win.ref() };
    const alloc = owner.arena.allocator();
    const destination = std.fs.path.join(alloc, &.{ remote_dir, std.fs.path.basename(source) }) catch {
        owner.window.?.unref();
        owner.arena.deinit();
        a.destroy(owner);
        win.addToast("Unable to prepare remote upload.");
        return true;
    };
    const params = p.object(alloc, .{
        .workspace_id = p.str(alloc.dupe(u8, id(tab)) catch return uploadStartFailed(owner, win)),
        .source = p.str(alloc.dupe(u8, source) catch return uploadStartFailed(owner, win)),
        .destination = p.str(destination),
    }) catch return uploadStartFailed(owner, win);
    RemoteJob.start(alloc, "upload", params, owner, UiRequest.complete) catch
        return uploadStartFailed(owner, win);
    return true;
}

fn uploadStartFailed(owner: *UiRequest, win: *Window) bool {
    owner.window.?.unref();
    owner.arena.deinit();
    a.destroy(owner);
    win.addToast("Unable to start remote upload.");
    return true;
}

pub fn addRemoteTerminal(widget: *gtk.Widget) bool {
    const tab = ext.getAncestor(Tab, widget) orelse return false;
    if (metadata(tab.as(gobject.Object)).remote == null) return false;
    uiRequest("terminal.create", tab, null) catch |err| std.log.err("remote terminal: {s}", .{@errorName(err)});
    return true;
}
pub fn closeRemoteTerminal(surface: *Surface) bool {
    const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return false;
    if (metadata(tab.as(gobject.Object)).remote == null) return false;
    // Closing a local surface detaches its transport. Persistent remote PTYs
    // are destroyed only by the explicit terminal/session cleanup APIs.
    return false;
}
pub fn closeRemoteWorkspace(tab: *Tab) bool {
    if (detaching) return false;
    const data = metadata(tab.as(gobject.Object));
    if (data.remote == null or data.remote_closed) return false;
    uiRequest("workspace.close", tab, null) catch |err| std.log.err("remote close: {s}", .{@errorName(err)});
    return true;
}
pub fn closeRemoteWindow(win: *Window) bool {
    if (detaching) return false;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ids = remoteWorkspaces(arena.allocator(), win) catch {
        win.addToast("Unable to enumerate remote sessions; close cancelled.");
        return true;
    };
    if (ids.array.items.len == 0) return false;
    const owner = a.create(UiRequest) catch return true;
    owner.* = .{ .arena = .init(a), .window = win.ref() };
    const alloc = owner.arena.allocator();
    const params = p.object(alloc, .{ .window_id = p.str(id(win)), .force = p.boolean(true) }) catch {
        UiRequest.complete(owner, .{ .err = "OutOfMemory" });
        return true;
    };
    const request = p.object(alloc, .{ .method = p.str("window.close"), .params = params }) catch {
        UiRequest.complete(owner, .{ .err = "OutOfMemory" });
        return true;
    };
    dispatch(alloc, request, owner, UiRequest.complete);
    return true;
}
pub fn detachRemotes() void {
    detaching = true;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const wins = windows(arena.allocator()) catch return;
    for (wins) |win| {
        const view = win.getTabView();
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const tab = gobject.ext.cast(Tab, view.getNthPage(i).getChild()) orelse continue;
            metadata(tab.as(gobject.Object)).remote_closed = true;
        }
    }
}

fn remoteWorkspaces(alloc: std.mem.Allocator, win: *Window) !p.Value {
    var ids: std.array_list.Managed(p.Value) = .init(alloc);
    const view = win.getTabView();
    var i: c_int = 0;
    while (i < view.getNPages()) : (i += 1) {
        const tab = gobject.ext.cast(Tab, view.getNthPage(i).getChild()) orelse continue;
        const data = metadata(tab.as(gobject.Object));
        if (data.remote != null and !data.remote_closed) try ids.append(p.str(try alloc.dupe(u8, id(tab))));
    }
    return .{ .array = ids };
}
fn uiRequest(method: []const u8, tab: *Tab, surface: ?*Surface) !void {
    const owner = try a.create(UiRequest);
    owner.* = .{ .arena = .init(a) };
    if (ext.getAncestor(Window, tab.as(gtk.Widget))) |win| owner.window = win.ref();
    errdefer {
        if (owner.window) |win| win.unref();
        owner.arena.deinit();
        a.destroy(owner);
    }
    const alloc = owner.arena.allocator();
    var params = try p.object(alloc, .{ .workspace_id = p.str(try alloc.dupe(u8, id(tab))), .force = p.boolean(true) });
    if (surface) |s| try params.object.put("terminal_id", p.str(try alloc.dupe(u8, id(s))));
    const request = try p.object(alloc, .{ .method = p.str(method), .params = params });
    dispatch(alloc, request, owner, UiRequest.complete);
}

pub fn workspaceDisposing(tab: *Tab) void {
    const data = metadata(tab.as(gobject.Object));
    if (data.remote != null and !data.remote_closed) {
        data.remote_closed = true;
        closeDisposedRemote(tab) catch |err| std.log.err("remote workspace close failed: {s}", .{@errorName(err)});
    }
    for (data.browsers.items) |pane| pane.destroy();
    data.browsers.clearRetainingCapacity();
}

fn closeDisposedRemote(tab: *Tab) !void {
    const owner = try a.create(UiRequest);
    owner.* = .{ .arena = .init(a) };
    errdefer {
        owner.arena.deinit();
        a.destroy(owner);
    }
    const alloc = owner.arena.allocator();
    const params = try p.object(alloc, .{ .workspace_id = p.str(try alloc.dupe(u8, id(tab))) });
    try RemoteJob.start(alloc, "close", params, owner, UiRequest.complete);
}

pub const ActivityItem = struct {
    notification_id: []const u8,
    title: []const u8,
    body: []const u8,
    created_at: i64,
    subtitle: []const u8,
    level: []const u8,
    read: bool,
};

pub fn activityItems(alloc: std.mem.Allocator, win: *Window) ![]ActivityItem {
    var result: std.ArrayList(ActivityItem) = .empty;
    var index = notifications.items.len;
    while (index > 0) {
        index -= 1;
        const item = &notifications.items[index];
        if (!eq(u8, &item.window_id, id(win))) continue;
        try result.append(alloc, .{
            .notification_id = &item.id,
            .title = item.title,
            .body = item.body,
            .created_at = item.created_at,
            .subtitle = item.subtitle,
            .level = item.level,
            .read = item.read,
        });
    }
    return result.toOwnedSlice(alloc);
}

pub const SidebarTodo = struct {
    text: []const u8,
    done: bool = false,
};

pub const WorkspaceRowData = struct {
    unread_count: usize = 0,
    preview: ?[]const u8 = null,
    /// The workspace description tier: the `description` status key only,
    /// matching cmux's `customDescription`. Agent status text never lands
    /// here, so a running agent cannot clobber the description line.
    description: ?[]const u8 = null,
    /// Every other status key, one entry per key, in cmux display order
    /// (`Workspace.sidebarStatusEntriesInDisplayOrder`): newest first, ties
    /// broken by key. Owned by the caller's allocator.
    statuses: []SidebarStatusItem = &.{},
    git_branch: ?[]const u8 = null,
    git_dirty: bool = false,
    pinned: bool = false,
    muted: bool = false,
    remote: bool = false,
    progress: ?i64 = null,
    progress_label: ?[]const u8 = null,
    last_log: ?[]const u8 = null,
    task_status: ?[]const u8 = null,
    agent_busy: bool = false,
    pr_label: ?[]const u8 = null,
    pr_url: ?[]const u8 = null,
    ports: []const u16 = &.{},
    todos: []const SidebarTodo = &.{},
};

/// Strings are borrowed from automation stores and must be copied before mutation.
pub fn workspaceRowData(alloc: std.mem.Allocator, tab: *Tab) WorkspaceRowData {
    var result: WorkspaceRowData = .{};
    var preview_at: i64 = std.math.minInt(i64);
    var description_at: i64 = std.math.minInt(i64);
    var statuses: std.ArrayList(SidebarStatusItem) = .empty;
    if (existingMetadata(tab.as(gobject.Object))) |data| {
        for (notifications.items) |item| {
            if (!eq(u8, &item.workspace_id, data.id[0..32])) continue;
            if (item.read) continue;
            result.unread_count += 1;
            const text = if (item.body.len > 0)
                item.body
            else if (item.subtitle.len > 0)
                item.subtitle
            else
                item.title;
            if (text.len > 0 and item.created_at >= preview_at) {
                result.preview = text;
                preview_at = item.created_at;
            }
        }
        collectWorkspaceStatuses(alloc, &statuses, &result, &description_at, data);
        result.git_branch = data.git_branch;
        result.git_dirty = data.git_dirty;
        result.pinned = data.pinned;
        result.muted = data.muted;
        result.remote = data.remote != null;
        result.progress = data.progress;
        result.progress_label = data.progress_label;
        result.task_status = data.task_status;
        result.agent_busy = data.prompt_turn_busy;
        if (data.logs.items.len > 0) result.last_log = data.logs.items[data.logs.items.len - 1].text;
        if (data.pull_request) |pr| {
            result.pr_label = pr.label;
            result.pr_url = pr.url;
        }
        result.ports = data.listening_ports.items;
    }

    // Include inactive terminals within a pane, not only visible split leaves.
    const split_tree = tab.getSplitTree();
    var surface_index: usize = 0;
    while (surface_index < split_tree.surfaceCount()) : (surface_index += 1) {
        const surface = split_tree.surfaceAt(surface_index) orelse continue;
        const data = existingMetadata(surface.as(gobject.Object)) orelse continue;
        collectWorkspaceStatuses(alloc, &statuses, &result, &description_at, data);
        if (data.progress != null) result.progress = data.progress;
        if (data.progress_label) |label| result.progress_label = label;
        if (data.logs.items.len > 0) result.last_log = data.logs.items[data.logs.items.len - 1].text;
        if (data.prompt_turn_busy) result.agent_busy = true;
        if (data.pull_request) |pr| {
            result.pr_label = pr.label;
            result.pr_url = pr.url;
        }
        if (data.listening_ports.items.len > 0) result.ports = data.listening_ports.items;
    }
    if (tab.getActiveSurface()) |surface| {
        if (existingMetadata(surface.as(gobject.Object))) |data| {
            if (data.git_branch) |branch| {
                result.git_branch = branch;
                result.git_dirty = data.git_dirty;
            }
        }
    }
    std.mem.sort(SidebarStatusItem, statuses.items, {}, statusDisplayPrecedes);
    result.statuses = statuses.toOwnedSlice(alloc) catch statuses: {
        statuses.deinit(alloc);
        break :statuses &.{};
    };
    result.todos = collectWorkspaceTodos(alloc, tab);
    return result;
}

/// One row per status key: the newest write for a key wins, whether it landed
/// on the workspace or on one of its terminals. `description` is a separate
/// tier and is never rendered as a status row.
fn collectWorkspaceStatuses(
    alloc: std.mem.Allocator,
    statuses: *std.ArrayList(SidebarStatusItem),
    result: *WorkspaceRowData,
    description_at: *i64,
    data: *const Metadata,
) void {
    for (data.statuses.items) |entry| {
        if (eq(u8, entry.key, "description")) {
            if (entry.updated_at >= description_at.*) {
                result.description = entry.text;
                description_at.* = entry.updated_at;
            }
            continue;
        }
        const item: SidebarStatusItem = .{
            .key = entry.key,
            .text = entry.text,
            .icon = entry.icon,
            .color = entry.color,
            .updated_at = entry.updated_at,
        };
        for (statuses.items) |*existing| {
            if (!eq(u8, existing.key, entry.key)) continue;
            if (entry.updated_at >= existing.updated_at) existing.* = item;
            break;
        } else statuses.append(alloc, item) catch return;
    }
}

fn collectWorkspaceTodos(alloc: std.mem.Allocator, tab: *Tab) []const SidebarTodo {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const records = feature_store.list(arena.allocator(), "todos") catch return &.{};
    if (records != .array) return &.{};
    var todos: std.ArrayList(SidebarTodo) = .empty;
    const workspace_id = id(tab);
    for (records.array.items) |record| {
        const value = record.object.get("value") orelse continue;
        if (value != .object) continue;
        const owner = (p.optionalString(value, "workspace_id") catch null) orelse continue;
        if (!eq(u8, owner, workspace_id)) continue;
        const text = (p.optionalString(value, "text") catch null) orelse continue;
        if (text.len == 0) continue;
        const done = if (value.object.get("done")) |flag| flag == .bool and flag.bool else false;
        const copy = alloc.dupe(u8, text) catch break;
        todos.append(alloc, .{ .text = copy, .done = done }) catch {
            alloc.free(copy);
            break;
        };
        if (todos.items.len == 8) break;
    }
    return todos.toOwnedSlice(alloc) catch {
        for (todos.items) |item| alloc.free(item.text);
        todos.deinit(alloc);
        return &.{};
    };
}

fn statusDisplayPrecedes(_: void, lhs: SidebarStatusItem, rhs: SidebarStatusItem) bool {
    if (lhs.updated_at != rhs.updated_at) return lhs.updated_at > rhs.updated_at;
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

pub const SidebarStatusItem = struct {
    key: []const u8,
    text: []const u8,
    icon: ?[]const u8,
    color: ?[]const u8,
    updated_at: i64,
};

pub const SidebarLogItem = struct {
    text: []const u8,
    level: []const u8,
};

pub const SidebarPullRequest = struct {
    number: i64,
    label: []const u8,
    url: []const u8,
    status: []const u8,
    branch: ?[]const u8,
};

pub const SidebarMetadata = struct {
    statuses: []SidebarStatusItem,
    progress: ?i64,
    progress_label: ?[]const u8,
    logs: []SidebarLogItem,
    git_branch: ?[]const u8,
    git_dirty: bool,
    pull_request: ?SidebarPullRequest,
    listening_ports: []const u16,

    pub fn deinit(self: SidebarMetadata, alloc: std.mem.Allocator) void {
        alloc.free(self.statuses);
        alloc.free(self.logs);
    }
};

pub fn sidebarMetadata(alloc: std.mem.Allocator, win: *Window) !SidebarMetadata {
    const empty: SidebarMetadata = .{
        .statuses = &.{},
        .progress = null,
        .progress_label = null,
        .logs = &.{},
        .git_branch = null,
        .git_dirty = false,
        .pull_request = null,
        .listening_ports = &.{},
    };
    const page = win.getTabView().getSelectedPage() orelse return empty;
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return error.TargetNotFound;
    const surface = tab.getActiveSurface() orelse return empty;
    const data = metadata(surface.as(gobject.Object));
    const statuses = try alloc.alloc(SidebarStatusItem, data.statuses.items.len);
    errdefer alloc.free(statuses);
    for (data.statuses.items, statuses) |entry, *item| item.* = .{
        .key = entry.key,
        .text = entry.text,
        .icon = entry.icon,
        .color = entry.color,
        .updated_at = entry.updated_at,
    };
    const log_count = @min(data.logs.items.len, 20);
    const logs = try alloc.alloc(SidebarLogItem, log_count);
    var index: usize = 0;
    while (index < log_count) : (index += 1) {
        const entry = data.logs.items[data.logs.items.len - index - 1];
        logs[index] = .{ .text = entry.text, .level = entry.level };
    }
    return .{
        .statuses = statuses,
        .progress = data.progress,
        .progress_label = data.progress_label,
        .logs = logs,
        .git_branch = data.git_branch,
        .git_dirty = data.git_dirty,
        .pull_request = if (data.pull_request) |entry| .{
            .number = entry.number,
            .label = entry.label,
            .url = entry.url,
            .status = entry.status,
            .branch = entry.branch,
        } else null,
        .listening_ports = data.listening_ports.items,
    };
}

fn refreshActivities() void {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    for (windows(arena.allocator()) catch return) |win| {
        const view = win.getTabView();
        var page_index: c_int = 0;
        while (page_index < view.getNPages()) : (page_index += 1) {
            const page = view.getNthPage(page_index);
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            var unread = false;
            for (notifications.items) |item| if (!item.read and eq(u8, &item.workspace_id, id(tab))) {
                unread = true;
                break;
            };
            page.setNeedsAttention(@intFromBool(unread));
            updatePaneRings(tab);
        }
        win.refreshWorkspaceRows();
        win.refreshActivity();
    }
    sessionChanged();
}

fn updatePaneRings(tab: *Tab) void {
    const tree = tab.getSplitTree();
    const active = tab.getActiveSurface();
    const focused_pane = if (active) |surface| tree.paneObject(surface) else null;
    var index: usize = 0;
    while (index < tree.surfaceCount()) : (index += 1) {
        const surface = tree.surfaceAt(index) orelse continue;
        const pane = tree.paneObject(surface) orelse continue;
        const widget = gobject.ext.cast(gtk.Widget, pane) orelse continue;
        const focused = focused_pane != null and pane == focused_pane;
        const unread = !focused and surfaceHasUnread(tab, surface);
        if (unread) widget.addCssClass("needs-attention") else widget.removeCssClass("needs-attention");
    }
}

fn surfaceHasUnread(tab: *Tab, surface: *Surface) bool {
    const surface_id = id(surface);
    for (notifications.items) |item| {
        if (item.read) continue;
        if (!eq(u8, &item.workspace_id, id(tab))) continue;
        const sid = item.surface_id orelse continue;
        if (eq(u8, &sid, surface_id)) return true;
    }
    return false;
}

pub fn jumpLatestUnread() bool {
    var index = notifications.items.len;
    while (index > 0) {
        index -= 1;
        if (notifications.items[index].read) continue;
        return openActivity(&notifications.items[index].id);
    }
    return false;
}

pub fn markOldestUnreadAndJumpNext() bool {
    var index = notifications.items.len;
    var latest: ?[32]u8 = null;
    while (index > 0) {
        index -= 1;
        if (notifications.items[index].read) continue;
        latest = notifications.items[index].id;
        break;
    }
    oldest_unread_id = latest;
    while (index > 0) {
        index -= 1;
        if (notifications.items[index].read) continue;
        return openActivity(&notifications.items[index].id);
    }
    return false;
}

/// Stores a user-entered workspace description as the "description" status
/// entry on the tab, matching what `clm status --key description` would set.
pub fn setWorkspaceDescription(tab: *Tab, text: []const u8) void {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return;
    const data = metadata(tab.as(gobject.Object));
    const key_copy = a.dupe(u8, "description") catch return;
    const text_copy = a.dupe(u8, text) catch {
        a.free(key_copy);
        return;
    };
    const entry: StatusEntry = .{
        .key = key_copy,
        .text = text_copy,
        .icon = null,
        .color = null,
        .updated_at = std.time.milliTimestamp(),
    };
    for (data.statuses.items, 0..) |existing, index| {
        if (!eq(u8, existing.key, entry.key)) continue;
        data.statuses.items[index].deinit();
        data.statuses.items[index] = entry;
        refreshActivities();
        return;
    }
    if (data.statuses.items.len == 32) data.statuses.orderedRemove(0).deinit();
    data.statuses.append(a, entry) catch {
        entry.deinit();
        return;
    };
    refreshActivities();
}

pub fn workspaceFocused(tab: *Tab) void {
    if (!restoring) markNotificationsRead(tab, tab.getActiveSurface());
    refreshActivities();
}

pub fn surfaceFocused(surface: *Surface) void {
    const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return;
    if (!restoring) markNotificationsRead(tab, surface);
    refreshActivities();
}

fn markNotificationsRead(tab: *Tab, surface: ?*Surface) void {
    const surface_id = if (surface) |value| id(value) else null;
    for (notifications.items) |*item| {
        if (item.read or !eq(u8, &item.workspace_id, id(tab))) continue;
        if (item.surface_id) |sid| {
            if (surface_id == null or !eq(u8, &sid, surface_id.?)) continue;
        } else if (surface != null) continue;
        item.read = true;
    }
}
fn notificationIndex(notification_id: []const u8) ?usize {
    for (notifications.items, 0..) |item, index|
        if (std.ascii.eqlIgnoreCase(&item.id, notification_id)) return index;
    return null;
}

pub fn openActivity(notification_id: []const u8) bool {
    const index = notificationIndex(notification_id) orelse return false;
    const item = &notifications.items[index];
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const t = if (item.surface_id) |surface_id|
        find(arena.allocator(), "surface_id", &surface_id) catch
            find(arena.allocator(), "workspace_id", &item.workspace_id) catch return false
    else
        find(arena.allocator(), "workspace_id", &item.workspace_id) catch return false;
    item.read = true;
    focus(t);
    refreshActivities();
    return true;
}

pub fn randomId() [32]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Remote directory metadata must never become a local subprocess cwd.
pub fn localDirectory(surface: *Surface) ?[:0]const u8 {
    if (ext.getAncestor(Tab, surface.as(gtk.Widget))) |tab| {
        if (metadata(tab.as(gobject.Object)).remote != null) return null;
    }
    return surface.getPwd();
}

pub fn subprocessEnv(surface: *Surface, env: *std.process.EnvMap) !void {
    const surface_id = id(surface);
    try env.put("COLM_TERMINAL_ID", surface_id);
    try env.put("COLM_SURFACE_ID", surface_id);
    try env.put("CMUX_SURFACE_ID", surface_id);
    if (ext.getAncestor(Tab, surface.as(gtk.Widget))) |tab| {
        const pane_id: []const u8 = if (tab.getSplitTree().paneObject(surface)) |pane|
            &metadata(pane).id
        else
            surface_id;
        try env.put("COLM_PANE_ID", pane_id);
        try env.put("CMUX_PANE_ID", pane_id);
        try env.put("CMUX_TAB_ID", pane_id);
        try env.put("COLM_WORKSPACE_ID", id(tab));
        try env.put("CMUX_WORKSPACE_ID", id(tab));
    }
    if (ext.getAncestor(Window, surface.as(gtk.Widget))) |win| {
        try env.put("COLM_WINDOW_ID", id(win));
        try env.put("CMUX_WINDOW_ID", id(win));
    }
    const path = try @import("control.zig").socketPath(a);
    defer a.free(path);
    try env.put("COLM_SOCKET", path);
    try env.put("CMUX_SOCKET_PATH", path);
    if (std.posix.getenv("CMUX_SOCKET_PASSWORD")) |password|
        try env.put("CMUX_SOCKET_PASSWORD", password);
}

pub fn sessionChanged() void {
    if (restoring or session_state.disabled() or session_save_source != null) return;
    session_save_source = glib.timeoutAdd(750, saveSessionTimeout, null);
}

fn saveSessionTimeout(_: ?*anyopaque) callconv(.c) c_int {
    session_save_source = null;
    saveSession() catch |err| std.log.err("session save failed: {s}", .{@errorName(err)});
    return 0;
}

fn persistScrollback(alloc: std.mem.Allocator, surface: *Surface) !void {
    const core = surface.core() orelse return;
    core.renderer_state.mutex.lock();
    const text = core.io.terminal.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} }) catch |err| {
        core.renderer_state.mutex.unlock();
        return err;
    };
    core.renderer_state.mutex.unlock();
    defer alloc.free(text);

    const limit = 1024 * 1024;
    var start: usize = text.len -| limit;
    while (start < text.len and text[start] & 0xc0 == 0x80) start += 1;
    try session_state.saveScrollback(alloc, id(surface), text[start..]);
}

fn sessionSnapshot(alloc: std.mem.Allocator) !p.Value {
    const previous_format = output_id_format;
    output_id_format = .uuids;
    defer output_id_format = previous_format;
    var window_values: std.array_list.Managed(p.Value) = .init(alloc);
    for (try windows(alloc)) |win| {
        var workspace_values: std.array_list.Managed(p.Value) = .init(alloc);
        const view = win.getTabView();
        var workspace_index: c_int = 0;
        while (workspace_index < view.getNPages()) : (workspace_index += 1) {
            const page = view.getNthPage(workspace_index);
            const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
            const split_tree = tab.getSplitTree();
            var pane_values: std.array_list.Managed(p.Value) = .init(alloc);
            var surface_index: usize = 0;
            while (surface_index < split_tree.surfaceCount()) {
                const first = split_tree.surfaceAt(surface_index).?;
                const pane_object = split_tree.paneObject(first).?;
                const active = split_tree.paneActiveSurface(first) orelse first;
                var surface_values: std.array_list.Managed(p.Value) = .init(alloc);
                while (surface_index < split_tree.surfaceCount()) : (surface_index += 1) {
                    const surface = split_tree.surfaceAt(surface_index).?;
                    if (split_tree.paneObject(surface).? != pane_object) break;
                    persistScrollback(alloc, surface) catch |err| {
                        std.log.warn("unable to save terminal scrollback: {s}", .{@errorName(err)});
                    };
                    var value = try terminalValue(alloc, win, tab, surface);
                    const data = metadata(surface.as(gobject.Object));
                    var status_values: std.array_list.Managed(p.Value) = .init(alloc);
                    for (data.statuses.items) |*entry| try status_values.append(try statusValue(alloc, entry));
                    var log_values: std.array_list.Managed(p.Value) = .init(alloc);
                    for (data.logs.items) |*entry| try log_values.append(try logValue(alloc, entry));
                    try value.object.put("statuses", .{ .array = status_values });
                    try value.object.put("progress", if (data.progress) |progress| p.integer(progress) else .null);
                    try value.object.put("progress_label", if (data.progress_label) |label| p.str(label) else .null);
                    try value.object.put("logs", .{ .array = log_values });
                    scanAgentArgv(surface);
                    try value.object.put("resume_command", if (data.resume_command) |command| p.str(command) else .null);
                    try value.object.put("tmux_session", if (data.tmux_session) |session| p.str(session) else .null);
                    const telemetry = try telemetryValue(alloc, data);
                    try value.object.put("git_branch", telemetry.object.get("git_branch").?);
                    try value.object.put("git_dirty", telemetry.object.get("git_dirty").?);
                    try value.object.put("pull_request", telemetry.object.get("pull_request").?);
                    try value.object.put("listening_ports", telemetry.object.get("listening_ports").?);
                    try value.object.put("active", p.boolean(surface == active));
                    try value.object.put(
                        "title_override",
                        if (surface.getTitleOverride()) |title| p.str(title) else .null,
                    );
                    try value.object.put("scrollback", p.boolean(true));
                    try value.object.put("dock", p.boolean(data.dock));
                    try surface_values.append(value);
                }
                try pane_values.append(try p.object(alloc, .{
                    .pane_id = p.str(&metadata(pane_object).id),
                    .width = p.integer(split_tree.paneWidth(active)),
                    .active = p.boolean(active == tab.getActiveSurface()),
                    .surfaces = p.Value{ .array = surface_values },
                }));
            }
            const workspace_meta = metadata(tab.as(gobject.Object));
            const remote = workspace_meta.remote;
            var workspace_value = try p.object(alloc, .{
                .workspace_id = p.str(id(tab)),
                .name = p.str(if (tab.getTitleOverride()) |name| name else std.mem.span(page.getTitle())),
                .active = p.boolean(view.getSelectedPage() == page),
                .pinned = p.boolean(workspace_meta.pinned),
                .muted = p.boolean(workspace_meta.muted),
                .task_status = if (workspace_meta.task_status) |value| p.str(value) else .null,
                .remote = p.boolean(remote != null),
                .remote_host = if (remote) |value| p.str(value.host) else .null,
                .remote_cwd = if (remote) |value| p.str(value.cwd) else .null,
                .remote_proxy = if (remote) |value| p.str(value.proxy) else .null,
                .remote_capability = if (remote) |value| p.str(&value.capability) else .null,
                .remote_terminal_transport = if (remote) |value| p.str(value.terminal_transport) else .null,
                .remote_terminal_profile = if (remote) |value| p.str(value.terminal_profile) else .null,
                .remote_tmux_session = if (remote) |value| if (value.tmux_session) |session| p.str(session) else .null else .null,
                .panes = p.Value{ .array = pane_values },
            });
            try workspace_value.object.put("group_key", if (workspace_meta.group_key) |value| p.str(value) else .null);

            try workspace_value.object.put("group_name", if (workspace_meta.group_name) |value| p.str(value) else .null);
            var browser_values: std.array_list.Managed(p.Value) = .init(alloc);
            for (workspace_meta.browsers.items) |pane| {
                if (pane.disposed) continue;
                try browser_values.append(try p.object(alloc, .{
                    .browser_id = p.str(pane.id),
                    .uri = p.str(pane.currentUri()),
                    .profile = if (pane.session.profile) |name| p.str(name) else .null,
                }));
            }
            try workspace_value.object.put("browsers", .{ .array = browser_values });
            try workspace_values.append(workspace_value);
        }
        try window_values.append(try p.object(alloc, .{
            .window_id = p.str(id(win)),
            .title = p.str(if (win.as(gtk.Window).getTitle()) |title| std.mem.span(title) else ""),
            .active = p.boolean(win.as(gtk.Window).isActive() != 0),
            .workspaces = p.Value{ .array = workspace_values },
        }));
    }
    var notification_values: std.array_list.Managed(p.Value) = .init(alloc);
    for (notifications.items) |*item|
        try notification_values.append(try notificationValue(alloc, item));
    return p.object(alloc, .{
        .version = p.integer(1),
        .saved_at_unix_ms = p.integer(std.time.milliTimestamp()),
        .windows = p.Value{ .array = window_values },
        .notifications = p.Value{ .array = notification_values },
    });
}

pub fn saveSession() !void {
    if (restoring or session_state.disabled()) return;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const snapshot = try sessionSnapshot(alloc);
    const json = try std.json.Stringify.valueAlloc(alloc, snapshot, .{});
    try session_state.saveSnapshot(alloc, json);
}
fn arrayField(value: p.Value, name: []const u8, maximum: usize) ![]p.Value {
    if (value != .object) return error.InvalidSessionState;
    const field = value.object.get(name) orelse return error.InvalidSessionState;
    if (field != .array or field.array.items.len > maximum) return error.InvalidSessionState;
    return field.array.items;
}

fn savedId(value: p.Value, name: []const u8) ![]const u8 {
    const value_id = try p.string(value, name);
    if (value_id.len != 32) return error.InvalidSessionState;
    for (value_id) |byte| if (!std.ascii.isHex(byte)) return error.InvalidSessionState;
    return value_id;
}

fn assignId(object: *gobject.Object, value_id: []const u8) void {
    @memcpy(metadata(object).id[0..32], value_id);
    metadata(object).id[32] = 0;
}

fn nullableString(value: p.Value, name: []const u8) !?[]const u8 {
    if (value != .object) return error.InvalidSessionState;
    const field = value.object.get(name) orelse return null;
    if (field == .null) return null;
    if (field != .string or std.mem.indexOfScalar(u8, field.string, 0) != null)
        return error.InvalidSessionState;
    return field.string;
}
fn optionalArrayField(value: p.Value, name: []const u8, maximum: usize) !?[]p.Value {
    if (value != .object) return error.InvalidSessionState;
    const field = value.object.get(name) orelse return null;
    if (field != .array or field.array.items.len > maximum) return error.InvalidSessionState;
    return field.array.items;
}

fn savedTimestamp(value: p.Value, name: []const u8) !i64 {
    if (value != .object) return error.InvalidSessionState;
    const field = value.object.get(name) orelse return error.InvalidSessionState;
    if (field != .integer or field.integer < 0) return error.InvalidSessionState;
    return field.integer;
}

fn restoreSurfaceMetadata(saved: p.Value, surface: *Surface) !void {
    const data = metadata(surface.as(gobject.Object));
    if (try optionalArrayField(saved, "statuses", 32)) |statuses| {
        for (statuses) |status| {
            const key = try p.string(status, "key");
            const text = try p.string(status, "text");
            if (key.len > 128 or text.len > 2048) return error.InvalidSessionState;
            try data.statuses.append(a, .{
                .key = try a.dupe(u8, key),
                .text = try a.dupe(u8, text),
                .icon = if (try nullableString(status, "icon")) |value| try a.dupe(u8, value) else null,
                .color = if (try nullableString(status, "color")) |value| try a.dupe(u8, value) else null,
                .updated_at = try savedTimestamp(status, "updated_at"),
            });
        }
    }
    if (saved.object.get("progress")) |progress| {
        if (progress == .integer) {
            if (progress.integer < 0 or progress.integer > 100) return error.InvalidSessionState;
            data.progress = progress.integer;
        } else if (progress != .null) return error.InvalidSessionState;
    }
    if (try nullableString(saved, "progress_label")) |label|
        data.progress_label = try a.dupe(u8, label);
    if (try optionalArrayField(saved, "logs", 256)) |logs| {
        for (logs) |log_entry| {
            const entry_id = try savedId(log_entry, "log_id");
            const text = try p.string(log_entry, "text");
            const level = try p.string(log_entry, "level");
            if (text.len > 8192 or !inWords("trace debug info warn error", level)) return error.InvalidSessionState;
            try data.logs.append(a, .{
                .id = entry_id[0..32].*,
                .text = try a.dupe(u8, text),
                .level = try a.dupe(u8, level),
                .created_at = try savedTimestamp(log_entry, "created_at"),
            });
        }
    }
    if (try nullableString(saved, "git_branch")) |branch| {
        if (branch.len > 1024) return error.InvalidSessionState;
        data.git_branch = try a.dupe(u8, branch);
        data.git_dirty = savedBool(saved, "git_dirty");
    }
    if (saved.object.get("pull_request")) |request| {
        if (request != .null) {
            if (request != .object) return error.InvalidSessionState;
            const number = request.object.get("number") orelse return error.InvalidSessionState;
            if (number != .integer or number.integer <= 0) return error.InvalidSessionState;
            const label = try p.string(request, "label");
            const url = try p.string(request, "url");
            const status = try p.string(request, "status");
            if (label.len > 2048 or url.len > 8192 or !inWords("open merged closed", status))
                return error.InvalidSessionState;
            var transferred = false;
            const label_copy = try a.dupe(u8, label);
            errdefer if (!transferred) a.free(label_copy);
            const url_copy = try a.dupe(u8, url);
            errdefer if (!transferred) a.free(url_copy);
            const status_copy = try a.dupe(u8, status);
            errdefer if (!transferred) a.free(status_copy);
            const branch_copy = if (try nullableString(request, "branch")) |value| try a.dupe(u8, value) else null;
            errdefer if (!transferred) if (branch_copy) |value| a.free(value);
            data.pull_request = .{
                .number = number.integer,
                .label = label_copy,
                .url = url_copy,
                .status = status_copy,
                .branch = branch_copy,
            };
            transferred = true;
        }
    }
    if (try optionalArrayField(saved, "listening_ports", 128)) |ports| {
        for (ports) |port| {
            if (port != .integer or port.integer <= 0 or port.integer > 65535)
                return error.InvalidSessionState;
            try data.listening_ports.append(a, @intCast(port.integer));
        }
    }
    data.dock = savedBool(saved, "dock");
    if (try nullableString(saved, "resume_command")) |command| {
        if (data.resume_command) |old| a.free(old);
        data.resume_command = try a.dupe(u8, command);
    }
    if (try nullableString(saved, "tmux_session")) |session| {
        if (data.tmux_session) |old| a.free(old);
        data.tmux_session = try a.dupe(u8, session);
    }
}

fn restoreNotifications(snapshot: p.Value) !void {
    var restored: std.ArrayList(NotificationRecord) = .empty;
    errdefer {
        for (restored.items) |item| item.deinit();
        restored.deinit(a);
    }
    if (try optionalArrayField(snapshot, "notifications", 512)) |saved_notifications| {
        for (saved_notifications) |saved| {
            const saved_surface = try nullableString(saved, "surface_id");
            if (saved_surface) |surface_id| {
                if (surface_id.len != 32) return error.InvalidSessionState;
                for (surface_id) |byte| if (!std.ascii.isHex(byte)) return error.InvalidSessionState;
            }
            const title = try p.string(saved, "title");
            const subtitle = (try nullableString(saved, "subtitle")) orelse "";
            const body = try p.string(saved, "body");
            const level = (try nullableString(saved, "level")) orelse "info";
            const tab_title = try p.string(saved, "tab_title");
            if (title.len > 2048 or subtitle.len > 2048 or body.len > 8192 or tab_title.len > 2048 or
                !inWords("info warning error", level))
                return error.InvalidSessionState;
            const notification_id = try savedId(saved, "notification_id");
            const window_id = try savedId(saved, "window_id");
            const workspace_id = try savedId(saved, "workspace_id");
            var transferred = false;
            const title_copy = try a.dupe(u8, title);
            errdefer if (!transferred) a.free(title_copy);
            const subtitle_copy = try a.dupe(u8, subtitle);
            errdefer if (!transferred) a.free(subtitle_copy);
            const body_copy = try a.dupe(u8, body);
            errdefer if (!transferred) a.free(body_copy);
            const level_copy = try a.dupe(u8, level);
            errdefer if (!transferred) a.free(level_copy);
            const tab_title_copy = try a.dupe(u8, tab_title);
            errdefer if (!transferred) a.free(tab_title_copy);
            try restored.append(a, .{
                .id = notification_id[0..32].*,
                .window_id = window_id[0..32].*,
                .workspace_id = workspace_id[0..32].*,
                .surface_id = if (saved_surface) |surface_id| surface_id[0..32].* else null,
                .title = title_copy,
                .subtitle = subtitle_copy,
                .body = body_copy,
                .level = level_copy,
                .tab_title = tab_title_copy,
                .category = try a.dupe(u8, (try nullableString(saved, "category")) orelse "generic"),
                .created_at = try savedTimestamp(saved, "created_at"),
                .read = savedBool(saved, "read"),
            });
            transferred = true;
        }
    }
    for (notifications.items) |item| item.deinit();
    notifications.deinit(a);
    notifications = restored;
}

fn savedBool(value: p.Value, name: []const u8) bool {
    const field = if (value == .object) value.object.get(name) orelse return false else return false;
    return field == .bool and field.bool;
}

fn savedPaneWidth(value: p.Value) !c_int {
    const field = if (value == .object) value.object.get("width") else null;
    if (field == null or field.? != .integer) return 0;
    if (field.?.integer < 0 or field.?.integer > 10000) return 0;
    return @intCast(field.?.integer);
}
fn restoredCommand(
    alloc: std.mem.Allocator,
    surface: p.Value,
) !?Config.Command {
    if (try nullableString(surface, "tmux_session")) |session| {
        if (session.len == 0 or session.len > 128) return error.InvalidSessionState;
        const args = try alloc.alloc([:0]const u8, 4);
        args[0] = "tmux";
        args[1] = "attach-session";
        args[2] = "-t";
        args[3] = try alloc.dupeZ(u8, session);
        return .{ .direct = args };
    }
    if (try nullableString(surface, "resume_command")) |command| {
        if (command.len == 0 or command.len > 4096) return error.InvalidSessionState;
        const args = try alloc.alloc([:0]const u8, 3);
        args[0] = "/bin/sh";
        args[1] = "-lc";
        args[2] = try alloc.dupeZ(u8, command);
        return .{ .direct = args };
    }
    if (!savedBool(surface, "scrollback")) return null;
    const surface_id = try savedId(surface, "surface_id");
    const path = try session_state.scrollbackPath(alloc, surface_id);
    var file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    if ((try file.stat()).size == 0) return null;

    const args = try alloc.alloc([:0]const u8, 5);
    args[0] = "/bin/sh";
    args[1] = "-lc";
    args[2] = "cat -- \"$1\"; exec \"${SHELL:-/bin/sh}\" -l";
    args[3] = "colm-session-restore";
    args[4] = try alloc.dupeZ(u8, path);
    return .{ .direct = args };
}

fn restoredTitle(alloc: std.mem.Allocator, surface: p.Value) !?[:0]const u8 {
    const title = (try nullableString(surface, "title_override")) orelse return null;
    return @as(?[:0]const u8, try alloc.dupeZ(u8, title));
}

fn restoredDirectory(alloc: std.mem.Allocator, surface: p.Value) !?[:0]const u8 {
    const cwd = (try nullableString(surface, "directory")) orelse return null;
    if (cwd.len == 0) return null;
    if (!std.fs.path.isAbsolute(cwd)) return error.InvalidSessionState;
    return try alloc.dupeZ(u8, cwd);
}

fn destroyFailedRestoreWindow(data: ?*anyopaque) callconv(.c) c_int {
    const win: *Window = @ptrCast(@alignCast(data.?));
    win.as(gtk.Window).destroy();
    win.unref();
    return 0;
}

fn resumeStoredAgent(alloc: std.mem.Allocator, tab: *Tab) !void {
    const sessions = try agent_store.listSessions(alloc);
    if (sessions != .array) return;
    const workspace_id = id(tab);
    for (sessions.array.items) |item| {
        if (item != .object) continue;
        const ws = if (item.object.get("workspace_id")) |value|
            if (value == .string) value.string else continue
        else
            continue;
        if (!eq(u8, ws, workspace_id)) continue;
        const provider = if (item.object.get("provider")) |value|
            if (value == .string) value.string else continue
        else
            continue;
        const session_id = if (item.object.get("session_id")) |value|
            if (value == .string) value.string else continue
        else
            continue;
        const command = try agent_store.launchCommand(alloc, provider, session_id, null, null);
        const surface = tab.getActiveSurface() orelse return;
        try PendingInput.start(surface, command);
        return;
    }
}

fn restoreSnapshot(alloc: std.mem.Allocator, snapshot: p.Value, preserve_ids: bool) !bool {
    const app = Application.default().as(gio.Application);
    app.hold();
    defer app.release();
    if (snapshot != .object) return error.InvalidSessionState;
    const version = snapshot.object.get("version") orelse return error.InvalidSessionState;
    if (version != .integer or version.integer != 1) return error.UnsupportedSessionVersion;
    const saved_windows = try arrayField(snapshot, "windows", 32);
    if (saved_windows.len == 0) return false;
    if (preserve_ids) try restoreNotifications(snapshot);

    var created: std.ArrayList(*Window) = .empty;
    var restore_succeeded = false;
    defer {
        if (restore_succeeded) {
            for (created.items) |win| win.unref();
        } else {
            for (created.items) |win| _ = glib.idleAdd(destroyFailedRestoreWindow, win);
        }
        created.deinit(alloc);
    }
    restoring = true;
    defer restoring = false;
    defer {
        creating_window = null;
        creating_workspace = null;
        creating_terminal = null;
    }

    for (saved_windows) |saved_window| {
        const saved_workspaces = try arrayField(saved_window, "workspaces", 256);
        if (saved_workspaces.len == 0) continue;
        const saved_window_id = try savedId(saved_window, "window_id");
        const generated_window_id = randomId();
        const window_id: []const u8 = if (preserve_ids) saved_window_id else &generated_window_id;
        creating_window = window_id;
        const win = Window.new(Application.default(), .{});
        assignId(win.as(gobject.Object), window_id);
        creating_window = null;
        try created.append(alloc, win.ref());
        var selected_tab: ?*Tab = null;

        for (saved_workspaces) |saved_workspace| {
            const saved_panes = try arrayField(saved_workspace, "panes", 512);
            if (saved_panes.len == 0) continue;
            const saved_workspace_id = try savedId(saved_workspace, "workspace_id");
            const generated_workspace_id = randomId();
            const workspace_id: []const u8 = if (preserve_ids) saved_workspace_id else &generated_workspace_id;
            var tab: ?*Tab = null;
            var selected_surface: ?*Surface = null;

            for (saved_panes, 0..) |saved_pane, pane_index| {
                const saved_surfaces = try arrayField(saved_pane, "surfaces", 1024);
                if (saved_surfaces.len == 0) return error.InvalidSessionState;
                const saved_pane_id = try savedId(saved_pane, "pane_id");
                const generated_pane_id = randomId();
                const pane_id: []const u8 = if (preserve_ids) saved_pane_id else &generated_pane_id;
                var pane_surface: ?*Surface = null;
                var active_in_pane: ?*Surface = null;

                for (saved_surfaces, 0..) |saved_surface, surface_index| {
                    const saved_surface_id = try savedId(saved_surface, "surface_id");
                    const generated_surface_id = randomId();
                    const surface_id: []const u8 = if (preserve_ids) saved_surface_id else &generated_surface_id;
                    creating_terminal = surface_id;
                    const command_value = try restoredCommand(alloc, saved_surface);
                    const cwd = try restoredDirectory(alloc, saved_surface);
                    const title = try restoredTitle(alloc, saved_surface);
                    const surface: *Surface = if (pane_index == 0 and surface_index == 0) surface: {
                        creating_workspace = workspace_id;
                        const new_tab = win.automationNewTab(command_value, cwd);
                        assignId(new_tab.as(gobject.Object), workspace_id);
                        tab = new_tab;
                        creating_workspace = null;
                        break :surface new_tab.getActiveSurface().?;
                    } else if (surface_index == 0) surface: {
                        const split_tree = tab.?.getSplitTree();
                        try split_tree.newSplit(.right, tab.?.getActiveSurface(), .{
                            .command = command_value,
                            .working_directory = cwd,
                            .title = title,
                        });
                        break :surface tab.?.getActiveSurface().?;
                    } else surface: {
                        try tab.?.getSplitTree().newSurface(pane_surface, .{
                            .command = command_value,
                            .working_directory = cwd,
                            .title = title,
                        });
                        break :surface tab.?.getActiveSurface().?;
                    };
                    assignId(surface.as(gobject.Object), surface_id);
                    creating_terminal = null;
                    try setLocalDirectory(surface, cwd);
                    if (title) |value| surface.setTitleOverride(value);
                    try restoreSurfaceMetadata(saved_surface, surface);
                    if (pane_surface == null) {
                        pane_surface = surface;
                        const pane_object = tab.?.getSplitTree().paneObject(surface) orelse
                            return error.InvalidSessionState;
                        assignId(pane_object, pane_id);
                    }
                    if (savedBool(saved_surface, "active")) active_in_pane = surface;
                }
                try tab.?.getSplitTree().restorePaneWidth(
                    pane_surface orelse return error.InvalidSessionState,
                    try savedPaneWidth(saved_pane),
                );
                if (savedBool(saved_pane, "active")) {
                    selected_surface = active_in_pane orelse pane_surface;
                }
            }

            const workspace = tab orelse return error.InvalidSessionState;
            if (savedBool(saved_workspace, "remote")) {
                const host = try nullableString(saved_workspace, "remote_host") orelse return error.InvalidSessionState;
                const remote_cwd = try nullableString(saved_workspace, "remote_cwd") orelse return error.InvalidSessionState;
                const proxy = try nullableString(saved_workspace, "remote_proxy") orelse return error.InvalidSessionState;
                const capability = try nullableString(saved_workspace, "remote_capability") orelse return error.InvalidSessionState;
                if (capability.len != 64) return error.InvalidSessionState;
                const transport = try nullableString(saved_workspace, "remote_terminal_transport") orelse "ssh";
                const profile = try nullableString(saved_workspace, "remote_terminal_profile") orelse "tmux";
                if (!inWords("ssh mosh", transport) or !inWords("shell tmux", profile)) return error.InvalidSessionState;
                const tmux_session = try nullableString(saved_workspace, "remote_tmux_session");
                metadata(workspace.as(gobject.Object)).remote = .{
                    .host = try a.dupe(u8, host),
                    .cwd = try a.dupe(u8, remote_cwd),
                    .proxy = try a.dupe(u8, proxy),
                    .capability = capability[0..64].*,
                    .terminal_transport = try a.dupe(u8, transport),
                    .terminal_profile = try a.dupe(u8, profile),
                    .tmux_session = if (tmux_session) |value| try a.dupe(u8, value) else null,
                };
                uiRequest("ssh.reconnect", workspace, null) catch |err|
                    std.log.err("restore ssh.reconnect failed: {s}", .{@errorName(err)});
            }
            if (try nullableString(saved_workspace, "name")) |name| {
                workspace.setTitleOverride(try alloc.dupeZ(u8, name));
            }
            const workspace_meta = metadata(workspace.as(gobject.Object));
            workspace_meta.pinned = savedBool(saved_workspace, "pinned");
            workspace_meta.muted = savedBool(saved_workspace, "muted");
            if (try nullableString(saved_workspace, "group_key")) |key| {
                if (workspace_meta.group_key) |value| a.free(value);
                workspace_meta.group_key = try a.dupe(u8, key);
            }
            if (try nullableString(saved_workspace, "group_name")) |name| {
                if (workspace_meta.group_name) |value| a.free(value);
                workspace_meta.group_name = try a.dupe(u8, name);
            }
            if (try nullableString(saved_workspace, "task_status")) |status| {
                if (workspace_meta.task_status) |value| a.free(value);
                workspace_meta.task_status = try a.dupe(u8, status);
            }
            if (saved_workspace.object.get("browsers")) |browsers_value| {
                if (browsers_value == .array) {
                    for (browsers_value.array.items) |saved_browser| {
                        if (saved_browser != .object) continue;
                        var pane_id = randomId();
                        if (try nullableString(saved_browser, "browser_id")) |value| {
                            if (value.len == 32) pane_id = value[0..32].*;
                        }
                        const profile_name = try nullableString(saved_browser, "profile");
                        const profile: ?[]const u8 = if (profile_name) |name|
                            if (eq(u8, name, "ephemeral")) null else name
                        else
                            null;
                        const pane = browser.create(
                            a,
                            workspace.as(gtk.Box),
                            workspace.getSplitTree(),
                            &pane_id,
                            if (workspace_meta.remote) |r| r.proxy else null,
                            profile,
                            if (workspace_meta.remote) |r| r.host else "local",
                        ) catch |err| {
                            std.log.err("restore browser failed: {s}", .{@errorName(err)});
                            continue;
                        };
                        workspace_meta.browsers.append(a, pane) catch {
                            pane.destroy();
                            continue;
                        };
                        if (try nullableString(saved_browser, "uri")) |uri| pane.loadUri(uri);
                    }
                }
            }

            resumeStoredAgent(alloc, workspace) catch |err|
                std.log.err("restore agent resume failed: {s}", .{@errorName(err)});
            if (savedBool(saved_workspace, "active")) selected_tab = workspace;
            if (selected_surface) |surface| try workspace.getSplitTree().automationFocus(surface);
        }

        if (selected_tab) |tab| {
            win.getTabView().setSelectedPage(win.getTabView().getPage(tab.as(gtk.Widget)));
        }
        if (try nullableString(saved_window, "title")) |title| {
            win.as(gtk.Window).setTitle(try alloc.dupeZ(u8, title));
        }
        win.as(gtk.Window).present();
    }
    refreshActivities();
    const restored = created.items.len > 0;
    restore_succeeded = true;
    return restored;
}

fn restoreBytes(alloc: std.mem.Allocator, bytes: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(p.Value, alloc, bytes, .{});
    defer parsed.deinit();
    return restoreSnapshot(alloc, parsed.value, true);
}

pub fn restoreSession() bool {
    if (restore_attempted) return false;
    restore_attempted = true;
    if (session_state.disabled()) return false;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const current = session_state.loadCurrent(alloc) catch null;
    if (current) |bytes| {
        if (restoreBytes(alloc, bytes)) |restored| {
            return restored;
        } else |err| {
            std.log.warn("current session restore failed: {s}", .{@errorName(err)});
        }
    }
    const previous = session_state.loadPrevious(alloc) catch return false;
    return restoreBytes(alloc, previous) catch |err| {
        std.log.warn("previous session restore failed: {s}", .{@errorName(err)});
        return false;
    };
}

pub fn restorePreviousSession() !bool {
    if (session_state.disabled()) return false;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const previous = try session_state.loadPrevious(alloc);
    const existing = try windows(alloc);
    if (!try restoreBytes(alloc, previous)) return false;
    for (existing) |win| win.as(gtk.Window).destroy();
    return true;
}

const Target = struct { window: *Window, tab: ?*Tab = null, surface: ?*Surface = null };
fn windows(alloc: std.mem.Allocator) ![]*Window {
    var result: std.ArrayList(*Window) = .empty;
    var node: ?*glib.List = Application.default().as(gtk.Application).getWindows();
    while (node) |n| : (node = n.f_next) {
        const obj: *gobject.Object = @ptrCast(@alignCast(n.f_data.?));
        if (gobject.ext.cast(Window, obj)) |win| try result.append(alloc, win);
    }
    return result.toOwnedSlice(alloc);
}
fn handleIndex(kind: []const u8, value: []const u8) ?usize {
    var digits = value;
    if (std.mem.indexOfScalar(u8, value, ':')) |separator| {
        if (!std.ascii.eqlIgnoreCase(value[0..separator], kind)) return null;
        digits = value[separator + 1 ..];
    } else {
        for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    }
    const result = std.fmt.parseInt(usize, digits, 10) catch return null;
    return if (result == 0) null else result;
}
fn matchesHandle(kind: []const u8, value: []const u8, data: *const Metadata) bool {
    return std.ascii.eqlIgnoreCase(value, &data.id) or handleIndex(kind, value) == data.ordinal;
}
fn find(alloc: std.mem.Allocator, key: []const u8, value: []const u8) !Target {
    // Handles resolve by each object's lifetime-stable ordinal, never by
    // enumeration position: reorders and closes must not remap targets.
    for (try windows(alloc)) |win| {
        if (eq(u8, key, "window_id") and matchesHandle("window", value, metadata(win.as(gobject.Object))))
            return .{ .window = win };
        const view = win.getTabView();
        var i: c_int = 0;
        while (i < view.getNPages()) : (i += 1) {
            const tab = gobject.ext.cast(Tab, view.getNthPage(i).getChild()) orelse continue;
            if (eq(u8, key, "workspace_id") and matchesHandle("workspace", value, metadata(tab.as(gobject.Object))))
                return .{ .window = win, .tab = tab };
            const split_tree = tab.getSplitTree();
            var surface_index: usize = 0;
            while (surface_index < split_tree.surfaceCount()) : (surface_index += 1) {
                const surface = split_tree.surfaceAt(surface_index).?;
                const pane = split_tree.paneObject(surface) orelse continue;
                if (eq(u8, key, "pane_id") and
                    matchesHandle("pane", value, metadata(pane)))
                {
                    return .{ .window = win, .tab = tab, .surface = split_tree.paneActiveSurface(surface) };
                }
                if (inWords("terminal_id surface_id", key) and
                    matchesHandle("surface", value, metadata(surface.as(gobject.Object))))
                {
                    return .{ .window = win, .tab = tab, .surface = surface };
                }
            }
        }
    }
    return error.TargetNotFound;
}
fn target(alloc: std.mem.Allocator, params: p.Value, key: []const u8) !Target {
    const result = try find(alloc, key, try p.string(params, key));
    if (try p.optionalString(params, "workspace_id")) |workspace| {
        const constraint = try find(alloc, "workspace_id", workspace);
        if (result.tab != constraint.tab) return error.TargetMismatch;
    }
    if (try p.optionalString(params, "window_id")) |window| {
        const constraint = try find(alloc, "window_id", window);
        if (result.window != constraint.window) return error.TargetMismatch;
    }
    return result;
}
const IdFormat = enum { refs, uuids, both };
var output_id_format: IdFormat = .refs;

fn reference(alloc: std.mem.Allocator, kind: []const u8, object_id: []const u8) ![]const u8 {
    const key = if (eq(u8, kind, "surface")) "surface_id" else try std.fmt.allocPrint(alloc, "{s}_id", .{kind});
    const found = try find(alloc, key, object_id);
    const data = if (eq(u8, kind, "window"))
        metadata(found.window.as(gobject.Object))
    else if (eq(u8, kind, "workspace"))
        metadata(found.tab.?.as(gobject.Object))
    else if (eq(u8, kind, "pane"))
        metadata(found.tab.?.getSplitTree().paneObject(found.surface.?).?)
    else
        metadata(found.surface.?.as(gobject.Object));
    return std.fmt.allocPrint(alloc, "{s}:{d}", .{ kind, data.ordinal });
}

fn identifier(alloc: std.mem.Allocator, kind: []const u8, object_id: []const u8) !p.Value {
    return p.str(if (output_id_format == .refs)
        try reference(alloc, kind, object_id)
    else
        object_id);
}

fn includeReference(value: *p.Value, alloc: std.mem.Allocator, field: []const u8, kind: []const u8, object_id: []const u8) !void {
    if (output_id_format == .both)
        try value.object.put(field, p.str(try reference(alloc, kind, object_id)));
}

fn windowValue(alloc: std.mem.Allocator, win: *Window) !p.Value {
    var value = try p.object(alloc, .{
        .window_id = try identifier(alloc, "window", id(win)),
        .title = p.str(if (win.as(gtk.Window).getTitle()) |v| std.mem.span(v) else ""),
    });
    try includeReference(&value, alloc, "window_ref", "window", id(win));
    return value;
}

fn workspaceValue(alloc: std.mem.Allocator, win: *Window, tab: *Tab) !p.Value {
    const page = win.getTabView().getPage(tab.as(gtk.Widget));
    const remote = metadata(tab.as(gobject.Object)).remote;
    var value = try p.object(alloc, .{
        .workspace_id = try identifier(alloc, "workspace", id(tab)),
        .window_id = try identifier(alloc, "window", id(win)),
        .name = p.str(std.mem.span(page.getTitle())),
        .remote = p.boolean(remote != null),
        .host = if (remote) |r| p.str(r.host) else .null,
        .terminal_transport = if (remote) |r| p.str(r.terminal_transport) else .null,
        .terminal_profile = if (remote) |r| p.str(r.terminal_profile) else .null,
        .terminal_tmux_session = if (remote) |r| if (r.tmux_session) |session| p.str(session) else .null else .null,
    });
    try includeReference(&value, alloc, "workspace_ref", "workspace", id(tab));
    try includeReference(&value, alloc, "window_ref", "window", id(win));
    return value;
}

fn setRemoteDirectory(surface: *Surface, cwd: []const u8) !void {
    if (!std.fs.path.isAbsolute(cwd) or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidRemoteDirectory;
    const data = metadata(surface.as(gobject.Object));
    const copy = try a.dupeZ(u8, cwd);
    if (data.remote_directory) |old| a.free(old);
    data.remote_directory = copy;
    surface.setPwd(copy);
}

fn setLocalDirectory(surface: *Surface, cwd: ?[:0]const u8) !void {
    const value = cwd orelse return;
    const data = metadata(surface.as(gobject.Object));
    const copy = try a.dupeZ(u8, value);
    if (data.local_directory) |old| a.free(old);
    data.local_directory = copy;
}

fn terminalValue(alloc: std.mem.Allocator, win: *Window, tab: *Tab, surface: *Surface) !p.Value {
    const remote = metadata(tab.as(gobject.Object)).remote;
    const pane = tab.getSplitTree().paneObject(surface) orelse return error.TargetNotFound;
    var value = try p.object(alloc, .{
        .terminal_id = try identifier(alloc, "surface", id(surface)),
        .pane_id = try identifier(alloc, "pane", &metadata(pane).id),
        .surface_id = try identifier(alloc, "surface", id(surface)),
        .workspace_id = try identifier(alloc, "workspace", id(tab)),
        .window_id = try identifier(alloc, "window", id(win)),
        .title = p.str(surface.getEffectiveTitle() orelse ""),
        .directory = p.str(if (remote) |r|
            metadata(surface.as(gobject.Object)).remote_directory orelse r.cwd
        else
            surface.getPwd() orelse metadata(surface.as(gobject.Object)).local_directory orelse ""),
        .directory_kind = p.str(if (remote != null) "remote" else "local"),
        .type = p.str("terminal"),
        .ready = p.boolean(surface.core() != null),
    });
    try includeReference(&value, alloc, "surface_ref", "surface", id(surface));
    try includeReference(&value, alloc, "pane_ref", "pane", &metadata(pane).id);
    try includeReference(&value, alloc, "workspace_ref", "workspace", id(tab));
    try includeReference(&value, alloc, "window_ref", "window", id(win));
    const telemetry = try telemetryValue(alloc, metadata(surface.as(gobject.Object)));
    try value.object.put("git_branch", telemetry.object.get("git_branch").?);
    try value.object.put("git_dirty", telemetry.object.get("git_dirty").?);
    try value.object.put("pull_request", telemetry.object.get("pull_request").?);
    try value.object.put("listening_ports", telemetry.object.get("listening_ports").?);
    return value;
}
fn resolvedMetadataTarget(alloc: std.mem.Allocator, params: p.Value) !Target {
    if (params.object.contains("surface_id")) return target(alloc, params, "surface_id");
    if (params.object.contains("terminal_id")) return target(alloc, params, "terminal_id");
    if (params.object.contains("workspace_id")) return target(alloc, params, "workspace_id");
    if (params.object.contains("window_id")) {
        const win = (try target(alloc, params, "window_id")).window;
        const page = win.getTabView().getSelectedPage() orelse return error.TargetNotFound;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return error.TargetNotFound;
        return .{ .window = win, .tab = tab, .surface = tab.getActiveSurface() };
    }
    const win = try currentWindow(alloc);
    const page = win.getTabView().getSelectedPage() orelse return error.TargetNotFound;
    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return error.TargetNotFound;
    return .{ .window = win, .tab = tab, .surface = tab.getActiveSurface() };
}

fn targetMetadata(t: Target) *Metadata {
    return metadata(if (t.surface) |surface| surface.as(gobject.Object) else t.tab.?.as(gobject.Object));
}

fn notificationValue(alloc: std.mem.Allocator, item: *const NotificationRecord) !p.Value {
    var value = try p.object(alloc, .{
        .notification_id = p.str(&item.id),
        .window_id = try identifier(alloc, "window", &item.window_id),
        .workspace_id = try identifier(alloc, "workspace", &item.workspace_id),
        .surface_id = if (item.surface_id) |*surface_id|
            try identifier(alloc, "surface", surface_id)
        else
            .null,
        .title = p.str(item.title),
        .body = p.str(item.body),
        .subtitle = p.str(item.subtitle),
        .level = p.str(item.level),
        .tab_title = p.str(item.tab_title),
        .category = p.str(item.category),
        .created_at = p.integer(item.created_at),
        .read = p.boolean(item.read),
    });
    try includeReference(&value, alloc, "window_ref", "window", &item.window_id);
    try includeReference(&value, alloc, "workspace_ref", "workspace", &item.workspace_id);
    if (item.surface_id) |*surface_id|
        try includeReference(&value, alloc, "surface_ref", "surface", surface_id);
    return value;
}

fn boolParam(params: p.Value, name: []const u8, fallback: bool) !bool {
    const value = params.object.get(name) orelse return fallback;
    if (value != .bool) return error.InvalidParams;
    return value.bool;
}
fn jsonValueParam(alloc: std.mem.Allocator, params: p.Value, name: []const u8) !p.Value {
    return std.json.parseFromSliceLeaky(
        p.Value,
        alloc,
        try p.string(params, name),
        .{ .allocate = .alloc_always },
    );
}

fn notificationMatches(alloc: std.mem.Allocator, item: *const NotificationRecord, params: p.Value) !bool {
    if (try p.optionalString(params, "window_id")) |value|
        if (!eq(u8, &item.window_id, id((try find(alloc, "window_id", value)).window))) return false;
    if (try p.optionalString(params, "workspace_id")) |value|
        if (!eq(u8, &item.workspace_id, id((try find(alloc, "workspace_id", value)).tab.?))) return false;
    const surface_filter = (try p.optionalString(params, "surface_id")) orelse
        (try p.optionalString(params, "terminal_id"));
    if (surface_filter) |value| {
        const item_surface = item.surface_id orelse return false;
        if (!eq(u8, &item_surface, id((try find(alloc, "surface_id", value)).surface.?))) return false;
    }
    if (try boolParam(params, "unread", false)) if (item.read) return false;
    return true;
}

fn appendNotification(alloc: std.mem.Allocator, t: Target, params: p.Value) !p.Value {
    const title = try p.string(params, "title");
    const subtitle = (try p.optionalString(params, "subtitle")) orelse "";
    const body = (try p.optionalString(params, "body")) orelse "";
    const level = (try p.optionalString(params, "level")) orelse "info";
    if (!inWords("info warning error", level)) return error.InvalidNotificationLevel;
    if (title.len > 2048 or subtitle.len > 2048 or body.len > 8192) return error.NotificationTooLarge;
    if (!std.unicode.utf8ValidateSlice(title) or !std.unicode.utf8ValidateSlice(subtitle) or !std.unicode.utf8ValidateSlice(body))
        return error.InvalidUTF8;
    // cmux `recordNotification`: a new event on the same workspace+surface
    // replaces the previous one so the row never stacks stale turn-end text.
    var duplicate = false;
    {
        var index = notifications.items.len;
        while (index > 0) {
            index -= 1;
            const existing = notifications.items[index];
            if (!eq(u8, &existing.workspace_id, id(t.tab.?))) continue;
            const same_surface = switch (t.surface != null) {
                true => existing.surface_id != null and eq(u8, &existing.surface_id.?, id(t.surface.?)),
                false => existing.surface_id == null,
            };
            if (!same_surface) continue;
            if (eq(u8, existing.title, title) and eq(u8, existing.subtitle, subtitle) and eq(u8, existing.body, body))
                duplicate = true;
            notifications.orderedRemove(index).deinit();
        }
    }

    if (notifications.items.len == 512) {
        const removed = notifications.orderedRemove(0);
        removed.deinit();
    }
    const page = t.window.getTabView().getPage(t.tab.?.as(gtk.Widget));
    const focused = notificationTargetIsFocused(t);
    const category = notify_policy.classify(title, subtitle, body, try p.optionalString(params, "category"));
    const agent_kind = (try p.optionalString(params, "agent")) orelse try p.optionalString(params, "kind");
    const subagent = notify_policy.isSubagent(title, subtitle, body, try boolParam(params, "is_subagent", false));
    const decision = notify_policy.decide(alloc, .{
        .workspace_id = id(t.tab.?),
        .surface_id = if (t.surface) |surface| id(surface) else null,
        .title = title,
        .subtitle = subtitle,
        .body = body,
        .cwd = if (t.surface) |surface| localDirectory(surface) else null,
        .app_focused = t.window.as(gtk.Window).isActive() != 0,
        .agent_kind = agent_kind,
        .category = category,
        .is_subagent = subagent,
        .pending = try boolParam(params, "pending", false),
    });
    if (decision.drop or !decision.effects.record)
        return try p.object(alloc, .{ .suppressed = p.boolean(true) });
    var transferred = false;
    const title_copy = try a.dupe(u8, title);
    errdefer if (!transferred) a.free(title_copy);
    const subtitle_copy = try a.dupe(u8, subtitle);
    errdefer if (!transferred) a.free(subtitle_copy);
    const body_copy = try a.dupe(u8, body);
    errdefer if (!transferred) a.free(body_copy);
    const level_copy = try a.dupe(u8, level);
    errdefer if (!transferred) a.free(level_copy);
    const tab_title_copy = try a.dupe(u8, std.mem.span(page.getTitle()));
    errdefer if (!transferred) a.free(tab_title_copy);
    const category_copy = try a.dupe(u8, @tagName(category));
    errdefer if (!transferred) a.free(category_copy);
    const record: NotificationRecord = .{
        .id = randomId(),
        .window_id = id(t.window)[0..32].*,
        .workspace_id = id(t.tab.?)[0..32].*,
        .surface_id = if (t.surface) |surface| id(surface)[0..32].* else null,
        .title = title_copy,
        .body = body_copy,
        .subtitle = subtitle_copy,
        .level = level_copy,
        .tab_title = tab_title_copy,
        .category = category_copy,
        .created_at = std.time.milliTimestamp(),
        .read = focused or !decision.effects.mark_unread,
    };
    try notifications.append(a, record);
    transferred = true;
    if (!duplicate) {
        const surface = t.surface orelse t.tab.?.getActiveSurface() orelse return error.TargetNotFound;
        const muted = metadata(t.tab.?.as(gobject.Object)).muted;
        if (!muted and decision.effects.desktop) {
            const desktop_body = if (subtitle.len > 0 and body.len > 0)
                try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ subtitle, body })
            else if (subtitle.len > 0)
                subtitle
            else
                body;
            surface.sendDesktopNotification(try alloc.dupeZ(u8, title), try alloc.dupeZ(u8, desktop_body));
            t.window.addToast(try alloc.dupeZ(u8, if (body.len > 0) body else if (subtitle.len > 0) subtitle else title));
        }
        if (decision.effects.pane_flash) flashPane(surface);
        if (decision.effects.reorder_workspace and decision.effects.mark_unread) floatUnreadWorkspace(t.tab.?);
    }

    if (looksLikeNeedsInput(title, subtitle, body)) setNeedsInputStatus(t);
    refreshActivities();
    notify_policy.runAutomations(alloc, "notification", title, body);
    return notificationValue(alloc, &notifications.items[notifications.items.len - 1]);
}

fn notificationTargetIsFocused(t: Target) bool {
    if (t.window.as(gtk.Window).isActive() == 0) return false;
    const page = t.window.getTabView().getSelectedPage() orelse return false;
    const selected = gobject.ext.cast(Tab, page.getChild()) orelse return false;
    if (selected != t.tab.?) return false;
    if (t.surface) |surface| {
        const active = selected.getActiveSurface() orelse return false;
        return surface == active;
    }
    return true;
}

fn looksLikeNeedsInput(title: []const u8, subtitle: []const u8, body: []const u8) bool {
    return containsInsensitive(title, "needs input") or
        containsInsensitive(subtitle, "needs input") or
        containsInsensitive(body, "needs input") or
        containsInsensitive(title, "needs your") or
        containsInsensitive(body, "needs your") or
        containsInsensitive(subtitle, "waiting") or
        containsInsensitive(body, "permission");
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

fn setNeedsInputStatus(t: Target) void {
    const data = targetMetadata(t);
    const key_copy = a.dupe(u8, "agent") catch return;
    const text_copy = a.dupe(u8, "Needs input") catch {
        a.free(key_copy);
        return;
    };
    const icon_copy = a.dupe(u8, "bell.fill") catch {
        a.free(key_copy);
        a.free(text_copy);
        return;
    };
    const color_copy = a.dupe(u8, "#4C8DFF") catch {
        a.free(key_copy);
        a.free(text_copy);
        a.free(icon_copy);
        return;
    };
    const entry: StatusEntry = .{
        .key = key_copy,
        .text = text_copy,
        .icon = icon_copy,
        .color = color_copy,
        .updated_at = std.time.milliTimestamp(),
    };
    for (data.statuses.items, 0..) |existing, index| {
        if (!eq(u8, existing.key, entry.key)) continue;
        data.statuses.items[index].deinit();
        data.statuses.items[index] = entry;
        return;
    }
    if (data.statuses.items.len == 32) data.statuses.orderedRemove(0).deinit();
    data.statuses.append(a, entry) catch entry.deinit();
}

fn flashPane(surface: *Surface) void {
    const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return;
    const pane = tab.getSplitTree().paneObject(surface) orelse return;
    const widget = gobject.ext.cast(gtk.Widget, pane) orelse return;
    widget.removeCssClass("pane-flash");
    widget.addCssClass("pane-flash");
}

fn floatUnreadWorkspace(tab: *Tab) void {
    const win = ext.getAncestor(Window, tab.as(gtk.Widget)) orelse return;
    const view = win.getTabView();
    const page = view.getPage(tab.as(gtk.Widget));
    const current = view.getPagePosition(page);
    var dest: c_int = 0;
    while (dest < view.getNPages()) : (dest += 1) {
        const child = view.getNthPage(dest).getChild();
        const other = gobject.ext.cast(Tab, child) orelse continue;
        if (!metadata(other.as(gobject.Object)).pinned) break;
    }
    if (current == dest) return;
    _ = view.reorderPage(page, dest);
}

pub fn feedCards() []const FeedRecord {
    return feed_items.items;
}

fn feedList(alloc: std.mem.Allocator) !p.Value {
    var result: std.array_list.Managed(p.Value) = .init(alloc);
    for (feed_items.items) |*item| try result.append(try feedValue(alloc, item));
    return .{ .array = result };
}

fn feedValue(alloc: std.mem.Allocator, item: *const FeedRecord) !p.Value {
    return p.object(alloc, .{
        .id = p.str(&item.id),
        .kind = p.str(item.kind),
        .workspace_id = p.str(&item.workspace_id),
        .terminal_id = if (item.surface_id) |value| p.str(&value) else .null,
        .request_id = p.str(item.request_id),
        .title = p.str(item.title),
        .body = p.str(item.body),
        .tool = p.str(item.tool),
        .status = p.str(item.status),
        .created_at = p.integer(item.created_at),
        .parked_until = p.integer(item.parked_until),
        .parked = p.boolean(std.time.milliTimestamp() < item.parked_until),
    });
}

fn feedPush(alloc: std.mem.Allocator, params: p.Value) !p.Value {
    const kind = try p.string(params, "kind");
    if (!inWords("permission exit_plan question automation", kind)) return error.InvalidFeedKind;
    const t = try resolvedMetadataTarget(alloc, params);
    const now = std.time.milliTimestamp();
    const generated_request = randomId();
    const request_id = (try p.optionalString(params, "request_id")) orelse generated_request[0..];
    if (request_id.len == 0 or request_id.len > 128) return error.InvalidRequestId;
    var index = feed_items.items.len;
    while (index > 0) {
        index -= 1;
        if (!eq(u8, feed_items.items[index].request_id, request_id)) continue;
        feed_items.orderedRemove(index).deinit();
    }
    if (feed_items.items.len == 256) feed_items.orderedRemove(0).deinit();
    const title = (try p.optionalString(params, "title")) orelse kind;
    const body = (try p.optionalString(params, "body")) orelse "";
    const tool = (try p.optionalString(params, "tool")) orelse "";
    if (title.len > 2048 or body.len > 8192 or tool.len > 256) return error.FeedTooLarge;
    var transferred = false;
    const kind_copy = try a.dupe(u8, kind);
    errdefer if (!transferred) a.free(kind_copy);
    const request_copy = try a.dupe(u8, request_id);
    errdefer if (!transferred) a.free(request_copy);
    const title_copy = try a.dupe(u8, title);
    errdefer if (!transferred) a.free(title_copy);
    const body_copy = try a.dupe(u8, body);
    errdefer if (!transferred) a.free(body_copy);
    const tool_copy = try a.dupe(u8, tool);
    errdefer if (!transferred) a.free(tool_copy);

    const status_copy = try a.dupe(u8, "pending");
    errdefer if (!transferred) a.free(status_copy);
    try feed_items.append(a, .{
        .id = randomId(),
        .kind = kind_copy,
        .workspace_id = id(t.tab.?)[0..32].*,
        .surface_id = if (t.surface) |surface| id(surface)[0..32].* else null,
        .request_id = request_copy,
        .title = title_copy,
        .body = body_copy,
        .tool = tool_copy,
        .status = status_copy,
        .created_at = now,
        .parked_until = now + 120_000,
    });
    transferred = true;
    const item = &feed_items.items[feed_items.items.len - 1];
    appendWorkstream("push", item);
    const notify = p.object(alloc, .{
        .title = p.str(title),
        .subtitle = p.str(kind),
        .body = p.str(if (body.len > 0) body else "Needs input"),
        .level = p.str("warning"),
    }) catch p.object(alloc, .{ .title = p.str(title) }) catch return feedValue(alloc, item);
    _ = appendNotification(alloc, t, notify) catch {};
    sendFeedDesktopNotification(item);
    t.window.setRightSidebarMode(.feed, false);

    refreshActivities();
    return feedValue(alloc, item);
}

fn feedReply(alloc: std.mem.Allocator, params: p.Value) !p.Value {
    const card_id = try p.string(params, "id");
    const verb = try p.string(params, "verb");
    if (!inWords("once always all_tools bypass deny ultraplan manual auto answer", verb)) return error.InvalidFeedVerb;
    const item = findFeed(card_id) orelse return error.TargetNotFound;
    a.free(item.status);
    item.status = try a.dupe(u8, verb);
    appendWorkstream("reply", item);
    focusFeedWorkspace(item);
    refreshActivities();
    return feedValue(alloc, item);
}

fn sendFeedDesktopNotification(item: *const FeedRecord) void {
    const title = a.dupeZ(u8, item.title) catch return;
    defer a.free(title);
    const body_src = if (item.body.len > 0) item.body else item.kind;
    const body = a.dupeZ(u8, body_src) catch return;
    defer a.free(body);
    const notification = gio.Notification.new(title);
    defer notification.unref();
    notification.setBody(body);
    const verbs: []const struct { verb: [:0]const u8, label: [:0]const u8 } = if (eq(u8, item.kind, "permission"))
        &.{
            .{ .verb = "once", .label = "Once" },
            .{ .verb = "always", .label = "Always" },
            .{ .verb = "deny", .label = "Deny" },
        }
    else if (eq(u8, item.kind, "exit_plan"))
        &.{
            .{ .verb = "ultraplan", .label = "Ultraplan" },
            .{ .verb = "manual", .label = "Manual" },
            .{ .verb = "auto", .label = "Auto" },
        }
    else if (eq(u8, item.kind, "question"))
        &.{.{ .verb = "answer", .label = "Answer" }}
    else
        &.{};
    for (verbs) |entry| {
        var detailed: [80]u8 = undefined;
        const action = std.fmt.bufPrintZ(&detailed, "app.feed-reply::{s}:{s}", .{ &item.id, entry.verb }) catch continue;
        notification.addButton(entry.label, action);
    }
    var id_z: [33]u8 = undefined;
    @memcpy(id_z[0..32], &item.id);
    id_z[32] = 0;
    Application.default().as(gio.Application).sendNotification(@ptrCast(&id_z), notification);
}

fn feedTui(alloc: std.mem.Allocator, params: p.Value) !p.Value {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try text.appendSlice(alloc, "Feed\n");
    for (feed_items.items) |item| {
        const line = try std.fmt.allocPrint(alloc, "{s}\t{s}\t{s}\t{s}\n", .{ item.kind, item.status, item.title, item.request_id });
        defer alloc.free(line);
        try text.appendSlice(alloc, line);
    }
    const dump = try alloc.dupe(u8, text.items);
    const dock = try boolParam(params, "dock", true);
    if (dock) {
        const t = try resolvedMetadataTarget(alloc, params);
        t.window.setRightSidebarMode(.dock, true);
        const xdg = @import("../../os/xdg.zig");
        const dir_path = try xdg.state(alloc, .{ .subdir = "colm" });
        defer alloc.free(dir_path);
        try std.fs.cwd().makePath(dir_path);
        const path = try std.fs.path.join(alloc, &.{ dir_path, "feed-tui.txt" });
        defer alloc.free(path);
        var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(dump);
        try t.tab.?.getSplitTree().newSplit(.right, null, .{});
        const created = t.tab.?.getActiveSurface() orelse return error.TargetNotFound;
        const command = try std.fmt.allocPrint(alloc, "less {s}\n", .{path});
        try PendingInput.start(created, command);
    }
    return p.object(alloc, .{
        .text = p.str(dump),
        .count = p.integer(@as(i64, @intCast(feed_items.items.len))),
        .dock = p.boolean(dock),
    });
}

pub fn replyFeed(card_id: []const u8, verb: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const params = p.object(arena.allocator(), .{
        .id = p.str(card_id),
        .verb = p.str(verb),
    }) catch return;
    _ = feedReply(arena.allocator(), params) catch {};
}

fn findFeed(card_id: []const u8) ?*FeedRecord {
    for (feed_items.items) |*item| if (eq(u8, &item.id, card_id)) return item;
    return null;
}

fn focusFeedWorkspace(item: *const FeedRecord) void {
    const t = find(a, "workspace_id", &item.workspace_id) catch return;
    const page = t.window.getTabView().getPage(t.tab.?.as(gtk.Widget));
    t.window.getTabView().setSelectedPage(page);
    t.window.setRightSidebarMode(.feed, true);
}

fn appendWorkstream(event: []const u8, item: *const FeedRecord) void {
    const xdg = @import("../../os/xdg.zig");
    const dir_path = xdg.state(a, .{ .subdir = "colm" }) catch return;
    defer a.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch return;
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
    defer dir.close();
    var file = dir.openFile("workstream.jsonl", .{ .mode = .read_write }) catch dir.createFile("workstream.jsonl", .{ .mode = 0o600 }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    const payload = p.object(a, .{
        .event = p.str(event),
        .id = p.str(&item.id),
        .kind = p.str(item.kind),
        .status = p.str(item.status),
        .request_id = p.str(item.request_id),
        .title = p.str(item.title),
        .created_at = p.integer(item.created_at),
    }) catch return;
    const encoded = std.json.Stringify.valueAlloc(a, payload, .{}) catch return;
    defer a.free(encoded);
    file.writeAll(encoded) catch {};
    file.writeAll("\n") catch {};
}

pub fn recordOscNotification(surface: *Surface, title: []const u8, body: []const u8) void {
    const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return;
    const win = ext.getAncestor(Window, surface.as(gtk.Widget)) orelse return;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const params = p.object(alloc, .{
        .title = p.str(title),
        .body = p.str(body),
    }) catch return;
    _ = appendNotification(alloc, .{ .window = win, .tab = tab, .surface = surface }, params) catch {};
}

pub fn observeProcessTitle(surface: *Surface, title: []const u8) void {
    const data = metadata(surface.as(gobject.Object));
    const previous = data.process_title orelse "";
    if (titleIsSpinnerFrame(previous, title)) {
        data.prompt_turn_busy = true;
        return;
    }
    const agent = agentNameIn(title) orelse agentNameIn(previous);
    const busy = titleLooksBusy(title);
    const was_busy = data.prompt_turn_busy;
    const left_real_busy = titleLooksBusy(previous);
    if (data.process_title) |value| a.free(value);
    data.process_title = a.dupe(u8, title) catch null;
    data.prompt_turn_busy = busy;
    if (was_busy and !busy and left_real_busy) {
        if (agent) |name| recordPromptTurn(surface, name);
    }
    scanAgentArgv(surface);
}

fn scanAgentArgv(surface: *Surface) void {
    const data = metadata(surface.as(gobject.Object));
    const now = std.time.milliTimestamp();
    if (now - data.agent_scan_at < 2000) return;
    data.agent_scan_at = now;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const detected = agent_store.detectForTerminal(arena.allocator(), id(surface)) catch return;
    const found = detected orelse return;
    if (found.session_id) |session_id| {
        const tab = ext.getAncestor(Tab, surface.as(gtk.Widget));
        agent_store.captureSession(arena.allocator(), .{
            .provider = if (found.provider.len > 0) found.provider else "agent",
            .session_id = session_id,
            .workspace_id = if (tab) |value| id(value) else "",
            .surface_id = id(surface),
            .cwd = localDirectory(surface),
        }) catch {};
    }
    if (found.tmux_session) |session| {
        if (data.tmux_session) |old| a.free(old);
        data.tmux_session = a.dupe(u8, session) catch null;
    }
}

fn titleIsSpinnerFrame(previous: []const u8, next: []const u8) bool {
    if (eq(u8, previous, next)) return false;
    var prev_buf: [256]u8 = undefined;
    var next_buf: [256]u8 = undefined;
    const stripped_prev = stripSpinner(previous, &prev_buf);
    const stripped_next = stripSpinner(next, &next_buf);
    return stripped_prev.len > 0 and eq(u8, stripped_prev, stripped_next);
}

fn stripSpinner(title: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    const view = std.unicode.Utf8View.init(title) catch return title;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (isSpinnerCodepoint(cp)) continue;
        const encoded_len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
        if (len + encoded_len > buf.len) break;
        _ = std.unicode.utf8Encode(cp, buf[len..]) catch break;
        len += encoded_len;
    }
    return std.mem.trim(u8, buf[0..len], " \t");
}

fn isSpinnerCodepoint(cp: u21) bool {
    return switch (cp) {
        0x2800...0x28FF => true,
        0x25D0...0x25D3 => true,
        0x25F4...0x25F7 => true,
        0x2022, 0x2219, 0x00B7, 0x2024 => true,
        else => false,
    };
}

fn titleLooksBusy(title: []const u8) bool {
    return containsInsensitive(title, "working") or
        containsInsensitive(title, "thinking") or
        containsInsensitive(title, "running") or
        containsInsensitive(title, "generating") or
        containsInsensitive(title, "coding");
}

fn agentNameIn(title: []const u8) ?[]const u8 {
    const names = [_][]const u8{
        "claude",  "codex", "grok", "opencode", "omp",   "cursor", "gemini",
        "copilot", "kimi",  "pi",   "campfire", "droid", "qoder",  "amp",
        "rovo",    "omo",   "omx",  "omc",
    };
    for (names) |name| if (containsInsensitive(title, name)) return name;
    return null;
}

fn recordPromptTurn(surface: *Surface, agent: []const u8) void {
    const data = metadata(surface.as(gobject.Object));
    const now = std.time.milliTimestamp();
    if (data.prompt_turn_at != 0 and now - data.prompt_turn_at < 30_000) return;
    data.prompt_turn_at = now;
    const tab = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse return;
    const win = ext.getAncestor(Window, surface.as(gtk.Widget)) orelse return;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const params = p.object(alloc, .{
        .title = p.str(agent),
        .subtitle = p.str("Completed"),
        .body = p.str("Task completed"),
        .category = p.str("turn-complete"),
    }) catch return;

    _ = appendNotification(alloc, .{ .window = win, .tab = tab, .surface = surface }, params) catch {};
}

fn statusValue(alloc: std.mem.Allocator, entry: *const StatusEntry) !p.Value {
    return p.object(alloc, .{
        .key = p.str(entry.key),
        .text = p.str(entry.text),
        .icon = if (entry.icon) |value| p.str(value) else .null,
        .color = if (entry.color) |value| p.str(value) else .null,
        .updated_at = p.integer(entry.updated_at),
    });
}

fn logValue(alloc: std.mem.Allocator, entry: *const LogEntry) !p.Value {
    return p.object(alloc, .{
        .log_id = p.str(&entry.id),
        .text = p.str(entry.text),
        .level = p.str(entry.level),
        .created_at = p.integer(entry.created_at),
    });
}

fn telemetryValue(alloc: std.mem.Allocator, data: *Metadata) !p.Value {
    var ports: std.array_list.Managed(p.Value) = .init(alloc);
    for (data.listening_ports.items) |port| try ports.append(p.integer(port));
    return p.object(alloc, .{
        .git_branch = if (data.git_branch) |value| p.str(value) else .null,
        .git_dirty = p.boolean(data.git_dirty),
        .pull_request = if (data.pull_request) |entry| try p.object(alloc, .{
            .number = p.integer(entry.number),
            .label = p.str(entry.label),
            .url = p.str(entry.url),
            .status = p.str(entry.status),
            .branch = if (entry.branch) |value| p.str(value) else .null,
        }) else .null,
        .listening_ports = p.Value{ .array = ports },
    });
}

fn inWords(words: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, words, ' ');
    while (it.next()) |item| if (eq(u8, item, word)) return true;
    return false;
}

fn currentWindow(alloc: std.mem.Allocator) !*Window {
    const values = try windows(alloc);
    if (values.len == 0) return error.TargetNotFound;
    for (values) |win| if (win.as(gtk.Window).isActive() != 0) return win;
    return values[0];
}

fn capabilitiesValue(alloc: std.mem.Allocator) !p.Value {
    var methods: std.array_list.Managed(p.Value) = .init(alloc);
    for ([_][]const u8{
        "system.ping",               "system.capabilities",             "system.identify",           "system.tree",
        "session.save",              "session.restore",                 "app.reexec",                "window.list",
        "window.current",            "window.create",                   "window.focus",              "window.rename",
        "window.close",              "workspace.list",                  "workspace.current",         "workspace.create",
        "workspace.focus",           "workspace.rename",                "workspace.move",            "workspace.reorder",
        "workspace.close",           "workspace.pin",                   "workspace.unpin",           "workspace.mute",
        "workspace.unmute",          "workspace.task-status",           "pane.list",                 "pane.create",
        "pane.focus",                "pane.close",                      "surface.list",              "surface.create",
        "surface.split",             "surface.focus",                   "surface.close",             "surface.move",
        "surface.refresh",           "surface.health",                  "surface.report_git_branch", "surface.clear_git_branch",
        "surface.report_pr",         "surface.clear_pr",                "surface.report_ports",      "surface.clear_ports",
        "surface.resume.set",        "surface.resume.show",             "surface.resume.clear",      "notification.create",
        "notification.list",         "notification.dismiss",            "notification.mark-read",    "notification.open",
        "notification.jump-unread",  "notification.mark-oldest-unread", "notification.clear",        "status.get",
        "status.set",                "status.clear",                    "status.list",               "progress.set",
        "progress.clear",            "canvas.set",                      "canvas.delete",             "canvas.open",
        "computer-use.open",         "simulator.list",                  "simulator.open",            "simulator.register",
        "simulator.status",          "simulator.stream",                "simulator.touch",           "simulator.delete",
        "policy.list",               "prompt.set",                      "prompt.delete",             "prompt.run",
        "rule.list",                 "rule.get",                        "rule.set",                  "rule.delete",
        "rule.run",                  "agent.hook",                      "agent.launch",              "agent.detect",
        "agent.fork",                "agent.hooks",                     "agent.hooks-install",       "agent.hooks-uninstall",
        "agent.session-capture",     "agent.sessions",                  "agent.tmux-shim-install",   "agent.tmux-shim-uninstall",
        "deep-link.open",            "settings.get",                    "settings.set",              "theme.list",
        "theme.apply",               "shortcut.list",                   "update.status",             "update.apply",
        "diagnostics.collect",       "platform.status",                 "group.list",                "group.get",
        "group.set",                 "group.delete",                    "group.assign",              "todo.list",
        "todo.get",                  "todo.set",                        "todo.delete",               "lane.list",
        "lane.get",                  "lane.set",                        "lane.delete",               "action.list",
        "action.get",                "action.set",                      "action.delete",             "action.run",
        "layout.list",               "layout.get",                      "layout.set",                "layout.delete",
        "layout.apply",              "trust.preview",                   "trust.status",              "trust.grant",
        "trust.revoke",              "dock.list",                       "dock.set",                  "dock.delete",
        "dock.open",                 "feed.list",                       "feed.set",                  "feed.delete",
        "feed.open",                 "feed.push",                       "feed.reply",                "feed.tui",
        "custom-sidebar.list",       "custom-sidebar.set",              "custom-sidebar.delete",     "custom-sidebar.open",
        "viewer.open",               "viewer.save",                     "viewer.refresh",            "viewer.list",
        "viewer.delete",             "vault.list",                      "vault.get",                 "vault.capture",
        "vault.search",              "vault.checkpoint",                "vault.fork",                "vault.delete",
        "task.list",                 "task.register",                   "task.status",               "task.tree",
        "task.unregister",           "task.terminate",                  "headless.list",             "headless.save",
        "headless.attach",           "headless.detach",                 "headless.delete",           "headless.tui",
        "machine.list",              "machine.register",                "machine.status",            "machine.start",
        "machine.stop",              "machine.route",                   "machine.delete",            "publication.list",
        "publication.publish",       "publication.get",                 "publication.delete",        "device.list",
        "device.pair",               "device.status",                   "device.sync",               "device.notify",
        "device.reply",              "device.compose",                  "device.revoke",             "event.list",
        "event.emit",                "event.clear",                     "automation-rule.list",      "automation-rule.get",
        "automation-rule.set",       "automation-rule.delete",          "agent-control.list",        "agent-control.register",
        "agent-control.status",      "agent-control.check",             "agent-control.hibernate",   "agent-control.resume",
        "agent-control.delete",      "canvas.list",                     "canvas.get",                "canvas.set",
        "canvas.delete",             "canvas.open",                     "simulator.list",            "simulator.register",
        "simulator.status",          "simulator.stream",                "simulator.touch",           "simulator.delete",
        "policy.list",               "policy.get",                      "policy.set",                "policy.delete",
        "policy.effective",          "locale.list",                     "locale.status",             "locale.set",
        "ssh.create",                "ssh.status",                      "ssh.disconnect",            "ssh.reconnect",
        "ssh.session-list",          "ssh.session-attach",              "ssh.session-cleanup",       "ssh.upload",
        "ssh.download",              "browser.create",                  "browser.list",              "browser.close",
        "browser.focus",             "browser.status",                  "browser.navigate",          "browser.back",
        "browser.forward",           "browser.reload",                  "browser.stop",              "browser.screenshot",
        "browser.download",          "browser.upload",                  "browser.permissions",       "browser.permission",
        "browser.devtools",          "browser.state-export",            "browser.state-import",      "browser.frames",
        "browser.logs",              "browser.logs-clear",              "browser.dialog-policy",     "browser.viewport",
        "browser.network",           "browser.script",                  "browser.style",             "browser.annotate",
        "browser.annotations-clear", "browser.click",                   "browser.fill",              "browser.get",
        "browser.find",              "browser.wait",                    "browser.select",            "browser.press",
        "browser.evaluate",
    }) |method| try methods.append(p.str(method));
    var formats: std.array_list.Managed(p.Value) = .init(alloc);
    inline for (.{ "refs", "uuids", "both" }) |format| try formats.append(p.str(format));
    return p.object(alloc, .{
        .protocol_version = p.integer(2),
        .transport = p.str("unix"),
        .authentication = p.str("peer-credentials"),
        .request_limit_bytes = p.integer(1024 * 1024),
        .response_limit_bytes = p.integer(16 * 1024 * 1024),
        .id_formats = p.Value{ .array = formats },
        .methods = p.Value{ .array = methods },
    });
}

fn splitDirection(params: p.Value) !Surface.Tree.Split.Direction {
    const value = (try p.optionalString(params, "direction")) orelse "right";
    return std.meta.stringToEnum(Surface.Tree.Split.Direction, value) orelse error.InvalidDirection;
}
fn optionalIndex(params: p.Value, fallback: c_int, maximum: c_int) !c_int {
    const value = params.object.get("index") orelse return fallback;
    if (value != .integer or value.integer < 0 or value.integer > maximum) return error.InvalidIndex;
    return @intCast(value.integer);
}
fn treeValue(alloc: std.mem.Allocator, params: p.Value) !p.Value {
    var window_values: std.array_list.Managed(p.Value) = .init(alloc);
    for (try windows(alloc)) |win| {
        if (try p.optionalString(params, "window_id")) |filter| {
            if ((try find(alloc, "window_id", filter)).window != win) continue;
        }
        var workspace_values: std.array_list.Managed(p.Value) = .init(alloc);
        const view = win.getTabView();
        var workspace_index: c_int = 0;
        while (workspace_index < view.getNPages()) : (workspace_index += 1) {
            const tab = gobject.ext.cast(Tab, view.getNthPage(workspace_index).getChild()) orelse continue;
            if (try p.optionalString(params, "workspace_id")) |filter| {
                if ((try find(alloc, "workspace_id", filter)).tab != tab) continue;
            }
            var pane_values: std.array_list.Managed(p.Value) = .init(alloc);
            const split_tree = tab.getSplitTree();
            var surface_index: usize = 0;
            while (surface_index < split_tree.surfaceCount()) {
                const first = split_tree.surfaceAt(surface_index).?;
                const pane_object = split_tree.paneObject(first).?;
                const active = split_tree.paneActiveSurface(first) orelse first;
                var pane = try terminalValue(alloc, win, tab, active);
                var surfaces: std.array_list.Managed(p.Value) = .init(alloc);
                while (surface_index < split_tree.surfaceCount()) : (surface_index += 1) {
                    const surface = split_tree.surfaceAt(surface_index).?;
                    if (split_tree.paneObject(surface).? != pane_object) break;
                    try surfaces.append(try terminalValue(alloc, win, tab, surface));
                }
                try pane.object.put("surfaces", .{ .array = surfaces });
                try pane_values.append(pane);
            }
            var workspace = try workspaceValue(alloc, win, tab);
            try workspace.object.put("index", p.integer(workspace_index));
            try workspace.object.put("panes", .{ .array = pane_values });
            try workspace_values.append(workspace);
        }
        var window = try windowValue(alloc, win);
        try window.object.put("workspaces", .{ .array = workspace_values });
        try window_values.append(window);
    }
    return p.object(alloc, .{ .windows = p.Value{ .array = window_values } });
}
fn requiredForce(params: p.Value) !void {
    const force = params.object.get("force") orelse return error.ConfirmationRequired;
    if (force != .bool or !force.bool) return error.ConfirmationRequired;
}
fn focus(t: Target) void {
    if (t.tab) |tab| {
        t.window.getTabView().setSelectedPage(t.window.getTabView().getPage(tab.as(gtk.Widget)));
        if (t.surface) |surface| tab.getSplitTree().automationFocus(surface) catch {};
    }
    t.window.as(gtk.Window).present();
    t.window.refreshActivity();
}
const PendingInput = struct {
    surface: *Surface,
    text: []u8,
    attempts: u16 = 0,

    fn start(surface: *Surface, value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUTF8;
        const self = try a.create(PendingInput);
        errdefer a.destroy(self);
        const text = try a.alloc(u8, value.len + 1);
        errdefer a.free(text);
        @memcpy(text[0..value.len], value);
        text[value.len] = '\r';
        self.* = .{ .surface = surface.ref(), .text = text };
        _ = glib.timeoutAdd(25, poll, self);
    }

    fn finish(self: *PendingInput) void {
        self.surface.unref();
        a.free(self.text);
        a.destroy(self);
    }

    fn poll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *PendingInput = @ptrCast(@alignCast(data.?));
        if (self.surface.core()) |core| {
            core.textCallback(self.text) catch |err|
                std.log.err("initial terminal input failed: {s}", .{@errorName(err)});
            self.finish();
            return 0;
        }
        self.attempts += 1;
        if (self.attempts < 400) return 1;
        std.log.err("initial terminal input timed out", .{});
        self.finish();
        return 0;
    }
};

fn scheduleInitialInput(surface: *Surface, params: p.Value) !void {
    if (try p.optionalString(params, "command")) |value| try PendingInput.start(surface, value);
}

fn directory(alloc: std.mem.Allocator, params: p.Value) !?[:0]const u8 {
    const value = try p.optionalString(params, "cwd") orelse return null;
    if (!std.fs.path.isAbsolute(value)) return error.AbsoluteDirectoryRequired;
    return try alloc.dupeZ(u8, value);
}
pub fn dispatch(alloc: std.mem.Allocator, request: p.Value, ctx: *anyopaque, callback: p.Callback) void {
    const result = dispatchAsync(alloc, request, ctx, callback) catch |err| {
        callback(ctx, .{ .err = @errorName(err) });
        return;
    };
    if (result == null) return;
    callback(ctx, .{ .ok = result.? });
}
fn handle(alloc: std.mem.Allocator, request: p.Value) !p.Value {
    const method = try p.string(request, "method");
    const params = request.object.get("params") orelse return error.MissingParameter;
    if (params != .object) return error.InvalidParams;
    try authorize(alloc, request, method, params);
    const requested_format = (try p.optionalString(request, "id_format")) orelse "refs";
    const selected_format = std.meta.stringToEnum(IdFormat, requested_format) orelse return error.InvalidIdFormat;
    const previous_format = output_id_format;
    output_id_format = selected_format;
    defer output_id_format = previous_format;
    if (eq(u8, method, "system.ping")) {
        return p.object(alloc, .{
            .pong = p.boolean(true),
            .protocol_version = p.integer(2),
            .unix_ms = p.integer(std.time.milliTimestamp()),
        });
    }
    if (eq(u8, method, "system.capabilities")) return capabilitiesValue(alloc);
    if (eq(u8, method, "system.identify")) {
        const socket_path = try @import("control.zig").socketPath(alloc);
        return p.object(alloc, .{
            .application = p.str("Colm"),
            .version = p.str(build_config.version_string),
            .pid = p.integer(std.os.linux.getpid()),
            .socket_path = p.str(socket_path),
            .protocol_version = p.integer(2),
        });
    }
    if (eq(u8, method, "deep-link.open")) {
        const uri = try p.string(params, "uri");
        const parsed = try deep_link.parse(alloc, uri);
        const token = deep_link.confirmationToken(uri);
        const supplied = try p.optionalString(params, "confirm");
        if (supplied == null) return p.object(alloc, .{
            .confirmation_required = p.boolean(true),
            .confirmation = p.str(&token),
            .summary = p.str(parsed.summary),
            .method = p.str(parsed.method),
            .params = parsed.params,
        });
        if (supplied.?.len != token.len or !std.crypto.timing_safe.eql([24]u8, supplied.?[0..24].*, token))
            return error.InvalidConfirmation;
        var nested: std.json.ObjectMap = .init(alloc);
        try nested.put("method", p.str(parsed.method));
        try nested.put("params", parsed.params);
        if (request.object.get("password")) |password| try nested.put("password", password);
        if (request.object.get("id_format")) |format| try nested.put("id_format", format);
        return handle(alloc, .{ .object = nested });
    }
    if (eq(u8, method, "settings.get")) {
        const prefs = Application.default().getAppearance();
        return p.object(alloc, .{
            .scheme = p.str(@tagName(prefs.scheme)),
            .inherit_terminal_colors = p.boolean(prefs.inherit_terminal_colors),
            .theme = if (prefs.theme) |value| p.str(value) else .null,
        });
    }
    if (eq(u8, method, "settings.set") or eq(u8, method, "theme.apply")) {
        const managed: ?p.Value = feature_store.get(alloc, "policies", "_settings") catch |err| switch (err) {
            error.NotFound => null,
            else => return err,
        };
        if (managed) |policy| {
            var requested = params.object.iterator();
            while (requested.next()) |entry| {
                if (policy.object.contains(entry.key_ptr.*)) return error.ManagedPolicy;
            }
        }
        var prefs = Application.default().getAppearance();
        if (try p.optionalString(params, "scheme")) |value|
            prefs.scheme = std.meta.stringToEnum(appearance.Scheme, value) orelse return error.InvalidScheme;
        if (params.object.get("inherit_terminal_colors")) |value| {
            if (value != .bool) return error.InvalidParameterType;
            prefs.inherit_terminal_colors = value.bool;
        }
        if (try boolParam(params, "clear_theme", false))
            prefs.theme = null
        else if (try p.optionalString(params, "theme")) |value|
            prefs.theme = value;
        try Application.default().setAppearance(prefs);
        return p.object(alloc, .{ .saved = p.boolean(true) });
    }
    if (eq(u8, method, "theme.list")) {
        const themes = try appearance.listThemes(alloc);
        var values: std.array_list.Managed(p.Value) = .init(alloc);
        for (themes) |theme| try values.append(try p.object(alloc, .{
            .name = p.str(theme.name),
            .foreground = try p.object(alloc, .{
                .r = p.integer(theme.foreground.r),
                .g = p.integer(theme.foreground.g),
                .b = p.integer(theme.foreground.b),
            }),
            .background = try p.object(alloc, .{
                .r = p.integer(theme.background.r),
                .g = p.integer(theme.background.g),
                .b = p.integer(theme.background.b),
            }),
        }));
        return .{ .array = values };
    }
    if (eq(u8, method, "shortcut.list")) {
        const config = Application.default().getConfig();
        defer config.unref();
        var values: std.array_list.Managed(p.Value) = .init(alloc);
        var iterator = config.get().keybind.set.bindings.iterator();
        while (iterator.next()) |entry| {
            const leaf = switch (entry.value_ptr.*) {
                .leader => continue,
                inline .leaf, .leaf_chained => |value| value.generic(),
            };
            var trigger: std.Io.Writer.Allocating = .init(alloc);
            try entry.key_ptr.format(&trigger.writer);
            const trigger_text = try trigger.toOwnedSlice();
            var actions: std.array_list.Managed(p.Value) = .init(alloc);
            for (leaf.actionsSlice()) |action| {
                var action_writer: std.Io.Writer.Allocating = .init(alloc);
                try action.format(&action_writer.writer);
                try actions.append(p.str(try action_writer.toOwnedSlice()));
            }
            try values.append(try p.object(alloc, .{
                .trigger = p.str(trigger_text),
                .actions = p.Value{ .array = actions },
                .global = p.boolean(leaf.flags.global),
            }));
        }
        return .{ .array = values };
    }
    if (eq(u8, method, "update.status")) return platform.status(alloc);
    if (eq(u8, method, "update.apply")) {
        const managed: ?p.Value = feature_store.get(alloc, "policies", "managed-updates") catch |err| switch (err) {
            error.NotFound => null,
            else => return err,
        };
        if (managed) |policy| {
            if (policy.object.get("updates_enabled")) |enabled|
                if (enabled != .bool or !enabled.bool) return error.ManagedPolicy;
        }
        try requiredForce(params);
        return platform.apply(alloc, try p.string(params, "artifact"), try p.string(params, "sha256"));
    }
    if (eq(u8, method, "diagnostics.collect"))
        return platform.collectDiagnostics(alloc, try p.string(params, "destination"));
    if (eq(u8, method, "platform.status")) {
        const display = gdk.Display.getDefault();
        return p.object(alloc, .{
            .display_available = p.boolean(display != null),
            .display_protocol = p.str(std.posix.getenv("XDG_SESSION_TYPE") orelse "unknown"),
            .desktop = p.str(std.posix.getenv("XDG_CURRENT_DESKTOP") orelse "unknown"),
            .accessibility = try p.object(alloc, .{
                .semantic_gtk_controls = p.boolean(true),
                .keyboard_navigation = p.boolean(true),
                .desktop_text_scaling = p.boolean(true),
                .reduced_motion_respected = p.boolean(true),
            }),
            .update = try platform.status(alloc),
        });
    }
    if (std.mem.startsWith(u8, method, "trust.")) {
        const path = try p.string(params, "path");
        const key = try feature_store.trustKey(alloc, path);
        const fingerprint = try feature_store.trustFingerprint(alloc, path);
        if (eq(u8, method, "trust.preview")) return p.object(alloc, .{
            .path = p.str(path),
            .fingerprint = p.str(&fingerprint),
            .confirmation_required = p.boolean(true),
        });
        if (eq(u8, method, "trust.status")) {
            const record = feature_store.get(alloc, "trust", &key) catch |err| switch (err) {
                error.NotFound => return p.object(alloc, .{ .trusted = p.boolean(false), .fingerprint = p.str(&fingerprint) }),
                else => return err,
            };
            const saved = try p.string(record, "fingerprint");
            return p.object(alloc, .{
                .trusted = p.boolean(eq(u8, saved, &fingerprint)),
                .fingerprint = p.str(&fingerprint),
                .saved_fingerprint = p.str(saved),
            });
        }
        if (eq(u8, method, "trust.revoke")) {
            try feature_store.remove(alloc, "trust", &key);
            return p.object(alloc, .{ .trusted = p.boolean(false) });
        }
        const confirmation = try p.string(params, "confirm");
        if (!eq(u8, confirmation, &fingerprint)) return error.InvalidConfirmation;
        try feature_store.set(alloc, "trust", &key, try p.object(alloc, .{
            .path = p.str(path),
            .fingerprint = p.str(&fingerprint),
            .granted_at = p.integer(std.time.milliTimestamp()),
        }));
        return p.object(alloc, .{ .trusted = p.boolean(true), .fingerprint = p.str(&fingerprint) });
    }
    if (std.mem.startsWith(u8, method, "action.") or std.mem.startsWith(u8, method, "layout.")) {
        const separator = std.mem.indexOfScalar(u8, method, '.') orelse unreachable;
        const prefix = method[0..separator];
        const operation = method[separator + 1 ..];
        const collection = if (eq(u8, prefix, "action")) "actions" else "layouts";
        if (eq(u8, operation, "list")) return feature_store.list(alloc, collection);
        const key = try p.string(params, "key");
        if (eq(u8, operation, "get")) return feature_store.get(alloc, collection, key);
        if (eq(u8, operation, "delete")) {
            try feature_store.remove(alloc, collection, key);
            return p.object(alloc, .{ .deleted = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, operation, "set")) {
            const parsed = try std.json.parseFromSliceLeaky(p.Value, alloc, try p.string(params, "value"), .{ .allocate = .alloc_always });
            try feature_store.set(alloc, collection, key, parsed);
            return p.object(alloc, .{ .saved = p.boolean(true), .key = p.str(key) });
        }
        const target_value = try target(alloc, params, "workspace_id");
        const tab = target_value.tab.?;
        if (eq(u8, operation, "run")) {
            const item = try feature_store.get(alloc, "actions", key);
            const cwd = try p.string(item, "cwd");
            const trust_key = try feature_store.trustKey(alloc, cwd);
            const fingerprint = try feature_store.trustFingerprint(alloc, cwd);
            const trust = try feature_store.get(alloc, "trust", &trust_key);
            if (!eq(u8, try p.string(trust, "fingerprint"), &fingerprint)) return error.ProjectTrustChanged;
            try tab.getSplitTree().newSplit(.right, null, .{ .working_directory = try alloc.dupeZ(u8, cwd) });
            const created = tab.getActiveSurface().?;
            try PendingInput.start(created, try p.string(item, "command"));
            return terminalValue(alloc, target_value.window, tab, created);
        }
        if (eq(u8, operation, "apply")) {
            const layout = try feature_store.get(alloc, "layouts", key);
            const surfaces = layout.object.get("terminals") orelse return error.InvalidLayout;
            if (surfaces != .array or surfaces.array.items.len == 0 or surfaces.array.items.len > 16) return error.InvalidLayout;
            for (surfaces.array.items) |item| {
                const cwd = try p.string(item, "cwd");
                const trust_key = try feature_store.trustKey(alloc, cwd);
                const fingerprint = try feature_store.trustFingerprint(alloc, cwd);
                const trust = try feature_store.get(alloc, "trust", &trust_key);
                if (!eq(u8, try p.string(trust, "fingerprint"), &fingerprint)) return error.ProjectTrustChanged;
                try tab.getSplitTree().newSplit(.right, null, .{ .working_directory = try alloc.dupeZ(u8, cwd) });
                if (try p.optionalString(item, "command")) |command| try PendingInput.start(tab.getActiveSurface().?, command);
            }
            return p.object(alloc, .{ .created = p.integer(surfaces.array.items.len) });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "feed.")) {
        if (eq(u8, method, "feed.push")) return feedPush(alloc, params);
        if (eq(u8, method, "feed.reply")) return feedReply(alloc, params);
        if (eq(u8, method, "feed.tui")) return feedTui(alloc, params);
        if (eq(u8, method, "feed.list")) return feedList(alloc);
        if (eq(u8, method, "feed.open")) {
            const win = if (try p.optionalString(params, "workspace_id")) |value|
                (try find(alloc, "workspace_id", value)).window
            else if (try p.optionalString(params, "window_id")) |value|
                (try find(alloc, "window_id", value)).window
            else
                try currentWindow(alloc);
            win.setRightSidebarMode(.feed, true);
            return p.object(alloc, .{ .opened = p.boolean(true), .mode = p.str("feed") });
        }
    }
    if (std.mem.startsWith(u8, method, "dock.") or std.mem.startsWith(u8, method, "feed.") or std.mem.startsWith(u8, method, "custom-sidebar.")) {
        const separator = std.mem.indexOfScalar(u8, method, '.') orelse unreachable;
        const prefix = method[0..separator];
        const operation = method[separator + 1 ..];
        const collection = if (eq(u8, prefix, "dock")) "dock" else if (eq(u8, prefix, "feed")) "feed" else "sidebars";
        if (eq(u8, operation, "list")) return feature_store.list(alloc, collection);
        const key = try p.string(params, "key");
        if (eq(u8, operation, "set")) {
            const parsed = try std.json.parseFromSliceLeaky(p.Value, alloc, try p.string(params, "value"), .{ .allocate = .alloc_always });
            try feature_store.set(alloc, collection, key, parsed);
            return p.object(alloc, .{ .saved = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, operation, "delete")) {
            try feature_store.remove(alloc, collection, key);
            return p.object(alloc, .{ .deleted = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, operation, "open")) {
            const win = if (try p.optionalString(params, "workspace_id")) |value|
                (try find(alloc, "workspace_id", value)).window
            else if (try p.optionalString(params, "window_id")) |value|
                (try find(alloc, "window_id", value)).window
            else
                try currentWindow(alloc);
            const mode: Window.SidebarMode = if (eq(u8, prefix, "dock"))
                .dock
            else if (eq(u8, prefix, "feed"))
                .feed
            else mode: {
                const config = try feature_store.get(alloc, collection, key);
                break :mode std.meta.stringToEnum(Window.SidebarMode, try p.string(config, "mode")) orelse return error.InvalidSidebarMode;
            };
            win.setRightSidebarMode(mode, true);
            return p.object(alloc, .{ .opened = p.boolean(true), .mode = p.str(@tagName(mode)), .key = p.str(key) });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "vault.")) {
        if (eq(u8, method, "vault.list")) return feature_store.list(alloc, "vault");
        if (eq(u8, method, "vault.search")) {
            const query = try p.string(params, "query");
            if (query.len == 0 or query.len > 4096) return error.InvalidQuery;
            const records = try feature_store.list(alloc, "vault");
            var matches: std.array_list.Managed(p.Value) = .init(alloc);
            for (records.array.items) |record| {
                const value = record.object.get("value").?;
                const text = (try p.optionalString(value, "text")) orelse continue;
                if (std.mem.indexOf(u8, text, query) != null) try matches.append(record);
            }
            return .{ .array = matches };
        }
        const key = try p.string(params, "key");
        if (eq(u8, method, "vault.get")) return feature_store.get(alloc, "vault", key);
        if (eq(u8, method, "vault.delete")) {
            try feature_store.remove(alloc, "vault", key);
            return p.object(alloc, .{ .deleted = p.boolean(true) });
        }
        if (eq(u8, method, "vault.capture")) {
            try feature_store.set(alloc, "vault", key, try p.object(alloc, .{
                .kind = p.str("transcript"),
                .text = p.str(try p.string(params, "text")),
                .workspace_id = if (try p.optionalString(params, "workspace_id")) |value| p.str(value) else .null,
                .terminal_id = if (try p.optionalString(params, "terminal_id")) |value| p.str(value) else .null,
                .created_at = p.integer(std.time.milliTimestamp()),
            }));
            return p.object(alloc, .{ .saved = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, method, "vault.checkpoint")) {
            try feature_store.set(alloc, "vault", key, try p.object(alloc, .{
                .kind = p.str("checkpoint"),
                .created_at = p.integer(std.time.milliTimestamp()),
                .snapshot = try sessionSnapshot(alloc),
            }));
            return p.object(alloc, .{ .saved = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, method, "vault.fork")) {
            const record = try feature_store.get(alloc, "vault", key);
            const snapshot = record.object.get("snapshot") orelse return error.NotACheckpoint;
            return p.object(alloc, .{ .restored = p.boolean(try restoreSnapshot(alloc, snapshot, false)), .key = p.str(key) });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "machine.")) {
        if (eq(u8, method, "machine.list")) return feature_store.list(alloc, "machines");
        const key = try p.string(params, "key");
        if (eq(u8, method, "machine.register")) {
            var record = try std.json.parseFromSliceLeaky(p.Value, alloc, try p.string(params, "value"), .{ .allocate = .alloc_always });
            if (record != .object or try p.optionalString(record, "host") == null) return error.InvalidMachine;
            try record.object.put("state", p.str("stopped"));
            try record.object.put("registered_at", p.integer(std.time.milliTimestamp()));
            try feature_store.set(alloc, "machines", key, record);
            return p.object(alloc, .{ .registered = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, method, "machine.delete")) {
            try requiredForce(params);
            try feature_store.remove(alloc, "machines", key);
            return p.object(alloc, .{ .deleted = p.boolean(true) });
        }
        var record = try feature_store.get(alloc, "machines", key);
        if (eq(u8, method, "machine.start") or eq(u8, method, "machine.stop")) {
            try record.object.put("state", p.str(if (eq(u8, method, "machine.start")) "running" else "stopped"));
            try record.object.put("updated_at", p.integer(std.time.milliTimestamp()));
            try feature_store.set(alloc, "machines", key, record);
        }
        if (eq(u8, method, "machine.route")) {
            if (!eq(u8, (try p.optionalString(record, "state")) orelse "stopped", "running")) return error.MachineStopped;
            return p.object(alloc, .{
                .key = p.str(key),
                .host = p.str(try p.string(record, "host")),
                .ssh_config = if (try p.optionalString(record, "ssh_config")) |value| p.str(value) else .null,
                .private = p.boolean(if (record.object.get("private")) |value| value == .bool and value.bool else false),
            });
        }
        return record;
    }
    if (std.mem.startsWith(u8, method, "publication.")) {
        if (eq(u8, method, "publication.list")) return feature_store.list(alloc, "publications");
        const key = try p.string(params, "key");
        if (eq(u8, method, "publication.publish")) {
            const record = try std.json.parseFromSliceLeaky(p.Value, alloc, try p.string(params, "value"), .{ .allocate = .alloc_always });
            try feature_store.set(alloc, "publications", key, record);
            return p.object(alloc, .{ .published = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, method, "publication.delete")) {
            try feature_store.remove(alloc, "publications", key);
            return p.object(alloc, .{ .published = p.boolean(false) });
        }
        return feature_store.get(alloc, "publications", key);
    }
    if (std.mem.startsWith(u8, method, "event.")) {
        if (eq(u8, method, "event.list")) return feature_store.list(alloc, "events");
        if (eq(u8, method, "event.clear")) {
            const records = try feature_store.list(alloc, "events");
            for (records.array.items) |record| try feature_store.remove(alloc, "events", record.object.get("key").?.string);
            return p.object(alloc, .{ .cleared = p.integer(records.array.items.len) });
        }
        if (eq(u8, method, "event.emit")) {
            var event = try std.json.parseFromSliceLeaky(p.Value, alloc, try p.string(params, "value"), .{ .allocate = .alloc_always });
            if (event != .object or try p.optionalString(event, "type") == null) return error.InvalidEvent;
            const event_id = randomId();
            try event.object.put("created_at", p.integer(std.time.milliTimestamp()));
            try feature_store.set(alloc, "events", &event_id, event);
            var matched: usize = 0;
            var delivered: usize = 0;
            const now = std.time.milliTimestamp();
            const rules = try feature_store.list(alloc, "rules");
            for (rules.array.items) |*record| {
                const rule = record.object.getPtr("value").?;
                const expected = (try p.optionalString(rule.*, "event")) orelse continue;
                if (!eq(u8, expected, try p.string(event, "type"))) continue;
                matched += 1;
                const interval = rule.object.get("minimum_interval_ms") orelse p.integer(0);
                const last = rule.object.get("last_triggered_at") orelse p.integer(0);
                if (interval != .integer or last != .integer or interval.integer < 0) return error.InvalidAutomationRule;
                if (now - last.integer < interval.integer) continue;
                const action = try p.string(rule.*, "action");
                if (!inWords("notify log run rpc webhook", action)) return error.InvalidAutomationAction;
                const delivery_id = randomId();
                try feature_store.set(alloc, "feed", &delivery_id, try p.object(alloc, .{
                    .type = p.str("automation"),
                    .action = p.str(action),
                    .event_id = p.str(&event_id),
                    .rule = p.str(record.object.get("key").?.string),
                    .created_at = p.integer(now),
                }));
                try rule.object.put("last_triggered_at", p.integer(now));
                try feature_store.set(alloc, "rules", record.object.get("key").?.string, rule.*);
                delivered += 1;
            }
            return p.object(alloc, .{
                .event_id = p.str(&event_id),
                .matched_rules = p.integer(matched),
                .delivered_actions = p.integer(delivered),
            });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "automation-rule.")) {
        const operation = method["automation-rule.".len..];
        if (eq(u8, operation, "list")) return feature_store.list(alloc, "rules");
        const key = try p.string(params, "key");
        if (eq(u8, operation, "get")) return feature_store.get(alloc, "rules", key);
        if (eq(u8, operation, "delete")) {
            try feature_store.remove(alloc, "rules", key);
            return p.object(alloc, .{ .deleted = p.boolean(true) });
        }
        if (eq(u8, operation, "set")) {
            const rule = try std.json.parseFromSliceLeaky(p.Value, alloc, try p.string(params, "value"), .{ .allocate = .alloc_always });
            if (rule != .object or try p.optionalString(rule, "event") == null or try p.optionalString(rule, "action") == null)
                return error.InvalidAutomationRule;
            try feature_store.set(alloc, "rules", key, rule);
            return p.object(alloc, .{ .saved = p.boolean(true), .key = p.str(key) });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "device.")) {
        if (eq(u8, method, "device.list")) {
            const records = try feature_store.list(alloc, "devices");
            for (records.array.items) |*item| _ = item.object.getPtr("value").?.object.swapRemove("token");
            return records;
        }
        const key = try p.string(params, "key");
        if (eq(u8, method, "device.pair")) {
            var bytes: [32]u8 = undefined;
            std.crypto.random.bytes(&bytes);
            const token = std.fmt.bytesToHex(bytes, .lower);
            try feature_store.set(alloc, "devices", key, try p.object(alloc, .{
                .name = p.str((try p.optionalString(params, "name")) orelse key),
                .token = p.str(&token),
                .paired_at = p.integer(std.time.milliTimestamp()),
                .state = .null,
                .last_notification = .null,
                .last_reply = .null,
                .last_task = .null,
            }));
            return p.object(alloc, .{ .paired = p.boolean(true), .key = p.str(key), .token = p.str(&token) });
        }
        var record = try feature_store.get(alloc, "devices", key);
        if (eq(u8, method, "device.status")) {
            _ = record.object.swapRemove("token");
            return record;
        }
        if (eq(u8, method, "device.revoke")) {
            try feature_store.remove(alloc, "devices", key);
            return p.object(alloc, .{ .paired = p.boolean(false) });
        }
        const token = try p.string(params, "token");
        const expected = try p.string(record, "token");
        if (token.len != expected.len or !std.crypto.timing_safe.eql([64]u8, token[0..64].*, expected[0..64].*))
            return error.Unauthorized;
        if (eq(u8, method, "device.sync")) {
            const state_value = try std.json.parseFromSliceLeaky(p.Value, alloc, try p.string(params, "value"), .{ .allocate = .alloc_always });
            try record.object.put("state", state_value);
        } else if (eq(u8, method, "device.notify")) {
            const message = try p.string(params, "value");
            try record.object.put("last_notification", p.str(message));
            const xdg = @import("../../os/xdg.zig");
            if (xdg.state(alloc, .{ .subdir = "colm" })) |dir| {
                std.fs.cwd().makePath(dir) catch {};
                const path = std.fs.path.join(alloc, &.{ dir, "device-inbox.jsonl" }) catch {
                    return error.OutOfMemory;
                };
                if (std.fs.cwd().openFile(path, .{ .mode = .write_only })) |opened| {
                    var file = opened;
                    defer file.close();
                    file.seekFromEnd(0) catch {};
                    file.writeAll(message) catch {};
                    file.writeAll("\n") catch {};
                } else |_| {
                    if (std.fs.cwd().createFile(path, .{})) |created| {
                        var file = created;
                        defer file.close();
                        file.writeAll(message) catch {};
                        file.writeAll("\n") catch {};
                    } else |_| {}
                }
            } else |_| {}
            if (windows(alloc)) |wins| {
                if (wins.len > 0) wins[0].addToast(try alloc.dupeZ(u8, message));
            } else |_| {}
        } else if (eq(u8, method, "device.reply")) {
            try record.object.put("last_reply", p.str(try p.string(params, "value")));
        } else if (eq(u8, method, "device.compose")) {
            try record.object.put("last_task", p.str(try p.string(params, "value")));
        } else return error.UnknownMethod;
        try record.object.put("updated_at", p.integer(std.time.milliTimestamp()));
        try feature_store.set(alloc, "devices", key, record);
        return p.object(alloc, .{ .accepted = p.boolean(true), .key = p.str(key) });
    }
    if (std.mem.startsWith(u8, method, "canvas.")) {
        if (eq(u8, method, "canvas.list")) return feature_store.list(alloc, "canvases");
        const key = try p.string(params, "key");
        if (eq(u8, method, "canvas.set")) {
            const value = try jsonValueParam(alloc, params, "value");
            if (value != .object) return error.InvalidFeatureValue;
            if (value.object.get("surfaces")) |surfaces|
                if (surfaces != .array or surfaces.array.items.len > 128) return error.InvalidFeatureValue;
            try feature_store.set(alloc, "canvases", key, value);
            return p.object(alloc, .{ .saved = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, method, "canvas.delete")) {
            try feature_store.remove(alloc, "canvases", key);
            return p.object(alloc, .{ .deleted = p.boolean(true) });
        }
        const value = try feature_store.get(alloc, "canvases", key);
        if (eq(u8, method, "canvas.get")) return value;
        if (eq(u8, method, "canvas.open")) {
            const t = resolvedMetadataTarget(alloc, params) catch Target{
                .window = try currentWindow(alloc),
                .tab = null,
                .surface = null,
            };
            const tab = t.tab orelse return error.TargetNotFound;
            const data = metadata(tab.as(gobject.Object));
            if (value.object.get("surfaces")) |surfaces| {
                if (surfaces == .array) {
                    for (surfaces.array.items) |item| {
                        const uri = if (item == .object)
                            (try p.optionalString(item, "uri")) orelse (try p.optionalString(item, "url")) orelse continue
                        else if (item == .string) item.string else continue;
                        const pane_id = randomId();
                        const pane = browser.create(
                            a,
                            tab.as(gtk.Box),
                            tab.getSplitTree(),
                            &pane_id,
                            if (data.remote) |r| r.proxy else null,
                            null,
                            if (data.remote) |r| r.host else "local",
                        ) catch continue;
                        data.browsers.append(a, pane) catch {
                            pane.destroy();
                            continue;
                        };
                        pane.loadUri(uri);
                    }
                }
            }
            return p.object(alloc, .{ .opened = p.boolean(true), .key = p.str(key), .canvas = value });
        }

        return error.UnknownMethod;
    }
    if (eq(u8, method, "computer-use.open")) {
        const tab = try currentTab(alloc, params);
        const uri = (try p.optionalString(params, "uri")) orelse "about:blank";
        const pane = try openDeviceColumn(
            tab,
            "computer-use",
            uri,
            1280,
            800,
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        );
        return try p.object(alloc, .{
            .opened = p.boolean(true),
            .browser_id = p.str(pane.id),
            .workspace_id = p.str(id(tab)),
            .profile = p.str("computer-use"),
            .uri = p.str(uri),
        });
    }
    if (std.mem.startsWith(u8, method, "simulator.")) {
        if (eq(u8, method, "simulator.list")) return feature_store.list(alloc, "simulators");
        if (eq(u8, method, "simulator.open")) {
            const tab = try currentTab(alloc, params);
            const kind = (try p.optionalString(params, "kind")) orelse "iphone";
            const uri = (try p.optionalString(params, "uri")) orelse "about:blank";
            const iphone = eq(u8, kind, "iphone") or eq(u8, kind, "ios");
            const android = eq(u8, kind, "android");
            if (!iphone and !android) return error.InvalidFeatureValue;
            const width: c_int = if (iphone) 390 else 360;
            const height: c_int = if (iphone) 844 else 800;
            const ua: []const u8 = if (iphone)
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
            else
                "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
            const pane = try openDeviceColumn(tab, "simulator", uri, width, height, ua);
            const key = (try p.optionalString(params, "key")) orelse pane.id;
            try feature_store.set(alloc, "simulators", key, try p.object(alloc, .{
                .kind = p.str(if (iphone) "iphone" else "android"),
                .browser_id = p.str(pane.id),
                .workspace_id = p.str(id(tab)),
                .width = p.integer(width),
                .height = p.integer(height),
                .uri = p.str(uri),
                .connected = p.boolean(true),
                .updated_at = p.integer(std.time.milliTimestamp()),
            }));
            return try p.object(alloc, .{
                .opened = p.boolean(true),
                .key = p.str(key),
                .browser_id = p.str(pane.id),
                .kind = p.str(if (iphone) "iphone" else "android"),
            });
        }
        const key = try p.string(params, "key");

        if (eq(u8, method, "simulator.register")) {
            var value = try jsonValueParam(alloc, params, "value");
            if (value != .object) return error.InvalidFeatureValue;
            _ = try p.string(value, "kind");
            try value.object.put("connected", p.boolean(true));
            try value.object.put("updated_at", p.integer(std.time.milliTimestamp()));
            try feature_store.set(alloc, "simulators", key, value);
            return p.object(alloc, .{ .registered = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, method, "simulator.delete")) {
            try feature_store.remove(alloc, "simulators", key);
            return p.object(alloc, .{ .deleted = p.boolean(true) });
        }
        var value = try feature_store.get(alloc, "simulators", key);
        if (eq(u8, method, "simulator.status")) return value;
        if (eq(u8, method, "simulator.stream")) {
            try value.object.put("stream", p.str(try p.string(params, "value")));
        } else if (eq(u8, method, "simulator.touch")) {
            const x = params.object.get("x") orelse return error.MissingParameter;
            const y = params.object.get("y") orelse return error.MissingParameter;
            if (x != .integer or y != .integer or x.integer < 0 or y.integer < 0)
                return error.InvalidFeatureValue;
            try value.object.put("last_touch", try p.object(alloc, .{
                .x = x,
                .y = y,
                .at = p.integer(std.time.milliTimestamp()),
            }));
        } else return error.UnknownMethod;
        try value.object.put("updated_at", p.integer(std.time.milliTimestamp()));
        try feature_store.set(alloc, "simulators", key, value);
        return value;
    }
    if (std.mem.startsWith(u8, method, "policy.")) {
        if (eq(u8, method, "policy.list") or eq(u8, method, "policy.effective"))
            return feature_store.list(alloc, "policies");
        const key = try p.string(params, "key");
        if (eq(u8, method, "policy.set")) {
            const value = try jsonValueParam(alloc, params, "value");
            if (value != .object) return error.InvalidFeatureValue;
            try feature_store.set(alloc, "policies", key, value);
            return p.object(alloc, .{ .managed = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, method, "policy.delete")) {
            try feature_store.remove(alloc, "policies", key);
            return p.object(alloc, .{ .deleted = p.boolean(true) });
        }
        if (eq(u8, method, "policy.get")) return feature_store.get(alloc, "policies", key);
        return error.UnknownMethod;
    }
    if (eq(u8, method, "locale.list")) {
        var values: std.array_list.Managed(p.Value) = .init(alloc);
        try values.append(p.str("system"));
        if (std.posix.getenv("LANG")) |lang| try values.append(p.str(lang));
        return .{ .array = values };
    }
    if (eq(u8, method, "locale.status")) {
        var preferred: []const u8 = "system";
        if (feature_store.get(alloc, "policies", "_locale")) |record| {
            preferred = p.string(record, "value") catch "system";
        } else |_| {}
        return p.object(alloc, .{
            .preferred = p.str(preferred),
            .system = p.str(std.posix.getenv("LANG") orelse "C"),
        });
    }
    if (eq(u8, method, "locale.set")) {
        const locale = try p.string(params, "key");
        if (locale.len == 0 or locale.len > 64) return error.InvalidLocale;
        for (locale) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "_.@-", byte) != null))
            return error.InvalidLocale;
        try feature_store.set(alloc, "policies", "_locale", try p.object(alloc, .{ .value = p.str(locale) }));
        return p.object(alloc, .{ .preferred = p.str(locale), .restart_required = p.boolean(true) });
    }
    if (std.mem.startsWith(u8, method, "agent-control.")) {
        if (eq(u8, method, "agent-control.list")) return feature_store.list(alloc, "agents");
        const key = try p.string(params, "key");
        if (eq(u8, method, "agent-control.register")) {
            const pid_value = params.object.get("pid") orelse return error.MissingParameter;
            const limit = params.object.get("limit_mb") orelse return error.MissingParameter;
            if (pid_value != .integer or limit != .integer or limit.integer < 16 or limit.integer > 1024 * 1024)
                return error.InvalidAgentLimit;
            _ = try task_manager.inspect(alloc, pid_value.integer);
            try feature_store.set(alloc, "agents", key, try p.object(alloc, .{
                .pid = pid_value,
                .limit_mb = limit,
                .hibernated = p.boolean(false),
                .keep_awake = p.boolean(try boolParam(params, "keep_awake", false)),
                .registered_at = p.integer(std.time.milliTimestamp()),
            }));
            return p.object(alloc, .{ .registered = p.boolean(true), .key = p.str(key) });
        }
        var record = try feature_store.get(alloc, "agents", key);
        if (eq(u8, method, "agent-control.delete")) {
            try feature_store.remove(alloc, "agents", key);
            return p.object(alloc, .{ .deleted = p.boolean(true) });
        }
        const pid_value = record.object.get("pid") orelse return error.InvalidFeatureValue;
        const limit = record.object.get("limit_mb") orelse return error.InvalidFeatureValue;
        if (pid_value != .integer or limit != .integer) return error.InvalidFeatureValue;
        var status = try task_manager.inspect(alloc, pid_value.integer);
        const memory = status.object.get("memory_kib").?.integer;
        try status.object.put("limit_mb", limit);
        try status.object.put("over_limit", p.boolean(memory > limit.integer * 1024));
        try status.object.put("hibernated", record.object.get("hibernated") orelse p.boolean(false));
        if (eq(u8, method, "agent-control.status")) return status;
        if (eq(u8, method, "agent-control.check")) {
            if (memory > limit.integer * 1024 and !(record.object.get("hibernated") orelse p.boolean(false)).bool) {
                try task_manager.signal(pid_value.integer, std.posix.SIG.STOP);
                try record.object.put("hibernated", p.boolean(true));
                try feature_store.set(alloc, "agents", key, record);
                try status.object.put("hibernated", p.boolean(true));
            }
            return status;
        }
        if (eq(u8, method, "agent-control.hibernate")) {
            try task_manager.signal(pid_value.integer, std.posix.SIG.STOP);
            try record.object.put("hibernated", p.boolean(true));
        } else if (eq(u8, method, "agent-control.resume")) {
            try task_manager.signal(pid_value.integer, std.posix.SIG.CONT);
            try record.object.put("hibernated", p.boolean(false));
        } else return error.UnknownMethod;
        try feature_store.set(alloc, "agents", key, record);
        return p.object(alloc, .{ .key = p.str(key), .hibernated = record.object.get("hibernated").? });
    }
    if (std.mem.startsWith(u8, method, "headless.")) {
        if (eq(u8, method, "headless.list")) return feature_store.list(alloc, "sessions");
        const key = try p.string(params, "key");
        if (eq(u8, method, "headless.delete")) {
            try requiredForce(params);
            try feature_store.remove(alloc, "sessions", key);
            return p.object(alloc, .{ .deleted = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, method, "headless.save") or eq(u8, method, "headless.detach")) {
            try feature_store.set(alloc, "sessions", key, try p.object(alloc, .{
                .name = p.str(key),
                .detached = p.boolean(true),
                .saved_at = p.integer(std.time.milliTimestamp()),
                .snapshot = try sessionSnapshot(alloc),
            }));
            return p.object(alloc, .{ .saved = p.boolean(true), .detached = p.boolean(true), .key = p.str(key) });
        }
        const record = try feature_store.get(alloc, "sessions", key);
        if (eq(u8, method, "headless.tui")) return record.object.get("snapshot") orelse return error.InvalidFeatureValue;
        if (eq(u8, method, "headless.attach")) {
            const snapshot = record.object.get("snapshot") orelse return error.InvalidFeatureValue;
            return p.object(alloc, .{ .attached = p.boolean(try restoreSnapshot(alloc, snapshot, false)), .key = p.str(key) });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "task.")) {
        if (eq(u8, method, "task.list")) return feature_store.list(alloc, "tasks");
        if (eq(u8, method, "task.tree")) {
            const records = try feature_store.list(alloc, "tasks");
            var values: std.array_list.Managed(p.Value) = .init(alloc);
            for (records.array.items) |record| {
                const value = record.object.get("value").?;
                const pid_value = value.object.get("pid") orelse continue;
                if (pid_value != .integer) continue;
                var status = task_manager.inspect(alloc, pid_value.integer) catch continue;
                try status.object.put("key", record.object.get("key").?);
                try status.object.put("owner", value.object.get("owner") orelse .null);
                try values.append(status);
            }
            return .{ .array = values };
        }
        const key = try p.string(params, "key");
        if (eq(u8, method, "task.register")) {
            const pid_value = params.object.get("pid") orelse return error.MissingParameter;
            if (pid_value != .integer) return error.InvalidParams;
            _ = try task_manager.inspect(alloc, pid_value.integer);
            try feature_store.set(alloc, "tasks", key, try p.object(alloc, .{
                .pid = pid_value,
                .owner = p.str((try p.optionalString(params, "owner")) orelse "user"),
                .registered_at = p.integer(std.time.milliTimestamp()),
            }));
            return p.object(alloc, .{ .registered = p.boolean(true), .key = p.str(key) });
        }
        const record = try feature_store.get(alloc, "tasks", key);
        if (eq(u8, method, "task.unregister")) {
            try feature_store.remove(alloc, "tasks", key);
            return p.object(alloc, .{ .registered = p.boolean(false) });
        }
        const pid_value = record.object.get("pid") orelse return error.InvalidFeatureValue;
        if (pid_value != .integer) return error.InvalidFeatureValue;
        if (eq(u8, method, "task.status")) return task_manager.inspect(alloc, pid_value.integer);
        if (eq(u8, method, "task.terminate")) {
            try requiredForce(params);
            _ = try task_manager.inspect(alloc, pid_value.integer);
            try task_manager.signal(pid_value.integer, std.posix.SIG.TERM);
            return p.object(alloc, .{ .signaled = p.boolean(true), .pid = pid_value });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "viewer.")) {
        if (eq(u8, method, "viewer.list")) return feature_store.list(alloc, "viewers");
        const key = try p.optionalString(params, "key");
        if (eq(u8, method, "viewer.delete")) {
            try feature_store.remove(alloc, "viewers", key orelse return error.MissingParameter);
            return p.object(alloc, .{ .deleted = p.boolean(true) });
        }
        if (eq(u8, method, "viewer.refresh")) {
            const record = try feature_store.get(alloc, "viewers", key orelse return error.MissingParameter);
            return viewer.render(alloc, try p.string(record, "path"), try p.optionalString(record, "type"));
        }
        const path = try p.string(params, "path");
        const kind = try p.optionalString(params, "type");
        if (eq(u8, method, "viewer.save")) {
            const name = key orelse return error.MissingParameter;
            try feature_store.set(alloc, "viewers", name, try p.object(alloc, .{
                .path = p.str(path),
                .type = if (kind) |value| p.str(value) else .null,
            }));
        }
        return viewer.render(alloc, path, kind);
    }
    if (std.mem.startsWith(u8, method, "group.") or std.mem.startsWith(u8, method, "todo.") or std.mem.startsWith(u8, method, "lane.")) {
        const separator = std.mem.indexOfScalar(u8, method, '.') orelse unreachable;
        const prefix = method[0..separator];
        const operation = method[separator + 1 ..];
        const collection = if (eq(u8, prefix, "group")) "groups" else if (eq(u8, prefix, "todo")) "todos" else "lanes";
        if (eq(u8, operation, "list")) return feature_store.list(alloc, collection);
        if (eq(u8, prefix, "group") and eq(u8, operation, "assign")) {
            const group_key = try p.string(params, "key");
            const workspace_id = try p.string(params, "workspace_id");
            const t = try find(alloc, "workspace_id", workspace_id);
            const name = (try p.optionalString(params, "name")) orelse group_key;
            assignWorkspaceGroup(t.tab.?, group_key, name);
            return workspaceValue(alloc, t.window, t.tab.?);
        }
        const key = try p.string(params, "key");
        if (eq(u8, operation, "get")) return feature_store.get(alloc, collection, key);
        if (eq(u8, operation, "delete")) {
            try feature_store.remove(alloc, collection, key);
            return p.object(alloc, .{ .deleted = p.boolean(true), .key = p.str(key) });
        }
        if (eq(u8, operation, "set")) {
            const raw = try p.string(params, "value");
            const parsed = try std.json.parseFromSliceLeaky(p.Value, alloc, raw, .{ .allocate = .alloc_always });
            try feature_store.set(alloc, collection, key, parsed);
            return p.object(alloc, .{ .saved = p.boolean(true), .key = p.str(key) });
        }
        return error.UnknownMethod;
    }

    if (eq(u8, method, "window.current")) {
        const win = if (try p.optionalString(params, "window_id")) |value|
            (try find(alloc, "window_id", value)).window
        else
            try currentWindow(alloc);
        return windowValue(alloc, win);
    }
    if (eq(u8, method, "workspace.current")) {
        if (try p.optionalString(params, "workspace_id")) |value| {
            const t = try find(alloc, "workspace_id", value);
            return workspaceValue(alloc, t.window, t.tab.?);
        }
        const win = if (try p.optionalString(params, "window_id")) |value|
            (try find(alloc, "window_id", value)).window
        else
            try currentWindow(alloc);
        const page = win.getTabView().getSelectedPage() orelse return error.TargetNotFound;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return error.TargetNotFound;
        return workspaceValue(alloc, win, tab);
    }
    if (eq(u8, method, "session.save")) {
        try saveSession();
        return p.object(alloc, .{ .saved = p.boolean(true) });
    }
    if (eq(u8, method, "session.restore")) {
        return p.object(alloc, .{ .restored = p.boolean(try restorePreviousSession()) });
    }
    if (eq(u8, method, "app.reexec")) {
        Application.default().reexec();
        return p.object(alloc, .{ .reexec = p.boolean(true) });
    }

    if (inWords("window.list workspace.list terminal.list pane.list surface.list", method)) {
        var values: std.array_list.Managed(p.Value) = .init(alloc);
        for (try windows(alloc)) |win| {
            if (try p.optionalString(params, "window_id")) |filter| {
                if ((try find(alloc, "window_id", filter)).window != win) continue;
            }
            if (eq(u8, method, "window.list")) {
                try values.append(try windowValue(alloc, win));
                continue;
            }
            const view = win.getTabView();
            var i: c_int = 0;
            while (i < view.getNPages()) : (i += 1) {
                const tab = gobject.ext.cast(Tab, view.getNthPage(i).getChild()) orelse continue;
                if (try p.optionalString(params, "workspace_id")) |filter| {
                    if ((try find(alloc, "workspace_id", filter)).tab != tab) continue;
                }
                if (eq(u8, method, "workspace.list")) {
                    try values.append(try workspaceValue(alloc, win, tab));
                    continue;
                }
                const split_tree = tab.getSplitTree();
                var surface_index: usize = 0;
                var previous_pane: ?*gobject.Object = null;
                while (surface_index < split_tree.surfaceCount()) : (surface_index += 1) {
                    const surface = split_tree.surfaceAt(surface_index).?;
                    const pane = split_tree.paneObject(surface).?;
                    if (try p.optionalString(params, "pane_id")) |filter| {
                        const expected = try find(alloc, "pane_id", filter);
                        const expected_pane = expected.tab.?.getSplitTree().paneObject(expected.surface.?).?;
                        if (pane != expected_pane) continue;
                    }
                    if (eq(u8, method, "pane.list")) {
                        if (pane == previous_pane) continue;
                        previous_pane = pane;
                        try values.append(try terminalValue(
                            alloc,
                            win,
                            tab,
                            split_tree.paneActiveSurface(surface) orelse surface,
                        ));
                    } else {
                        try values.append(try terminalValue(alloc, win, tab, surface));
                    }
                }
            }
        }
        return .{ .array = values };
    }
    if (eq(u8, method, "system.tree")) return treeValue(alloc, params);
    if (eq(u8, method, "window.create")) {
        const win = Window.new(Application.default(), .{});
        win.newTab(null);
        win.as(gtk.Window).present();
        return windowValue(alloc, win);
    }
    if (std.mem.startsWith(u8, method, "window.")) {
        const t = try target(alloc, params, "window_id");
        if (eq(u8, method, "window.current")) {
            return windowValue(alloc, t.window);
        } else if (eq(u8, method, "window.focus")) {
            focus(t);
        } else if (eq(u8, method, "window.rename")) {
            t.window.as(gtk.Window).setTitle(try alloc.dupeZ(u8, try p.string(params, "name")));
            sessionChanged();
        } else if (eq(u8, method, "window.close")) {
            try requiredForce(params);
            t.window.as(gtk.Window).destroy();
        } else return error.UnknownMethod;
        return .null;
    }
    if (eq(u8, method, "workspace.create")) {
        // Omitting a window creates a new one, never targets arbitrary focus.
        const win = if (try p.optionalString(params, "window_id")) |value| (try find(alloc, "window_id", value)).window else Window.new(Application.default(), .{});
        const cwd = try directory(alloc, params);
        const tab = win.automationNewTab(null, cwd);
        try setLocalDirectory(tab.getActiveSurface().?, cwd);
        try scheduleInitialInput(tab.getActiveSurface().?, params);
        if (try p.optionalString(params, "name")) |name| tab.setTitleOverride(try alloc.dupeZ(u8, name));
        win.as(gtk.Window).present();
        return p.object(alloc, .{ .workspace = try workspaceValue(alloc, win, tab), .terminal = try terminalValue(alloc, win, tab, tab.getActiveSurface().?) });
    }
    if (std.mem.startsWith(u8, method, "workspace.")) {
        const t = try target(alloc, params, "workspace_id");
        if (eq(u8, method, "workspace.focus")) {
            focus(t);
        } else if (eq(u8, method, "workspace.rename")) {
            t.tab.?.setTitleOverride(try alloc.dupeZ(u8, try p.string(params, "name")));
        } else if (eq(u8, method, "workspace.move")) {
            const destination = (try find(alloc, "window_id", try p.string(params, "destination_window_id"))).window;
            const source_view = t.window.getTabView();
            const destination_view = destination.getTabView();
            const page = source_view.getPage(t.tab.?.as(gtk.Widget));
            const index = try optionalIndex(params, destination_view.getNPages(), destination_view.getNPages());
            source_view.transferPage(page, destination_view, index);
            destination_view.setSelectedPage(page);
            destination.as(gtk.Window).present();
            return workspaceValue(alloc, destination, t.tab.?);
        } else if (eq(u8, method, "workspace.reorder")) {
            const view = t.window.getTabView();
            const page = view.getPage(t.tab.?.as(gtk.Widget));
            const index = try optionalIndex(params, view.getPagePosition(page), view.getNPages() - 1);
            if (view.reorderPage(page, index) == 0) return error.ReorderFailed;
            return workspaceValue(alloc, t.window, t.tab.?);
        } else if (eq(u8, method, "workspace.close")) {
            if (metadata(t.tab.?.as(gobject.Object)).pinned) return error.WorkspacePinned;
            try requiredForce(params);
            t.window.automationCloseTab(t.tab.?);
        } else if (eq(u8, method, "workspace.pin") or eq(u8, method, "workspace.unpin") or eq(u8, method, "workspace.mute") or eq(u8, method, "workspace.unmute") or eq(u8, method, "workspace.task-status")) {
            const data = metadata(t.tab.?.as(gobject.Object));
            if (eq(u8, method, "workspace.pin")) data.pinned = true;
            if (eq(u8, method, "workspace.unpin")) data.pinned = false;
            if (eq(u8, method, "workspace.mute")) data.muted = true;
            if (eq(u8, method, "workspace.unmute")) data.muted = false;
            if (eq(u8, method, "workspace.task-status")) {
                setWorkspaceTaskStatus(t.tab.?, try p.optionalString(params, "status"));
            }
            if (eq(u8, method, "workspace.pin")) {
                const view = t.window.getTabView();
                const page = view.getPage(t.tab.?.as(gtk.Widget));
                _ = view.reorderPage(page, 0);
            }
            refreshActivities();
            return workspaceValue(alloc, t.window, t.tab.?);
        } else return error.UnknownMethod;
        return .null;
    }
    if (eq(u8, method, "pane.create") or eq(u8, method, "surface.split") or eq(u8, method, "surface.create")) {
        const key: []const u8 = if (params.object.contains("pane_id"))
            "pane_id"
        else if (params.object.contains("surface_id"))
            "surface_id"
        else if (params.object.contains("terminal_id"))
            "terminal_id"
        else
            "workspace_id";
        const t = try target(alloc, params, key);
        const tab = t.tab.?;
        const parent = t.surface orelse tab.getActiveSurface();
        const cwd = try directory(alloc, params);
        if (eq(u8, method, "surface.create")) {
            try tab.getSplitTree().newSurface(
                parent,
                .{ .working_directory = cwd },
            );
        } else {
            try tab.getSplitTree().newSplit(
                try splitDirection(params),
                parent,
                .{ .working_directory = cwd },
            );
        }
        const created = tab.getActiveSurface().?;
        try setLocalDirectory(created, cwd);
        try scheduleInitialInput(created, params);
        if (try p.optionalString(params, "placement")) |place| {
            // niri: "column" and leftover "dock" both mean a new right column.
            if (eq(u8, place, "dock") or eq(u8, place, "column")) {
                // newSplit already inserted a column; do not open the Dock sidebar.
            }
        }
        return terminalValue(alloc, t.window, tab, created);
    }
    if (eq(u8, method, "pane.focus") or eq(u8, method, "surface.focus")) {
        const key: []const u8 = if (params.object.contains("pane_id")) "pane_id" else "surface_id";
        const t = try target(alloc, params, key);
        focus(t);
        return terminalValue(alloc, t.window, t.tab.?, t.surface.?);
    }
    if (eq(u8, method, "pane.close")) {
        try requiredForce(params);
        const t = try target(alloc, params, "pane_id");
        try t.tab.?.getSplitTree().automationClosePane(t.surface.?);
        return .null;
    }
    if (eq(u8, method, "surface.close")) {
        try requiredForce(params);
        const t = try target(alloc, params, "surface_id");
        try t.tab.?.getSplitTree().automationClose(t.surface.?);
        return .null;
    }
    if (eq(u8, method, "surface.move")) {
        const source = try target(alloc, params, "surface_id");
        const destination_workspace_id = try p.string(params, "destination_workspace_id");
        const destination = if (try p.optionalString(params, "pane_id")) |pane_id| destination: {
            const pane = try find(alloc, "pane_id", pane_id);
            if ((try find(alloc, "workspace_id", destination_workspace_id)).tab != pane.tab) return error.TargetMismatch;
            break :destination pane;
        } else try find(alloc, "workspace_id", destination_workspace_id);
        try source.tab.?.getSplitTree().automationMoveTo(
            source.surface.?,
            destination.tab.?.getSplitTree(),
            try splitDirection(params),
            destination.surface orelse destination.tab.?.getActiveSurface(),
        );
        focus(.{ .window = destination.window, .tab = destination.tab, .surface = source.surface });
        return terminalValue(alloc, destination.window, destination.tab.?, source.surface.?);
    }
    if (eq(u8, method, "surface.refresh")) {
        var refreshed: i64 = 0;
        for (try windows(alloc)) |win| {
            if (try p.optionalString(params, "window_id")) |filter|
                if ((try find(alloc, "window_id", filter)).window != win) continue;
            const view = win.getTabView();
            var page_index: c_int = 0;
            while (page_index < view.getNPages()) : (page_index += 1) {
                const tab = gobject.ext.cast(Tab, view.getNthPage(page_index).getChild()) orelse continue;
                if (try p.optionalString(params, "workspace_id")) |filter|
                    if ((try find(alloc, "workspace_id", filter)).tab != tab) continue;
                if (tab.getSurfaceTree()) |tree| {
                    var it = tree.iterator();
                    while (it.next()) |entry| {
                        entry.view.redraw();
                        refreshed += 1;
                    }
                }
            }
        }
        return p.object(alloc, .{ .refreshed = p.integer(refreshed) });
    }
    if (eq(u8, method, "surface.health")) {
        const t = try target(alloc, params, "surface_id");
        var result = try terminalValue(alloc, t.window, t.tab.?, t.surface.?);
        try result.object.put("healthy", p.boolean(t.surface.?.core() != null));
        return result;
    }
    if (std.mem.startsWith(u8, method, "surface.report_") or
        std.mem.startsWith(u8, method, "surface.clear_") or
        std.mem.startsWith(u8, method, "surface.resume."))
    {
        const t = try resolvedMetadataTarget(alloc, params);
        const data = metadata((t.surface orelse return error.TargetNotFound).as(gobject.Object));
        if (eq(u8, method, "surface.report_git_branch")) {
            const branch = try p.string(params, "branch");
            if (!std.unicode.utf8ValidateSlice(branch)) return error.InvalidUTF8;
            const copy = try a.dupe(u8, branch);
            if (data.git_branch) |old| a.free(old);
            data.git_branch = copy;
            data.git_dirty = try boolParam(params, "dirty", false);
        } else if (eq(u8, method, "surface.clear_git_branch")) {
            if (data.git_branch) |old| a.free(old);
            data.git_branch = null;
            data.git_dirty = false;
        } else if (eq(u8, method, "surface.report_pr")) {
            const number = params.object.get("number") orelse return error.MissingParameter;
            if (number != .integer or number.integer <= 0) return error.InvalidPullRequest;
            const label = try p.string(params, "label");
            const url = try p.string(params, "url");
            const status = try p.string(params, "status");
            if (!inWords("open merged closed", status)) return error.InvalidPullRequest;
            if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidPullRequest;
            var transferred = false;
            const label_copy = try a.dupe(u8, label);
            errdefer if (!transferred) a.free(label_copy);
            const url_copy = try a.dupe(u8, url);
            errdefer if (!transferred) a.free(url_copy);
            const status_copy = try a.dupe(u8, status);
            errdefer if (!transferred) a.free(status_copy);
            const branch_copy = if (try p.optionalString(params, "branch")) |value| try a.dupe(u8, value) else null;
            errdefer if (!transferred) if (branch_copy) |value| a.free(value);
            const entry: PullRequestEntry = .{
                .number = number.integer,
                .label = label_copy,
                .url = url_copy,
                .status = status_copy,
                .branch = branch_copy,
            };
            if (data.pull_request) |old| old.deinit();
            data.pull_request = entry;
            transferred = true;
        } else if (eq(u8, method, "surface.clear_pr")) {
            if (data.pull_request) |old| old.deinit();
            data.pull_request = null;
        } else if (eq(u8, method, "surface.report_ports")) {
            const value = params.object.get("ports") orelse return error.MissingParameter;
            if (value != .array or value.array.items.len > 128) return error.InvalidPorts;
            var ports: std.ArrayList(u16) = .empty;
            errdefer ports.deinit(a);
            for (value.array.items) |port| {
                if (port != .integer or port.integer <= 0 or port.integer > 65535) return error.InvalidPorts;
                const narrowed: u16 = @intCast(port.integer);
                if (std.mem.indexOfScalar(u16, ports.items, narrowed) == null) try ports.append(a, narrowed);
            }
            data.listening_ports.deinit(a);
            data.listening_ports = ports;
        } else if (eq(u8, method, "surface.clear_ports")) {
            data.listening_ports.clearRetainingCapacity();
        } else if (eq(u8, method, "surface.resume.set")) {
            const command = try p.string(params, "command");
            if (command.len == 0 or command.len > 4096 or !std.unicode.utf8ValidateSlice(command))
                return error.InvalidText;
            if (data.resume_command) |old| a.free(old);
            data.resume_command = try a.dupe(u8, command);
        } else if (eq(u8, method, "surface.resume.show")) {
            return try p.object(alloc, .{
                .command = if (data.resume_command) |command| p.str(command) else .null,
                .tmux_session = if (data.tmux_session) |session| p.str(session) else .null,
            });
        } else if (eq(u8, method, "surface.resume.clear")) {
            if (data.resume_command) |old| a.free(old);
            data.resume_command = null;
        } else return error.UnknownMethod;

        refreshActivities();
        return telemetryValue(alloc, data);
    }
    if (eq(u8, method, "terminal.create")) {
        const t = try target(alloc, params, "workspace_id");
        const tab = t.tab.?;
        try tab.getSplitTree().newSplit(.right, null, .{ .working_directory = try directory(alloc, params) });
        const created = tab.getActiveSurface().?;
        try scheduleInitialInput(created, params);
        return terminalValue(alloc, t.window, tab, created);
    }
    if (std.mem.startsWith(u8, method, "terminal.")) {
        const t = try target(alloc, params, "terminal_id");
        const surface = t.surface.?;
        if (eq(u8, method, "terminal.focus")) {
            focus(t);
            return .null;
        }
        if (eq(u8, method, "terminal.rename")) {
            surface.setTitleOverride(try alloc.dupeZ(u8, try p.string(params, "name")));
            return .null;
        }
        if (eq(u8, method, "terminal.close")) {
            try requiredForce(params);
            try t.tab.?.getSplitTree().automationClose(surface);
            return .null;
        }
        const core = surface.core() orelse return error.TerminalNotReady;
        if (eq(u8, method, "terminal.send-text")) {
            const text = try p.string(params, "text");
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUTF8;
            try core.textCallback(text);
            return .null;
        }
        if (eq(u8, method, "terminal.send-key")) {
            const name = try p.string(params, "key");
            const key = std.meta.stringToEnum(input.Key, name) orelse return error.UnknownKey;
            var mods: input.Mods = .{};
            if (params.object.get("ctrl")) |value| {
                if (value != .bool) return error.InvalidParams;
                mods.ctrl = value.bool;
            }
            if (params.object.get("alt")) |value| {
                if (value != .bool) return error.InvalidParams;
                mods.alt = value.bool;
            }
            if (params.object.get("shift")) |value| {
                if (value != .bool) return error.InvalidParams;
                mods.shift = value.bool;
            }
            const text = try p.optionalString(params, "text") orelse "";
            try core.automationKey(.{ .key = key, .mods = mods, .utf8 = text, .action = .press });
            try core.automationKey(.{ .key = key, .mods = mods, .utf8 = text, .action = .release });
            return .null;
        }
        if (eq(u8, method, "terminal.read")) {
            core.renderer_state.mutex.lock();
            defer core.renderer_state.mutex.unlock();
            const screen = core.io.terminal.screens.active;
            const text = try screen.dumpStringAlloc(alloc, .{ .screen = .{} });
            return p.object(alloc, .{ .terminal_id = p.str(id(surface)), .text = p.str(text), .columns = p.integer(screen.pages.cols), .rows = p.integer(screen.pages.rows) });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "notification.")) {
        if (eq(u8, method, "notification.create")) {
            return appendNotification(alloc, try resolvedMetadataTarget(alloc, params), params);
        }
        if (eq(u8, method, "notification.list")) {
            var values: std.array_list.Managed(p.Value) = .init(alloc);
            var index = notifications.items.len;
            while (index > 0) {
                index -= 1;
                if (try notificationMatches(alloc, &notifications.items[index], params))
                    try values.append(try notificationValue(alloc, &notifications.items[index]));
            }
            return .{ .array = values };
        }
        if (eq(u8, method, "notification.dismiss")) {
            var removed: i64 = 0;
            if (try p.optionalString(params, "notification_id")) |notification_id| {
                const index = notificationIndex(notification_id) orelse return error.TargetNotFound;
                notifications.orderedRemove(index).deinit();
                removed = 1;
            } else if (try boolParam(params, "all_read", false)) {
                var index = notifications.items.len;
                while (index > 0) {
                    index -= 1;
                    if (!notifications.items[index].read) continue;
                    notifications.orderedRemove(index).deinit();
                    removed += 1;
                }
            } else return error.MissingParameter;
            refreshActivities();
            return p.object(alloc, .{ .removed = p.integer(removed) });
        }
        if (eq(u8, method, "notification.mark-read")) {
            var marked: i64 = 0;
            if (try p.optionalString(params, "notification_id")) |notification_id| {
                const index = notificationIndex(notification_id) orelse return error.TargetNotFound;
                if (!notifications.items[index].read) marked = 1;
                notifications.items[index].read = true;
            } else {
                for (notifications.items) |*item| {
                    if (!try notificationMatches(alloc, item, params) or item.read) continue;
                    item.read = true;
                    marked += 1;
                }
            }
            refreshActivities();
            return p.object(alloc, .{ .marked = p.integer(marked) });
        }
        if (eq(u8, method, "notification.open")) {
            const notification_id = try p.string(params, "notification_id");
            if (!openActivity(notification_id)) return error.TargetNotFound;
            const index = notificationIndex(notification_id) orelse return error.TargetNotFound;
            return notificationValue(alloc, &notifications.items[index]);
        }
        if (eq(u8, method, "notification.jump-unread")) {
            var index = notifications.items.len;
            while (index > 0) {
                index -= 1;
                const item = &notifications.items[index];
                if (item.read or !try notificationMatches(alloc, item, params)) continue;
                if (!openActivity(&item.id)) return error.TargetNotFound;
                return notificationValue(alloc, item);
            }
            return error.TargetNotFound;
        }
        if (eq(u8, method, "notification.mark-oldest-unread")) {
            if (!markOldestUnreadAndJumpNext()) return error.TargetNotFound;
            var index = notifications.items.len;
            while (index > 0) {
                index -= 1;
                const item = &notifications.items[index];
                if (item.read) continue;
                return notificationValue(alloc, item);
            }
            return .null;
        }
        if (eq(u8, method, "notification.clear")) {
            var removed: i64 = 0;
            var index = notifications.items.len;
            while (index > 0) {
                index -= 1;
                if (!try notificationMatches(alloc, &notifications.items[index], params)) continue;
                notifications.orderedRemove(index).deinit();
                removed += 1;
            }
            refreshActivities();
            return p.object(alloc, .{ .removed = p.integer(removed) });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "status.") or eq(u8, method, "agent.hook")) {
        const t = try resolvedMetadataTarget(alloc, params);
        const data = targetMetadata(t);
        if (eq(u8, method, "status.set") or eq(u8, method, "agent.hook")) {
            if (try p.optionalString(params, "directory")) |cwd| {
                if (metadata(t.tab.?.as(gobject.Object)).remote == null) return error.NotRemoteWorkspace;
                try setRemoteDirectory(t.surface orelse return error.MissingParameter, cwd);
            }
            const field = if (eq(u8, method, "agent.hook")) "event" else "text";
            if (try p.optionalString(params, field)) |text| {
                if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUTF8;
                const key = (try p.optionalString(params, "key")) orelse
                    if (eq(u8, method, "agent.hook")) "agent" else "default";
                var found: ?usize = null;
                for (data.statuses.items, 0..) |entry, index|
                    if (eq(u8, entry.key, key)) {
                        found = index;
                        break;
                    };
                var transferred = false;
                const key_copy = try a.dupe(u8, key);
                errdefer if (!transferred) a.free(key_copy);
                const text_copy = try a.dupe(u8, text);
                errdefer if (!transferred) a.free(text_copy);
                const icon_copy = if (try p.optionalString(params, "icon")) |value| try a.dupe(u8, value) else null;
                errdefer if (!transferred) if (icon_copy) |value| a.free(value);
                const color_copy = if (try p.optionalString(params, "color")) |value| try a.dupe(u8, value) else null;
                errdefer if (!transferred) if (color_copy) |value| a.free(value);
                const entry: StatusEntry = .{
                    .key = key_copy,
                    .text = text_copy,
                    .icon = icon_copy,
                    .color = color_copy,
                    .updated_at = std.time.milliTimestamp(),
                };
                if (found) |index| {
                    data.statuses.items[index].deinit();
                    data.statuses.items[index] = entry;
                } else {
                    if (data.statuses.items.len == 32) data.statuses.orderedRemove(0).deinit();
                    try data.statuses.append(a, entry);
                }
                transferred = true;
            } else if (!params.object.contains("directory")) return error.MissingParameter;
        } else if (eq(u8, method, "status.clear")) {
            if (try p.optionalString(params, "key")) |key| {
                for (data.statuses.items, 0..) |entry, index| if (eq(u8, entry.key, key)) {
                    data.statuses.orderedRemove(index).deinit();
                    break;
                };
            } else {
                for (data.statuses.items) |entry| entry.deinit();
                data.statuses.clearRetainingCapacity();
            }
        } else if (!eq(u8, method, "status.list") and !eq(u8, method, "status.get")) return error.UnknownMethod;
        if (!eq(u8, method, "status.list") and !eq(u8, method, "status.get")) refreshActivities();
        var values: std.array_list.Managed(p.Value) = .init(alloc);
        for (data.statuses.items) |*entry| try values.append(try statusValue(alloc, entry));
        return .{ .array = values };
    }
    if (eq(u8, method, "progress.set") or eq(u8, method, "progress.clear")) {
        const t = try resolvedMetadataTarget(alloc, params);
        const data = targetMetadata(t);
        if (eq(u8, method, "progress.clear")) {
            data.progress = null;
        } else {
            const value = params.object.get("value") orelse return error.MissingParameter;
            if (value == .null) {
                data.progress = null;
            } else {
                if (value != .integer or value.integer < 0 or value.integer > 100) return error.InvalidProgress;
                data.progress = value.integer;
            }
        }
        if (data.progress_label) |value| a.free(value);
        data.progress_label = if (try p.optionalString(params, "label")) |value| try a.dupe(u8, value) else null;
        const surface = t.surface orelse t.tab.?.getActiveSurface() orelse return error.TargetNotFound;
        surface.setProgressReport(.{
            .state = if (data.progress == null) .remove else .set,
            .progress = if (data.progress) |value| @intCast(value) else null,
        });
        refreshActivities();
        return p.object(alloc, .{
            .value = if (data.progress) |value| p.integer(value) else .null,
            .label = if (data.progress_label) |value| p.str(value) else .null,
        });
    }
    if (std.mem.startsWith(u8, method, "log.")) {
        const t = try resolvedMetadataTarget(alloc, params);
        const data = targetMetadata(t);
        if (eq(u8, method, "log.append")) {
            const text = try p.string(params, "text");
            const level = (try p.optionalString(params, "level")) orelse "info";
            if (!inWords("trace debug info warn error", level)) return error.InvalidLogLevel;
            if (data.logs.items.len == 256) data.logs.orderedRemove(0).deinit();
            var transferred = false;
            const text_copy = try a.dupe(u8, text);
            errdefer if (!transferred) a.free(text_copy);
            const level_copy = try a.dupe(u8, level);
            errdefer if (!transferred) a.free(level_copy);
            try data.logs.append(a, .{
                .id = randomId(),
                .text = text_copy,
                .level = level_copy,
                .created_at = std.time.milliTimestamp(),
            });
            transferred = true;
        } else if (eq(u8, method, "log.clear")) {
            for (data.logs.items) |entry| entry.deinit();
            data.logs.clearRetainingCapacity();
        } else if (!eq(u8, method, "log.list")) return error.UnknownMethod;
        if (!eq(u8, method, "log.list")) refreshActivities();
        var values: std.array_list.Managed(p.Value) = .init(alloc);
        for (data.logs.items) |*entry| try values.append(try logValue(alloc, entry));
        return .{ .array = values };
    }
    if (std.mem.startsWith(u8, method, "sidebar.")) {
        const win = if (try p.optionalString(params, "workspace_id")) |value|
            (try find(alloc, "workspace_id", value)).window
        else if (try p.optionalString(params, "window_id")) |value|
            (try find(alloc, "window_id", value)).window
        else
            try currentWindow(alloc);
        if (eq(u8, method, "sidebar.toggle")) {
            win.setRightSidebarVisible(!win.rightSidebarVisible());
        } else if (eq(u8, method, "sidebar.show")) {
            win.setRightSidebarVisible(true);
        } else if (eq(u8, method, "sidebar.hide")) {
            win.setRightSidebarVisible(false);
        } else if (eq(u8, method, "sidebar.focus")) {
            win.setRightSidebarVisible(true);
            win.focusRightSidebar();
        } else if (eq(u8, method, "sidebar.set") or
            inWords("sidebar.files sidebar.find sidebar.vault sidebar.sessions sidebar.feed sidebar.dock sidebar.machines", method))
        {
            const mode_name = if (eq(u8, method, "sidebar.set"))
                try p.string(params, "mode")
            else
                method["sidebar.".len..];
            const mode = std.meta.stringToEnum(Window.SidebarMode, mode_name) orelse return error.InvalidSidebarMode;
            win.setRightSidebarMode(mode, !try boolParam(params, "no_focus", false));
        } else if (!eq(u8, method, "sidebar.mode") and !eq(u8, method, "sidebar.state")) {
            return error.UnknownMethod;
        }
        var result = try p.object(alloc, .{
            .panel_mapped = p.boolean(win.rightSidebarPanelMapped()),
            .panel_width = p.integer(win.rightSidebarPanelWidth()),
            .panel_x = p.integer(win.rightSidebarPanelX()),
            .collapsed = p.boolean(win.rightSidebarCollapsed()),
            .visible = p.boolean(win.rightSidebarVisible()),
            .mode = p.str(@tagName(win.rightSidebarMode())),
        });
        if (eq(u8, method, "sidebar.state")) {
            const t = try resolvedMetadataTarget(alloc, params);
            const data = targetMetadata(t);
            var statuses: std.array_list.Managed(p.Value) = .init(alloc);
            for (data.statuses.items) |*entry| try statuses.append(try statusValue(alloc, entry));
            var logs: std.array_list.Managed(p.Value) = .init(alloc);
            for (data.logs.items) |*entry| try logs.append(try logValue(alloc, entry));
            try result.object.put("statuses", .{ .array = statuses });
            try result.object.put("progress", if (data.progress) |value| p.integer(value) else .null);
            try result.object.put("progress_label", if (data.progress_label) |value| p.str(value) else .null);
            try result.object.put("logs", .{ .array = logs });
            const telemetry = try telemetryValue(alloc, data);
            try result.object.put("git_branch", telemetry.object.get("git_branch").?);
            try result.object.put("git_dirty", telemetry.object.get("git_dirty").?);
            try result.object.put("pull_request", telemetry.object.get("pull_request").?);
            try result.object.put("listening_ports", telemetry.object.get("listening_ports").?);
        }
        return result;
    }
    if (eq(u8, method, "agent.tmux-shim-install")) {
        const path = try agent_store.installTmuxShim(alloc);
        return try p.object(alloc, .{ .path = p.str(path), .installed = p.boolean(true) });
    }
    if (eq(u8, method, "agent.tmux-shim-uninstall")) {
        try agent_store.uninstallTmuxShim(alloc);
        return try p.object(alloc, .{ .installed = p.boolean(false) });
    }
    if (eq(u8, method, "agent.launch")) {
        const provider = try p.string(params, "provider");
        const command = try agent_store.launchCommand(
            alloc,
            provider,
            try p.optionalString(params, "resume"),
            try p.optionalString(params, "team"),
            try p.optionalString(params, "prompt"),
        );
        if (try boolParam(params, "dry_run", false))
            return try p.object(alloc, .{
                .provider = p.str(provider),
                .command = p.str(command),
            });
        const new_pane = try boolParam(params, "new_pane", false);
        if (new_pane) {
            const t = try target(alloc, params, "workspace_id");
            const tab = t.tab.?;
            try tab.getSplitTree().newSplit(.right, null, .{ .working_directory = try directory(alloc, params) });
            const created = tab.getActiveSurface().?;
            try PendingInput.start(created, command);
            var result = try terminalValue(alloc, t.window, tab, created);
            try result.object.put("provider", p.str(provider));
            return result;
        }
        const t = try target(alloc, params, "terminal_id");
        const core = t.surface.?.core() orelse return error.TerminalNotReady;
        try core.textCallback(command);
        try core.textCallback("\r");
        return try p.object(alloc, .{
            .provider = p.str(provider),
            .command = p.str(command),
            .terminal_id = p.str(id(t.surface.?)),
        });
    }
    if (eq(u8, method, "agent.detect")) {
        const t = try target(alloc, params, "terminal_id");
        scanAgentArgv(t.surface.?);
        const detected = try agent_store.detectForTerminal(alloc, id(t.surface.?));
        const found = detected orelse return try p.object(alloc, .{ .detected = p.boolean(false) });
        return try p.object(alloc, .{
            .detected = p.boolean(true),
            .provider = p.str(found.provider),
            .session_id = if (found.session_id) |value| p.str(value) else .null,
            .tmux_session = if (found.tmux_session) |value| p.str(value) else .null,
        });
    }
    if (eq(u8, method, "agent.fork")) {
        const t = try target(alloc, params, "terminal_id");
        scanAgentArgv(t.surface.?);
        const detected = try agent_store.detectForTerminal(alloc, id(t.surface.?));
        var provider: []const u8 = (try p.optionalString(params, "provider")) orelse "claude";
        var session_id: ?[]const u8 = try p.optionalString(params, "resume");
        if (detected) |found| {
            if (found.provider.len > 0) provider = found.provider;
            if (session_id == null) session_id = found.session_id;
        }
        const cwd = try directory(alloc, params) orelse localDirectory(t.surface.?);
        const tab = t.window.automationNewTab(null, cwd);
        if (t.tab) |old| {
            if (workspaceGroup(old)) |group| assignWorkspaceGroup(tab, group.key, group.name);
        }
        tab.setTitleOverride(try alloc.dupeZ(u8, "Fork"));
        const command = try agent_store.launchCommand(alloc, provider, session_id, null, try p.optionalString(params, "prompt"));
        if (tab.getActiveSurface()) |created| try PendingInput.start(created, command);
        var result = try workspaceValue(alloc, t.window, tab);
        try result.object.put("provider", p.str(provider));
        try result.object.put("command", p.str(command));
        return result;
    }

    if (std.mem.startsWith(u8, method, "agent.hooks") or eq(u8, method, "agent.session-capture") or eq(u8, method, "agent.sessions")) {
        if (eq(u8, method, "agent.hooks")) return agent_store.hookStatus(alloc);
        if (eq(u8, method, "agent.sessions")) return agent_store.listSessions(alloc);
        if (eq(u8, method, "agent.session-capture")) {
            const t = resolvedMetadataTarget(alloc, params) catch Target{ .window = try currentWindow(alloc), .tab = null, .surface = null };
            try agent_store.captureSession(alloc, .{
                .provider = (try p.optionalString(params, "provider")) orelse "agent",
                .session_id = try p.string(params, "session_id"),
                .workspace_id = if (t.tab) |tab| id(tab) else "",
                .surface_id = if (t.surface) |surface| id(surface) else "",
                .cwd = if (t.surface) |surface| localDirectory(surface) else null,
            });
            return try p.object(alloc, .{
                .provider = p.str((try p.optionalString(params, "provider")) orelse "agent"),
                .session_id = p.str(try p.string(params, "session_id")),
            });
        }
        if (eq(u8, method, "agent.hooks-install")) {
            if (try p.optionalString(params, "provider")) |provider| {
                if (!eq(u8, provider, "all")) {
                    const path = try agent_store.installHook(alloc, provider);
                    return try p.object(alloc, .{
                        .provider = p.str(provider),
                        .path = p.str(path),
                        .installed = p.boolean(true),
                    });
                }
            }
            return agent_store.installAllHooks(alloc);
        }
        if (eq(u8, method, "agent.hooks-uninstall")) {
            const provider = try p.string(params, "provider");
            try agent_store.uninstallHook(alloc, provider);
            return try p.object(alloc, .{
                .provider = p.str(provider),
                .installed = p.boolean(false),
            });
        }
        return error.UnknownMethod;
    }
    if (std.mem.startsWith(u8, method, "prompt.") or std.mem.startsWith(u8, method, "rule.")) {
        const kind: agent_store.Kind = if (std.mem.startsWith(u8, method, "prompt.")) .prompt else .rule;
        const action = method[std.mem.indexOfScalar(u8, method, '.').? + 1 ..];
        if (eq(u8, action, "list")) return agent_store.list(alloc, kind);
        const name = try p.string(params, "name");
        if (eq(u8, action, "set")) {
            const text = try p.string(params, "text");
            try agent_store.set(alloc, kind, name, text);
            return try p.object(alloc, .{ .name = p.str(name), .text = p.str(text) });
        }
        if (eq(u8, action, "delete")) {
            try agent_store.remove(alloc, kind, name);
            return .null;
        }
        const text = try agent_store.get(alloc, kind, name);
        if (eq(u8, action, "get"))
            return try p.object(alloc, .{ .name = p.str(name), .text = p.str(text) });
        if (!eq(u8, action, "run")) return error.UnknownMethod;
        const t = try target(alloc, params, "terminal_id");
        const core = t.surface.?.core() orelse return error.TerminalNotReady;
        try core.textCallback(text);
        const submit = try boolParam(params, "submit", false);
        if (submit) try core.textCallback("\r");
        return try p.object(alloc, .{
            .name = p.str(name),
            .text = p.str(text),
            .submitted = p.boolean(submit),
            .terminal_id = p.str(id(t.surface.?)),
        });
    }
    return error.UnknownMethod;
}

fn authorize(alloc: std.mem.Allocator, request: p.Value, method: []const u8, params: p.Value) !void {
    if (std.posix.getenv("CMUX_SOCKET_PASSWORD")) |expected| {
        const supplied = (try p.optionalString(request, "password")) orelse return error.Unauthorized;
        if (supplied.len != expected.len) return error.Unauthorized;
        var difference: u8 = 0;
        for (supplied, expected) |left, right| difference |= left ^ right;
        if (difference != 0) return error.Unauthorized;
    }
    const capability = try p.optionalString(request, "capability") orelse return;
    if (!inWords(
        "notification.create status.set status.clear progress.set progress.clear log.append log.clear agent.hook surface.report_git_branch surface.clear_git_branch surface.report_pr surface.clear_pr surface.report_ports surface.clear_ports",
        method,
    )) return error.Unauthorized;
    const t = try resolvedMetadataTarget(alloc, params);
    const remote = metadata(t.tab.?.as(gobject.Object)).remote orelse return error.Unauthorized;
    if (capability.len != remote.capability.len or !std.crypto.timing_safe.eql([64]u8, capability[0..64].*, remote.capability)) return error.Unauthorized;
}

fn dispatchAsync(alloc: std.mem.Allocator, request: p.Value, ctx: *anyopaque, callback: p.Callback) !?p.Value {
    const method = try p.string(request, "method");
    const params = request.object.get("params") orelse return error.MissingParameter;
    if (params != .object) return error.InvalidParams;
    try authorize(alloc, request, method, params);
    if (eq(u8, method, "window.close")) {
        try requiredForce(params);
        const t = try target(alloc, params, "window_id");
        const ids = try remoteWorkspaces(alloc, t.window);
        if (ids.array.items.len > 0) {
            var remote_params = params;
            try remote_params.object.put("workspace_ids", ids);
            try RemoteJob.start(alloc, "close-window", remote_params, ctx, callback);
            return null;
        }
    }
    if (std.mem.startsWith(u8, method, "browser.")) {
        const t = try target(alloc, params, "workspace_id");
        const data = metadata(t.tab.?.as(gobject.Object));
        if (eq(u8, method, "browser.create")) {
            browser.spawnColumn = spawnColumnFromPane;

            const pane_id = randomId();
            const profile = try p.optionalString(params, "profile");
            const pane = try browser.create(
                a,
                t.tab.?.as(gtk.Box),
                t.tab.?.getSplitTree(),
                &pane_id,
                if (data.remote) |r| r.proxy else null,
                profile,
                if (data.remote) |r| r.host else "local",
            );

            errdefer pane.destroy();
            try data.browsers.append(a, pane);
            return try p.object(alloc, .{
                .browser_id = p.str(pane.id),
                .workspace_id = p.str(id(t.tab.?)),
                .profile = p.str(pane.session.profile orelse "ephemeral"),
            });
        }
        if (eq(u8, method, "browser.list")) {
            var list: std.array_list.Managed(p.Value) = .init(alloc);
            for (data.browsers.items) |pane| if (!pane.disposed) {
                try list.append(try p.object(alloc, .{
                    .browser_id = p.str(pane.id),
                    .workspace_id = p.str(id(t.tab.?)),
                    .profile = p.str(pane.session.profile orelse "ephemeral"),
                }));
            };
            return .{ .array = list };
        }
        const pane_id = try p.string(params, "browser_id");
        for (data.browsers.items, 0..) |pane, index| {
            if (!eq(u8, pane.id, pane_id) or pane.disposed) continue;
            if (eq(u8, method, "browser.close")) {
                _ = data.browsers.orderedRemove(index);
                pane.destroy();
                return p.Value.null;
            }
            if (eq(u8, method, "browser.focus")) {
                if (!pane.focus()) return error.FocusFailed;
                return try pane.status(alloc);
            }
            browser.dispatch(pane, alloc, method, params, ctx, callback);
            return null;
        }
        return error.TargetNotFound;
    }
    if (eq(u8, method, "ssh.create")) {
        const workspace_id = randomId();
        const terminal_id = randomId();
        var bytes: [32]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        const capability = std.fmt.bytesToHex(bytes, .lower);
        var remote_params = params;
        try remote_params.object.put("workspace_id", p.str(try alloc.dupe(u8, &workspace_id)));
        try remote_params.object.put("terminal_id", p.str(try alloc.dupe(u8, &terminal_id)));
        try remote_params.object.put("capability", p.str(try alloc.dupe(u8, &capability)));
        try remote_params.object.put("endpoint", p.str(try @import("control.zig").socketPath(alloc)));
        if (remote_params.object.get("terminal_profile") == null)
            try remote_params.object.put("terminal_profile", p.str("tmux"));
        try RemoteJob.start(alloc, "prepare", remote_params, ctx, callback);
        return null;
    }
    if (std.mem.startsWith(u8, method, "ssh.")) {
        const t = try target(alloc, params, "workspace_id");
        if (metadata(t.tab.?.as(gobject.Object)).remote == null) return error.NotRemoteWorkspace;
        var remote_params = params;
        try remote_params.object.put("workspace_id", p.str(try alloc.dupe(u8, id(t.tab.?))));
        if (try p.optionalString(params, "terminal_id")) |terminal_id| {
            if (find(alloc, "terminal_id", terminal_id)) |terminal_target|
                try remote_params.object.put("terminal_id", p.str(try alloc.dupe(u8, id(terminal_target.surface.?))))
            else |_| {}
        }
        const operation = method[4..];
        if (!inWords("status upload download disconnect reconnect session-list session-attach session-cleanup", operation)) return error.UnknownMethod;
        if (eq(u8, operation, "session-cleanup")) {
            try requiredForce(params);
            const terminal = params.object.contains("terminal_id");
            const all = if (params.object.get("all")) |value| value == .bool and value.bool else false;
            if (!terminal and !all) return error.MissingParameter;
            if (terminal and all) return error.InvalidParams;
        }
        if (eq(u8, operation, "session-attach")) {
            const terminal_id = try p.string(params, "terminal_id");
            _ = find(alloc, "terminal_id", terminal_id) catch |err| switch (err) {
                error.TargetNotFound => {
                    try RemoteJob.start(alloc, operation, remote_params, ctx, callback);
                    return null;
                },
                else => return err,
            };
            return error.AlreadyAttached;
        }
        try RemoteJob.start(alloc, operation, remote_params, ctx, callback);
        return null;
    }
    if (eq(u8, method, "terminal.create") or eq(u8, method, "terminal.close") or eq(u8, method, "workspace.close")) {
        if (!eq(u8, method, "terminal.create")) try requiredForce(params);
        const t = try target(alloc, params, if (eq(u8, method, "terminal.close")) "terminal_id" else "workspace_id");
        if (metadata(t.tab.?.as(gobject.Object)).remote != null) {
            var remote_params = params;
            try remote_params.object.put("workspace_id", p.str(try alloc.dupe(u8, id(t.tab.?))));
            if (eq(u8, method, "terminal.create")) {
                const terminal_id = randomId();
                try remote_params.object.put("terminal_id", p.str(try alloc.dupe(u8, &terminal_id)));
            }
            try RemoteJob.start(alloc, if (eq(u8, method, "terminal.create")) "terminal" else if (eq(u8, method, "terminal.close")) "close-terminal" else "close", remote_params, ctx, callback);
            return null;
        }
    }
    return try handle(alloc, request);
}

/// SSH handshakes, uploads and helper installation never block the GTK thread.
const RemoteJob = struct {
    alloc: std.mem.Allocator,
    method: []const u8,
    params: p.Value,
    ctx: *anyopaque,
    callback: p.Callback,
    result: ?p.Value = null,
    failure: ?[]const u8 = null,
    fn start(alloc: std.mem.Allocator, method: []const u8, params: p.Value, ctx: *anyopaque, callback: p.Callback) !void {
        const job = try a.create(RemoteJob);
        errdefer a.destroy(job);
        job.* = .{ .alloc = alloc, .method = method, .params = params, .ctx = ctx, .callback = callback };
        const thread = try std.Thread.spawn(.{}, work, .{job});
        thread.detach();
    }
    fn work(self: *RemoteJob) void {
        self.run() catch |err| {
            self.failure = @errorName(err);
        };
        _ = glib.idleAdd(finish, self);
    }
    fn run(self: *RemoteJob) !void {
        if (eq(u8, self.method, "close-window")) {
            for (self.params.object.get("workspace_ids").?.array.items) |workspace_id| {
                try self.runOperation("close", try p.object(self.alloc, .{ .workspace_id = workspace_id }));
                if (self.failure != null) return;
            }
            self.result = .null;
            return;
        }
        try self.runOperation(self.method, self.params);
    }
    fn runOperation(self: *RemoteJob, method: []const u8, params: p.Value) !void {
        const executable = try std.fs.selfExeDirPathAlloc(self.alloc);
        const manager = try std.fs.path.join(self.alloc, &.{ executable, "..", "share", "colm", "remote", "manager.py" });
        const request = try std.json.Stringify.valueAlloc(self.alloc, try p.object(self.alloc, .{ .method = p.str(method), .params = params }), .{});
        const output = try std.process.Child.run(.{ .allocator = self.alloc, .argv = &.{ "python3", manager, request }, .max_output_bytes = 4 * 1024 * 1024 });
        const parsed = try std.json.parseFromSlice(p.Value, self.alloc, output.stdout, .{ .allocate = .alloc_always });
        if (parsed.value != .object) return error.InvalidHelperResponse;
        const ok = parsed.value.object.get("ok") orelse return error.InvalidHelperResponse;
        if (ok != .bool) return error.InvalidHelperResponse;
        if (!ok.bool) {
            const err = parsed.value.object.get("error") orelse return error.RemoteFailure;
            self.failure = try p.string(err, "message");
            return;
        }
        self.result = parsed.value.object.get("result") orelse return error.InvalidHelperResponse;
    }
    fn finish(ptr: ?*anyopaque) callconv(.c) c_int {
        const self: *RemoteJob = @ptrCast(@alignCast(ptr.?));
        defer a.destroy(self);
        if (self.failure) |failure| {
            self.callback(self.ctx, .{ .err = failure });
            return 0;
        }
        const result = self.apply() catch |err| {
            if (eq(u8, self.method, "prepare") or eq(u8, self.method, "terminal")) {
                self.cleanupCreation() catch |cleanup_err| std.log.err("remote creation cleanup: {s}", .{@errorName(cleanup_err)});
            }
            self.callback(self.ctx, .{ .err = @errorName(err) });
            return 0;
        };
        self.callback(self.ctx, .{ .ok = result });
        return 0;
    }
    fn cleanupCreation(self: *RemoteJob) !void {
        const owner = try a.create(UiRequest);
        owner.* = .{ .arena = .init(a) };
        errdefer {
            owner.arena.deinit();
            a.destroy(owner);
        }
        const alloc = owner.arena.allocator();
        var params = try p.object(alloc, .{ .workspace_id = p.str(try alloc.dupe(u8, try p.string(self.params, "workspace_id"))) });
        const terminal = eq(u8, self.method, "terminal");
        if (terminal) try params.object.put("terminal_id", p.str(try alloc.dupe(u8, try p.string(self.params, "terminal_id"))));
        try RemoteJob.start(alloc, if (terminal) "close-terminal" else "close", params, owner, UiRequest.complete);
    }
    fn apply(self: *RemoteJob) !p.Value {
        const result = self.result.?;
        const alloc = self.alloc;
        if (eq(u8, self.method, "close-window")) {
            const t = try target(alloc, self.params, "window_id");
            for (self.params.object.get("workspace_ids").?.array.items) |workspace_id| {
                const workspace = find(alloc, "workspace_id", workspace_id.string) catch continue;
                metadata(workspace.tab.?.as(gobject.Object)).remote_closed = true;
            }
            t.window.as(gtk.Window).destroy();
            return .null;
        }
        if (eq(u8, self.method, "prepare")) {
            const win = if (try p.optionalString(self.params, "window_id")) |value| (try find(alloc, "window_id", value)).window else Window.new(Application.default(), .{});
            creating_workspace = try p.string(self.params, "workspace_id");
            creating_terminal = try p.string(self.params, "terminal_id");
            defer {
                creating_workspace = null;
                creating_terminal = null;
            }
            const tab = win.automationNewTab(.{ .shell = try alloc.dupeZ(u8, try p.string(result, "command")) }, null);
            const data = metadata(tab.as(gobject.Object));
            const capability = try p.string(self.params, "capability");
            data.remote = .{
                .host = try a.dupe(u8, try p.string(self.params, "host")),
                .cwd = try a.dupe(u8, (try p.optionalString(self.params, "cwd")) orelse "~"),
                .proxy = try a.dupe(u8, try p.string(result, "proxy_uri")),
                .capability = capability[0..64].*,
                .terminal_transport = try a.dupe(u8, try p.string(result, "effective_terminal_transport")),
                .terminal_profile = try a.dupe(u8, try p.string(result, "terminal_profile")),
                .tmux_session = if (try p.optionalString(result, "terminal_tmux_session")) |value| try a.dupe(u8, value) else null,
            };
            try setRemoteDirectory(tab.getActiveSurface().?, try p.string(result.object.get("terminal") orelse return error.InvalidHelperResponse, "cwd"));
            tab.setTitleOverride(try alloc.dupeZ(u8, (try p.optionalString(self.params, "name")) orelse data.remote.?.host));
            win.as(gtk.Window).present();
            return p.object(alloc, .{ .workspace = try workspaceValue(alloc, win, tab), .terminal = try terminalValue(alloc, win, tab, tab.getActiveSurface().?) });
        }
        const t = target(alloc, self.params, "workspace_id") catch |err| {
            if (eq(u8, self.method, "close") and err == error.TargetNotFound) return result;
            return err;
        };
        if (eq(u8, self.method, "terminal") or eq(u8, self.method, "session-attach")) {
            creating_terminal = try p.string(self.params, "terminal_id");
            defer creating_terminal = null;
            try t.tab.?.getSplitTree().newSplit(.right, null, .{ .command = .{ .shell = try alloc.dupeZ(u8, try p.string(result, "command")) } });
            try setRemoteDirectory(t.tab.?.getActiveSurface().?, try p.string(result.object.get("terminal") orelse return error.InvalidHelperResponse, "cwd"));
            return terminalValue(alloc, t.window, t.tab.?, t.tab.?.getActiveSurface().?);
        }
        if (eq(u8, self.method, "close-terminal")) {
            const terminal = try target(alloc, self.params, "terminal_id");
            closing_remote = true;
            defer closing_remote = false;
            try terminal.tab.?.getSplitTree().automationClose(terminal.surface.?);
        } else if (eq(u8, self.method, "close")) {
            metadata(t.tab.?.as(gobject.Object)).remote_closed = true;
            t.window.automationCloseTab(t.tab.?);
        }
        return result;
    }
};

test "notification surface identifier serializes as stable string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const previous_format = output_id_format;
    output_id_format = .uuids;
    defer output_id_format = previous_format;
    const item: NotificationRecord = .{
        .id = "00000000000000000000000000000000".*,
        .window_id = "11111111111111111111111111111111".*,
        .surface_id = "33333333333333333333333333333333".*,
        .workspace_id = "22222222222222222222222222222222".*,
        .title = "Done",
        .body = "Ready",
        .subtitle = "Build",
        .level = "info",
        .tab_title = "Workspace",
        .category = "turn-complete",
        .created_at = 1,
    };

    const value = try notificationValue(alloc, &item);
    const json = try std.json.Stringify.valueAlloc(alloc, value, .{});
    try std.testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"surface_id\":\"33333333333333333333333333333333\"",
    ) != null);
}
