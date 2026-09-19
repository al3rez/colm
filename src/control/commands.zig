const std = @import("std");
const p = @import("protocol.zig");
const Allocator = std.mem.Allocator;

pub const Parsed = struct {
    request: p.Value = .null,
    socket: ?[]const u8 = null,
    password: ?[]const u8 = null,
    id_format: []const u8 = "refs",
    help: bool = false,
    help_command: ?[]const u8 = null,
    version: bool = false,
    json: bool = false,
    endpoints: bool = false,
    open_path: ?[]const u8 = null,
    ambient_targets: bool = true,
};

const Command = struct {
    name: []const u8,
    method: []const u8,
    positional: []const u8 = "",
    fields: []const u8 = "",
    required: []const u8 = "",
};

const commands = [_]Command{
    .{ .name = "ping", .method = "system.ping" },
    .{ .name = "capabilities", .method = "system.capabilities" },
    .{ .name = "identify", .method = "system.identify" },
    .{ .name = "ssh", .method = "ssh.create", .positional = "host", .fields = "host name cwd command port identity ssh_config forward_agent no_forward_agent transport profile session window_id", .required = "host" },
    .{ .name = "mosh", .method = "ssh.create", .positional = "host", .fields = "host name cwd command port identity ssh_config forward_agent no_forward_agent transport profile session window_id", .required = "host" },
    .{ .name = "mosh-tmux", .method = "ssh.create", .positional = "host", .fields = "host name cwd command port identity ssh_config forward_agent no_forward_agent transport profile session window_id", .required = "host" },
    .{ .name = "ssh-status", .method = "ssh.status", .fields = "workspace_id" },
    .{ .name = "ssh-disconnect", .method = "ssh.disconnect", .fields = "workspace_id" },
    .{ .name = "ssh-reconnect", .method = "ssh.reconnect", .fields = "workspace_id" },
    .{ .name = "ssh-session-list", .method = "ssh.session-list", .fields = "workspace_id" },
    .{ .name = "ssh-session-attach", .method = "ssh.session-attach", .positional = "terminal_id", .fields = "workspace_id terminal_id", .required = "terminal_id" },
    .{ .name = "ssh-session-cleanup", .method = "ssh.session-cleanup", .positional = "terminal_id", .fields = "workspace_id terminal_id all force", .required = "force" },
    .{ .name = "ssh-upload", .method = "ssh.upload", .positional = "source destination", .fields = "workspace_id source destination", .required = "source destination" },
    .{ .name = "ssh-download", .method = "ssh.download", .positional = "source destination", .fields = "workspace_id source destination", .required = "source destination" },
    .{ .name = "save-session", .method = "session.save" },
    .{ .name = "restore-session", .method = "session.restore" },
    .{ .name = "restart", .method = "app.reexec" },

    .{ .name = "current-window", .method = "window.current", .fields = "window_id" },
    .{ .name = "current-workspace", .method = "workspace.current", .fields = "workspace_id window_id" },
    .{ .name = "move-workspace-to-window", .method = "workspace.move", .fields = "workspace_id destination_window_id index", .required = "workspace_id destination_window_id" },
    .{ .name = "reorder-workspace", .method = "workspace.reorder", .fields = "workspace_id index", .required = "workspace_id index" },
    .{ .name = "tree", .method = "system.tree", .fields = "window_id workspace_id" },
    .{ .name = "list-panes", .method = "pane.list", .fields = "window_id workspace_id" },
    .{ .name = "focus-pane", .method = "pane.focus", .fields = "window_id workspace_id pane_id" },
    .{ .name = "close-pane", .method = "pane.close", .fields = "window_id workspace_id pane_id force", .required = "pane_id force" },
    .{ .name = "new-pane", .method = "pane.create", .fields = "window_id workspace_id pane_id direction cwd command" },
    .{ .name = "new-split", .method = "surface.split", .fields = "window_id workspace_id terminal_id direction cwd command" },
    .{ .name = "list-pane-surfaces", .method = "surface.list", .fields = "window_id workspace_id pane_id" },
    .{ .name = "new-surface", .method = "surface.create", .fields = "window_id workspace_id pane_id cwd command" },
    .{ .name = "close-surface", .method = "surface.close", .fields = "window_id workspace_id surface_id force", .required = "surface_id force" },
    .{ .name = "move-surface", .method = "surface.move", .fields = "window_id workspace_id surface_id destination_workspace_id pane_id direction", .required = "surface_id destination_workspace_id" },
    .{ .name = "split-off", .method = "surface.move", .fields = "window_id workspace_id surface_id destination_workspace_id pane_id direction", .required = "surface_id destination_workspace_id" },
    .{ .name = "drag-surface-to-split", .method = "surface.move", .fields = "window_id workspace_id surface_id destination_workspace_id pane_id direction", .required = "surface_id destination_workspace_id" },
    .{ .name = "refresh-surfaces", .method = "surface.refresh", .fields = "window_id workspace_id" },
    .{ .name = "surface-health", .method = "surface.health", .fields = "window_id workspace_id surface_id" },
    .{ .name = "list-windows", .method = "window.list" },
    .{ .name = "new-window", .method = "window.create" },
    .{ .name = "focus-window", .method = "window.focus", .fields = "window_id" },
    .{ .name = "rename-window", .method = "window.rename", .positional = "name", .fields = "window_id name", .required = "name" },
    .{ .name = "close-window", .method = "window.close", .fields = "window_id force", .required = "force" },
    .{ .name = "list-workspaces", .method = "workspace.list", .fields = "window_id" },
    .{ .name = "new-workspace", .method = "workspace.create", .fields = "window_id name cwd command" },
    .{ .name = "select-workspace", .method = "workspace.focus", .fields = "window_id workspace_id" },
    .{ .name = "rename-workspace", .method = "workspace.rename", .positional = "name", .fields = "window_id workspace_id name", .required = "name" },
    .{ .name = "close-workspace", .method = "workspace.close", .fields = "window_id workspace_id force", .required = "force" },
    .{ .name = "pin-workspace", .method = "workspace.pin", .fields = "window_id workspace_id" },
    .{ .name = "unpin-workspace", .method = "workspace.unpin", .fields = "window_id workspace_id" },
    .{ .name = "mute-workspace", .method = "workspace.mute", .fields = "window_id workspace_id" },
    .{ .name = "unmute-workspace", .method = "workspace.unmute", .fields = "window_id workspace_id" },
    .{ .name = "set-task-status", .method = "workspace.task-status", .positional = "status", .fields = "window_id workspace_id status" },
    .{ .name = "list-terminals", .method = "terminal.list", .fields = "window_id workspace_id" },
    .{ .name = "new-terminal", .method = "terminal.create", .fields = "window_id workspace_id cwd command" },
    .{ .name = "focus-terminal", .method = "terminal.focus", .fields = "window_id workspace_id terminal_id" },
    .{ .name = "rename-terminal", .method = "terminal.rename", .positional = "name", .fields = "window_id workspace_id terminal_id name", .required = "name" },
    .{ .name = "close-terminal", .method = "terminal.close", .fields = "window_id workspace_id terminal_id force", .required = "force" },
    .{ .name = "send", .method = "terminal.send-text", .positional = "text", .fields = "window_id workspace_id terminal_id text", .required = "text" },
    .{ .name = "send-key", .method = "terminal.send-key", .positional = "key", .fields = "window_id workspace_id terminal_id key ctrl alt shift text", .required = "key" },
    .{ .name = "read-screen", .method = "terminal.read", .fields = "window_id workspace_id terminal_id" },
    .{ .name = "notify", .method = "notification.create", .positional = "title body", .fields = "window_id workspace_id terminal_id surface_id title subtitle body level clear" },
    .{ .name = "list-notifications", .method = "notification.list", .fields = "window_id workspace_id terminal_id surface_id unread" },
    .{ .name = "dismiss-notification", .method = "notification.dismiss", .positional = "notification_id", .fields = "notification_id all_read" },
    .{ .name = "mark-notification-read", .method = "notification.mark-read", .positional = "notification_id", .fields = "notification_id window_id workspace_id terminal_id surface_id all" },
    .{ .name = "open-notification", .method = "notification.open", .positional = "notification_id", .fields = "notification_id", .required = "notification_id" },
    .{ .name = "jump-to-unread", .method = "notification.jump-unread", .fields = "window_id workspace_id terminal_id surface_id" },
    .{ .name = "jump-next-unread", .method = "notification.mark-oldest-unread", .fields = "window_id workspace_id terminal_id surface_id" },
    .{ .name = "clear-notifications", .method = "notification.clear", .fields = "window_id workspace_id terminal_id surface_id all_read" },
    .{ .name = "status", .method = "status.set", .positional = "text", .fields = "window_id workspace_id terminal_id surface_id text" },
    .{ .name = "set-status", .method = "status.set", .positional = "text", .fields = "window_id workspace_id terminal_id surface_id key text icon color", .required = "text" },
    .{ .name = "clear-status", .method = "status.clear", .fields = "window_id workspace_id terminal_id surface_id key" },
    .{ .name = "list-status", .method = "status.list", .fields = "window_id workspace_id terminal_id surface_id" },
    .{ .name = "progress", .method = "progress.set", .positional = "value", .fields = "window_id workspace_id terminal_id surface_id value label", .required = "value" },
    .{ .name = "set-progress", .method = "progress.set", .positional = "value", .fields = "window_id workspace_id terminal_id surface_id value label", .required = "value" },
    .{ .name = "clear-progress", .method = "progress.clear", .fields = "window_id workspace_id terminal_id surface_id" },
    .{ .name = "log", .method = "log.append", .positional = "text", .fields = "window_id workspace_id terminal_id surface_id text level", .required = "text" },
    .{ .name = "clear-log", .method = "log.clear", .fields = "window_id workspace_id terminal_id surface_id" },
    .{ .name = "list-log", .method = "log.list", .fields = "window_id workspace_id terminal_id surface_id" },
    .{ .name = "sidebar-state", .method = "sidebar.state", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar toggle", .method = "sidebar.toggle", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar show", .method = "sidebar.show", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar hide", .method = "sidebar.hide", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar focus", .method = "sidebar.focus", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar mode", .method = "sidebar.mode", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar set", .method = "sidebar.set", .positional = "mode", .fields = "window_id workspace_id mode no_focus", .required = "mode" },
    .{ .name = "right-sidebar files", .method = "sidebar.files", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar find", .method = "sidebar.find", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar vault", .method = "sidebar.vault", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar sessions", .method = "sidebar.sessions", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar feed", .method = "sidebar.feed", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar dock", .method = "sidebar.dock", .fields = "window_id workspace_id" },
    .{ .name = "right-sidebar cloud", .method = "sidebar.machines", .fields = "window_id workspace_id" },
    .{ .name = "agent-hook", .method = "agent.hook", .positional = "event", .fields = "window_id workspace_id terminal_id surface_id event", .required = "event" },
    .{ .name = "agent hooks", .method = "agent.hooks" },
    .{ .name = "agent hooks-install", .method = "agent.hooks-install", .positional = "provider", .fields = "provider" },
    .{ .name = "agent capture-session", .method = "agent.session-capture", .positional = "session_id", .fields = "session_id provider window_id workspace_id terminal_id surface_id", .required = "session_id" },
    .{ .name = "agent sessions", .method = "agent.sessions" },
    .{ .name = "agent hooks-uninstall", .method = "agent.hooks-uninstall", .positional = "provider", .fields = "provider", .required = "provider" },
    .{ .name = "agent tmux-shim-install", .method = "agent.tmux-shim-install" },
    .{ .name = "agent tmux-shim-uninstall", .method = "agent.tmux-shim-uninstall" },
    .{ .name = "agent launch", .method = "agent.launch", .positional = "provider prompt", .fields = "window_id workspace_id terminal_id surface_id provider prompt cwd new_pane dry_run", .required = "provider" },
    .{ .name = "agent detect", .method = "agent.detect", .fields = "window_id workspace_id terminal_id surface_id", .required = "terminal_id" },
    .{ .name = "agent fork", .method = "agent.fork", .fields = "window_id workspace_id terminal_id surface_id provider resume prompt cwd", .required = "terminal_id" },
    .{ .name = "agent resume", .method = "agent.launch", .positional = "provider resume", .fields = "window_id workspace_id terminal_id surface_id provider resume cwd new_pane dry_run", .required = "provider resume" },
    .{ .name = "surface resume-set", .method = "surface.resume.set", .positional = "command", .fields = "window_id workspace_id terminal_id surface_id command", .required = "command" },
    .{ .name = "surface resume-show", .method = "surface.resume.show", .fields = "window_id workspace_id terminal_id surface_id" },
    .{ .name = "surface resume-clear", .method = "surface.resume.clear", .fields = "window_id workspace_id terminal_id surface_id" },

    .{ .name = "deep-link preview", .method = "deep-link.open", .positional = "uri", .fields = "uri", .required = "uri" },
    .{ .name = "deep-link open", .method = "deep-link.open", .positional = "uri", .fields = "uri confirm", .required = "uri confirm" },
    .{ .name = "settings get", .method = "settings.get" },
    .{ .name = "settings set", .method = "settings.set", .fields = "scheme theme inherit_terminal_colors clear_theme" },
    .{ .name = "theme list", .method = "theme.list" },
    .{ .name = "theme apply", .method = "theme.apply", .positional = "theme", .fields = "theme", .required = "theme" },
    .{ .name = "shortcut list", .method = "shortcut.list" },
    .{ .name = "update status", .method = "update.status" },
    .{ .name = "update apply", .method = "update.apply", .positional = "artifact sha256", .fields = "artifact sha256 force", .required = "artifact sha256 force" },
    .{ .name = "diagnostics collect", .method = "diagnostics.collect", .positional = "destination", .fields = "destination", .required = "destination" },
    .{ .name = "platform status", .method = "platform.status" },
    .{ .name = "group list", .method = "group.list" },
    .{ .name = "group get", .method = "group.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "group set", .method = "group.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "group delete", .method = "group.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "group assign", .method = "group.assign", .positional = "key workspace_id", .fields = "key workspace_id name", .required = "key workspace_id" },

    .{ .name = "todo list", .method = "todo.list" },
    .{ .name = "todo get", .method = "todo.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "todo set", .method = "todo.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "todo delete", .method = "todo.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "lane list", .method = "lane.list" },
    .{ .name = "lane get", .method = "lane.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "lane set", .method = "lane.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "lane delete", .method = "lane.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "action list", .method = "action.list" },
    .{ .name = "action get", .method = "action.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "action set", .method = "action.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "action delete", .method = "action.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "action run", .method = "action.run", .positional = "key", .fields = "key window_id workspace_id", .required = "key" },
    .{ .name = "layout list", .method = "layout.list" },
    .{ .name = "layout get", .method = "layout.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "layout set", .method = "layout.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "layout delete", .method = "layout.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "layout apply", .method = "layout.apply", .positional = "key", .fields = "key window_id workspace_id", .required = "key" },
    .{ .name = "trust preview", .method = "trust.preview", .positional = "path", .fields = "path", .required = "path" },
    .{ .name = "trust status", .method = "trust.status", .positional = "path", .fields = "path", .required = "path" },
    .{ .name = "trust grant", .method = "trust.grant", .positional = "path", .fields = "path confirm", .required = "path confirm" },
    .{ .name = "trust revoke", .method = "trust.revoke", .positional = "path", .fields = "path", .required = "path" },
    .{ .name = "dock list", .method = "dock.list" },
    .{ .name = "dock set", .method = "dock.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "dock delete", .method = "dock.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "dock open", .method = "dock.open", .positional = "key", .fields = "key window_id workspace_id", .required = "key" },
    .{ .name = "feed list", .method = "feed.list" },
    .{ .name = "feed set", .method = "feed.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "feed delete", .method = "feed.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "feed open", .method = "feed.open", .positional = "", .fields = "key window_id workspace_id", .required = "" },
    .{ .name = "feed push", .method = "feed.push", .positional = "kind title", .fields = "kind title body tool request_id workspace_id terminal_id", .required = "kind title" },
    .{ .name = "feed reply", .method = "feed.reply", .positional = "id verb", .fields = "id verb answer", .required = "id verb" },
    .{ .name = "feed tui", .method = "feed.tui", .fields = "dock new_pane window_id workspace_id" },
    .{ .name = "custom-sidebar list", .method = "custom-sidebar.list" },
    .{ .name = "custom-sidebar set", .method = "custom-sidebar.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "custom-sidebar delete", .method = "custom-sidebar.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "custom-sidebar open", .method = "custom-sidebar.open", .positional = "key", .fields = "key window_id workspace_id", .required = "key" },
    .{ .name = "viewer open", .method = "viewer.open", .positional = "path", .fields = "path type", .required = "path" },
    .{ .name = "viewer save", .method = "viewer.save", .positional = "key path", .fields = "key path type", .required = "key path" },
    .{ .name = "viewer refresh", .method = "viewer.refresh", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "viewer list", .method = "viewer.list" },
    .{ .name = "viewer delete", .method = "viewer.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "vault list", .method = "vault.list" },
    .{ .name = "vault get", .method = "vault.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "vault capture", .method = "vault.capture", .positional = "key text", .fields = "key text workspace_id terminal_id", .required = "key text" },
    .{ .name = "vault search", .method = "vault.search", .positional = "query", .fields = "query", .required = "query" },
    .{ .name = "vault checkpoint", .method = "vault.checkpoint", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "vault fork", .method = "vault.fork", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "vault delete", .method = "vault.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "task list", .method = "task.list" },
    .{ .name = "task tree", .method = "task.tree" },
    .{ .name = "task register", .method = "task.register", .positional = "key pid", .fields = "key pid owner", .required = "key pid" },
    .{ .name = "task status", .method = "task.status", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "task unregister", .method = "task.unregister", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "task terminate", .method = "task.terminate", .positional = "key", .fields = "key force", .required = "key force" },
    .{ .name = "headless list", .method = "headless.list" },
    .{ .name = "headless save", .method = "headless.save", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "headless attach", .method = "headless.attach", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "headless detach", .method = "headless.detach", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "headless tui", .method = "headless.tui", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "headless delete", .method = "headless.delete", .positional = "key", .fields = "key force", .required = "key force" },
    .{ .name = "machine list", .method = "machine.list" },
    .{ .name = "machine register", .method = "machine.register", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "machine status", .method = "machine.status", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "machine start", .method = "machine.start", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "machine stop", .method = "machine.stop", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "machine route", .method = "machine.route", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "machine delete", .method = "machine.delete", .positional = "key", .fields = "key force", .required = "key force" },
    .{ .name = "publication list", .method = "publication.list" },
    .{ .name = "publication publish", .method = "publication.publish", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "publication get", .method = "publication.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "publication delete", .method = "publication.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "device list", .method = "device.list" },
    .{ .name = "device pair", .method = "device.pair", .positional = "key", .fields = "key name", .required = "key" },
    .{ .name = "device status", .method = "device.status", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "device sync", .method = "device.sync", .positional = "key value", .fields = "key value token", .required = "key value token" },
    .{ .name = "device notify", .method = "device.notify", .positional = "key value", .fields = "key value token", .required = "key value token" },
    .{ .name = "device reply", .method = "device.reply", .positional = "key value", .fields = "key value token", .required = "key value token" },
    .{ .name = "device compose", .method = "device.compose", .positional = "key value", .fields = "key value token", .required = "key value token" },
    .{ .name = "device revoke", .method = "device.revoke", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "event list", .method = "event.list" },
    .{ .name = "event emit", .method = "event.emit", .positional = "value", .fields = "value", .required = "value" },
    .{ .name = "event clear", .method = "event.clear" },
    .{ .name = "automation-rule list", .method = "automation-rule.list" },
    .{ .name = "automation-rule get", .method = "automation-rule.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "automation-rule set", .method = "automation-rule.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "automation-rule delete", .method = "automation-rule.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "agent-control list", .method = "agent-control.list" },
    .{ .name = "agent-control register", .method = "agent-control.register", .positional = "key pid limit_mb", .fields = "key pid limit_mb keep_awake", .required = "key pid limit_mb" },
    .{ .name = "agent-control status", .method = "agent-control.status", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "agent-control check", .method = "agent-control.check", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "agent-control hibernate", .method = "agent-control.hibernate", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "agent-control resume", .method = "agent-control.resume", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "agent-control delete", .method = "agent-control.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "canvas list", .method = "canvas.list" },
    .{ .name = "canvas get", .method = "canvas.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "canvas set", .method = "canvas.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "canvas delete", .method = "canvas.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "canvas open", .method = "canvas.open", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "computer-use open", .method = "computer-use.open", .fields = "window_id workspace_id uri" },
    .{ .name = "simulator list", .method = "simulator.list" },
    .{ .name = "simulator open", .method = "simulator.open", .positional = "kind", .fields = "window_id workspace_id kind uri key" },
    .{ .name = "simulator register", .method = "simulator.register", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "simulator status", .method = "simulator.status", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "simulator stream", .method = "simulator.stream", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "simulator touch", .method = "simulator.touch", .positional = "key x y", .fields = "key x y", .required = "key x y" },
    .{ .name = "simulator delete", .method = "simulator.delete", .positional = "key", .fields = "key", .required = "key" },

    .{ .name = "policy list", .method = "policy.list" },
    .{ .name = "policy get", .method = "policy.get", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "policy set", .method = "policy.set", .positional = "key value", .fields = "key value", .required = "key value" },
    .{ .name = "policy delete", .method = "policy.delete", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "policy effective", .method = "policy.effective" },
    .{ .name = "locale list", .method = "locale.list" },
    .{ .name = "locale status", .method = "locale.status" },
    .{ .name = "locale set", .method = "locale.set", .positional = "key", .fields = "key", .required = "key" },
    .{ .name = "prompt list", .method = "prompt.list" },
    .{ .name = "prompt get", .method = "prompt.get", .positional = "name", .fields = "name", .required = "name" },
    .{ .name = "prompt set", .method = "prompt.set", .positional = "name text", .fields = "name text", .required = "name text" },
    .{ .name = "prompt delete", .method = "prompt.delete", .positional = "name", .fields = "name", .required = "name" },
    .{ .name = "prompt run", .method = "prompt.run", .positional = "name", .fields = "window_id workspace_id terminal_id surface_id name submit", .required = "name" },
    .{ .name = "rule list", .method = "rule.list" },
    .{ .name = "rule get", .method = "rule.get", .positional = "name", .fields = "name", .required = "name" },
    .{ .name = "rule set", .method = "rule.set", .positional = "name text", .fields = "name text", .required = "name text" },
    .{ .name = "rule delete", .method = "rule.delete", .positional = "name", .fields = "name", .required = "name" },
    .{ .name = "rule run", .method = "rule.run", .positional = "name", .fields = "window_id workspace_id terminal_id surface_id name submit", .required = "name" },
    .{ .name = "browser create", .method = "browser.create", .fields = "workspace_id profile" },
    .{ .name = "browser list", .method = "browser.list", .fields = "workspace_id" },
    .{ .name = "browser close", .method = "browser.close", .fields = "workspace_id browser_id" },
    .{ .name = "browser focus", .method = "browser.focus", .fields = "workspace_id browser_id" },
    .{ .name = "browser navigate", .method = "browser.navigate", .positional = "uri", .fields = "workspace_id browser_id uri timeout_ms", .required = "uri" },
    .{ .name = "browser status", .method = "browser.status", .fields = "workspace_id browser_id" },
    .{ .name = "browser snapshot", .method = "browser.snapshot", .fields = "workspace_id browser_id timeout_ms" },
    .{ .name = "browser back", .method = "browser.back", .fields = "workspace_id browser_id timeout_ms" },
    .{ .name = "browser forward", .method = "browser.forward", .fields = "workspace_id browser_id timeout_ms" },
    .{ .name = "browser reload", .method = "browser.reload", .fields = "workspace_id browser_id timeout_ms" },
    .{ .name = "browser stop", .method = "browser.stop", .fields = "workspace_id browser_id" },
    .{ .name = "browser screenshot", .method = "browser.screenshot", .positional = "path", .fields = "workspace_id browser_id path full_page timeout_ms", .required = "path" },
    .{ .name = "browser download", .method = "browser.download", .positional = "uri path", .fields = "workspace_id browser_id uri path", .required = "uri path" },
    .{ .name = "browser devtools", .method = "browser.devtools", .fields = "workspace_id browser_id" },
    .{ .name = "browser upload", .method = "browser.upload", .positional = "ref path", .fields = "workspace_id browser_id ref path generation timeout_ms", .required = "ref path generation" },
    .{ .name = "browser permissions", .method = "browser.permissions", .fields = "workspace_id browser_id" },
    .{ .name = "browser permission", .method = "browser.permission", .positional = "name", .fields = "workspace_id browser_id name allow deny", .required = "name" },
    .{ .name = "browser state-export", .method = "browser.state-export", .fields = "workspace_id browser_id timeout_ms" },
    .{ .name = "browser state-import", .method = "browser.state-import", .positional = "state", .fields = "workspace_id browser_id state generation timeout_ms", .required = "state generation" },
    .{ .name = "browser frames", .method = "browser.frames", .fields = "workspace_id browser_id timeout_ms" },
    .{ .name = "browser logs", .method = "browser.logs", .fields = "workspace_id browser_id" },
    .{ .name = "browser logs-clear", .method = "browser.logs-clear", .fields = "workspace_id browser_id" },
    .{ .name = "browser dialog-policy", .method = "browser.dialog-policy", .positional = "action", .fields = "workspace_id browser_id action prompt", .required = "action" },
    .{ .name = "browser viewport", .method = "browser.viewport", .positional = "width height", .fields = "workspace_id browser_id width height", .required = "width height" },
    .{ .name = "browser network", .method = "browser.network", .positional = "mode", .fields = "workspace_id browser_id mode timeout_ms", .required = "mode" },
    .{ .name = "browser script", .method = "browser.script", .positional = "script", .fields = "workspace_id browser_id script timeout_ms", .required = "script" },
    .{ .name = "browser style", .method = "browser.style", .positional = "css", .fields = "workspace_id browser_id css timeout_ms", .required = "css" },
    .{ .name = "browser annotate", .method = "browser.annotate", .positional = "ref text", .fields = "workspace_id browser_id ref text generation timeout_ms", .required = "ref text generation" },
    .{ .name = "browser annotations-clear", .method = "browser.annotations-clear", .fields = "workspace_id browser_id timeout_ms" },
    .{ .name = "browser click", .method = "browser.click", .positional = "ref", .fields = "workspace_id browser_id ref generation timeout_ms", .required = "ref generation" },
    .{ .name = "browser fill", .method = "browser.fill", .positional = "ref value", .fields = "workspace_id browser_id ref value generation timeout_ms", .required = "ref value generation" },
    .{ .name = "browser evaluate", .method = "browser.evaluate", .positional = "script", .fields = "workspace_id browser_id script generation timeout_ms", .required = "script" },
    .{ .name = "browser get", .method = "browser.get", .positional = "ref", .fields = "workspace_id browser_id ref generation timeout_ms", .required = "ref generation" },
    .{ .name = "browser find", .method = "browser.find", .positional = "query", .fields = "workspace_id browser_id query timeout_ms", .required = "query" },
    .{ .name = "browser wait", .method = "browser.wait", .positional = "query", .fields = "workspace_id browser_id query timeout_ms", .required = "query" },
    .{ .name = "browser select", .method = "browser.select", .positional = "ref value", .fields = "workspace_id browser_id ref value generation timeout_ms", .required = "ref value generation" },
    .{ .name = "browser press", .method = "browser.press", .positional = "ref key", .fields = "workspace_id browser_id ref key generation timeout_ms", .required = "ref key generation" },
};

/// Terminal launch options and +helper actions still belong to Ghostty's parser.
pub fn isInvocation(args: []const [:0]u8) bool {
    if (args.len == 0) return false;
    const first = args[0];
    if (first.len == 0) return true;
    if (first[0] == '+') return false;
    if (first[0] != '-') return true;
    const key = first[0 .. std.mem.indexOfScalar(u8, first, '=') orelse first.len];
    return inWords("--help -h --version -v --skill --json --socket --password --id-format --window --workspace --terminal --pane --surface --browser", key);
}

fn inWords(words: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, words, ' ');
    while (it.next()) |item| if (std.mem.eql(u8, item, word)) return true;
    return false;
}

fn fieldName(alloc: Allocator, option: []const u8) ![]const u8 {
    if (std.mem.eql(u8, option, "-p")) return "port";
    if (std.mem.eql(u8, option, "-i")) return "identity";
    if (std.mem.eql(u8, option, "-F")) return "ssh_config";
    if (std.mem.eql(u8, option, "-A")) return "forward_agent";
    if (std.mem.eql(u8, option, "-a")) return "no_forward_agent";
    if (!std.mem.startsWith(u8, option, "--") or option.len == 2) return error.UnknownOption;
    const name = option[2..];
    inline for (.{ "window", "workspace", "terminal", "browser", "pane", "surface", "notification", "destination-window", "destination-workspace" }) |kind| {
        if (std.mem.eql(u8, name, kind)) return if (std.mem.eql(u8, kind, "destination-window"))
            "destination_window_id"
        else if (std.mem.eql(u8, kind, "destination-workspace"))
            "destination_workspace_id"
        else
            kind ++ "_id";
    }
    const field = try alloc.dupe(u8, name);
    for (field) |*c| if (c.* == '-') {
        c.* = '_';
    };
    return field;
}

fn put(params: *p.Value, field: []const u8, value: p.Value) !void {
    if (params.object.contains(field)) return error.DuplicateArgument;
    try params.object.put(field, value);
}

/// The returned request borrows argv strings; the caller owns their lifetime.
pub fn parse(alloc: Allocator, args: []const [:0]u8) !Parsed {
    var result: Parsed = .{};
    var params: p.Value = .{ .object = .init(alloc) };
    var positional: std.ArrayList([]const u8) = .empty;
    var literal = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!literal and std.mem.eql(u8, arg, "--")) {
            literal = true;
            continue;
        }
        if (literal or arg.len == 0 or arg[0] != '-') {
            try positional.append(alloc, arg);
            continue;
        }
        const equal = std.mem.indexOfScalar(u8, arg, '=');
        var option: []const u8 = arg[0 .. equal orelse arg.len];
        var value: ?[]const u8 = if (equal) |at| arg[at + 1 ..] else null;
        if (arg.len > 2 and arg[0] == '-' and inWords("-p -i -F", arg[0..2])) {
            option = arg[0..2];
            value = arg[2..];
        }
        if (inWords("--help -h", option)) {
            if (value != null) return error.InvalidArguments;
            result.help = true;
            continue;
        }
        if (inWords("--version -v", option)) {
            if (value != null) return error.InvalidArguments;
            result.version = true;
            continue;
        }
        if (std.mem.eql(u8, option, "--json")) {
            if (value != null) return error.InvalidArguments;
            result.json = true;
            continue;
        }
        if (std.mem.eql(u8, option, "--skill")) {
            if (value != null) return error.InvalidArguments;
            result.help = true;
            continue;
        }
        const field = try fieldName(alloc, option);
        if (inWords("force ctrl alt shift no_focus new_pane dry_run all all_read unread clear allow deny submit forward_agent no_forward_agent full_page inherit_terminal_colors clear_theme keep_awake", field)) {
            const enabled = if (value) |v| blk: {
                if (std.mem.eql(u8, v, "true")) break :blk true;
                if (std.mem.eql(u8, v, "false")) break :blk false;
                return error.InvalidBoolean;
            } else true;
            try put(&params, field, p.boolean(enabled));
            continue;
        }
        if (value == null) {
            i += 1;
            if (i == args.len) return error.MissingOptionValue;
            value = args[i];
        }
        if (std.mem.eql(u8, field, "socket")) {
            if (result.socket != null) return error.DuplicateArgument;
            if (value.?.len == 0) return error.InvalidSocketPath;
            result.socket = value;
        } else if (std.mem.eql(u8, field, "password")) {
            if (result.password != null) return error.DuplicateArgument;
            result.password = value;
        } else if (std.mem.eql(u8, field, "id_format")) {
            if (!inWords("refs uuids both", value.?)) return error.InvalidIdFormat;
            result.id_format = value.?;
        } else try put(&params, field, p.str(value.?));
    }
    const tokens = positional.items;
    if (result.version or (tokens.len == 1 and std.mem.eql(u8, tokens[0], "version"))) {
        if (tokens.len > 1 or params.object.count() != 0) return error.InvalidArguments;
        result.version = true;
        return result;
    }
    if (result.help) {
        if (tokens.len > 0) result.help_command = tokens[0];
        return result;
    }
    if (tokens.len == 0) return error.MissingCommand;
    if (std.mem.eql(u8, tokens[0], "help")) {
        if (tokens.len > 2 or params.object.count() != 0) return error.InvalidArguments;
        result.help = true;
        if (tokens.len == 2) result.help_command = tokens[1];
        return result;
    }
    if (std.mem.eql(u8, tokens[0], "endpoints")) {
        if (tokens.len != 1 or params.object.count() != 0) return error.InvalidArguments;
        result.endpoints = true;
        return result;
    }
    if (tokens.len == 1 and params.object.count() == 0) {
        if (std.fs.cwd().statFile(tokens[0])) |_| {
            result.open_path = tokens[0];
            return result;
        } else |_| {}
    }
    if (std.mem.eql(u8, tokens[0], "ctl") or std.mem.eql(u8, tokens[0], "rpc")) {
        if (params.object.count() != 0) return error.InvalidArguments;
        if (tokens.len == 1) {
            result.help = true;
            result.help_command = tokens[0];
            return result;
        }
        if (tokens.len == 2 and std.mem.eql(u8, tokens[1], "endpoints")) {
            result.endpoints = true;
            return result;
        }
        if (tokens.len > 3) return error.InvalidArguments;
        const body = try std.json.parseFromSliceLeaky(p.Value, alloc, if (tokens.len == 3) tokens[2] else "{}", .{ .allocate = .alloc_always });
        if (std.mem.eql(u8, tokens[0], "ctl") and std.mem.eql(u8, tokens[1], "request")) {
            result.request = body;
            result.ambient_targets = false;
        } else {
            if (body != .object) return error.InvalidParams;
            result.request = try p.object(alloc, .{ .method = p.str(tokens[1]), .params = body });
        }
        return result;
    }
    const namespaced = inWords("browser right-sidebar prompt rule agent deep-link settings theme shortcut update diagnostics platform group todo lane action layout trust dock feed custom-sidebar viewer vault task headless machine publication device event automation-rule agent-control canvas simulator policy locale computer-use", tokens[0]);

    if (namespaced and tokens.len < 2) return error.MissingCommand;
    const name = if (namespaced) try std.fmt.allocPrint(alloc, "{s} {s}", .{ tokens[0], tokens[1] }) else tokens[0];
    const command = for (commands) |candidate| {
        if (std.mem.eql(u8, name, candidate.name)) break candidate;
    } else return error.UnknownCommand;
    var fields = std.mem.tokenizeScalar(u8, command.positional, ' ');
    for (tokens[if (namespaced) @as(usize, 2) else 1..]) |value| {
        const field = fields.next() orelse return error.UnexpectedArgument;
        try put(&params, field, p.str(value));
    }
    var it = params.object.iterator();
    while (it.next()) |entry| {
        if (!inWords(command.fields, entry.key_ptr.*)) return error.UnknownOption;
        if (inWords("port generation timeout_ms index width height pid limit_mb x y", entry.key_ptr.*)) {
            const number = std.fmt.parseInt(i64, entry.value_ptr.string, 10) catch return error.InvalidInteger;
            if (std.mem.eql(u8, entry.key_ptr.*, "port") and (number < 1 or number > 65535)) return error.InvalidPort;
            if (std.mem.eql(u8, entry.key_ptr.*, "generation") and number < 0) return error.InvalidGeneration;
            if (std.mem.eql(u8, entry.key_ptr.*, "timeout_ms") and (number < 1 or number > 120000)) return error.InvalidTimeout;
            if (std.mem.eql(u8, entry.key_ptr.*, "index") and number < 0) return error.InvalidIndex;
            entry.value_ptr.* = p.integer(number);
        }
    }
    var required = std.mem.tokenizeScalar(u8, command.required, ' ');
    while (required.next()) |field| {
        const value = params.object.get(field) orelse return error.MissingArgument;
        if (std.mem.eql(u8, field, "force") and !value.bool) return error.ForceRequired;
    }
    if (std.mem.eql(u8, command.method, "ssh.create")) {
        if (params.object.contains("forward_agent") and params.object.contains("no_forward_agent"))
            return error.InvalidArguments;
        if (params.object.get("transport")) |value| {
            if (!inWords("ssh mosh", value.string)) return error.InvalidArguments;
        }
        if (params.object.get("profile")) |value| {
            if (!inWords("shell tmux", value.string)) return error.InvalidArguments;
        }
        if (std.mem.eql(u8, command.name, "mosh") or std.mem.eql(u8, command.name, "mosh-tmux")) {
            if (params.object.get("transport")) |value| {
                if (!std.mem.eql(u8, value.string, "mosh")) return error.InvalidArguments;
            } else try params.object.put("transport", p.str("mosh"));
        }
        if (std.mem.eql(u8, command.name, "mosh-tmux")) {
            if (params.object.get("profile")) |value| {
                if (!std.mem.eql(u8, value.string, "tmux")) return error.InvalidArguments;
            } else try params.object.put("profile", p.str("tmux"));
            if (!params.object.contains("session")) try params.object.put("session", p.str("main"));
        }
        if (params.object.get("session")) |value| {
            const profile = params.object.get("profile") orelse return error.InvalidArguments;
            if (!std.mem.eql(u8, profile.string, "tmux") or value.string.len == 0 or value.string.len > 128 or
                std.mem.indexOfAny(u8, value.string, ".:") != null) return error.InvalidArguments;
        }
    }
    if (std.mem.eql(u8, command.name, "ssh-session-cleanup")) {
        const terminal = params.object.contains("terminal_id");
        const all = if (params.object.get("all")) |value| value.bool else false;
        if (!terminal and !all) return error.MissingArgument;
        if (terminal and all) return error.InvalidArguments;
    }
    if (std.mem.eql(u8, command.method, "progress.set")) {
        const text = params.object.get("value").?.string;
        const progress: p.Value = if (std.mem.eql(u8, text, "clear")) .null else blk: {
            const number = std.fmt.parseInt(i64, text, 10) catch return error.InvalidProgress;
            if (number < 0 or number > 100) return error.InvalidProgress;
            break :blk p.integer(number);
        };
        try params.object.put("value", progress);
    }
    // These paths are local to the invoking shell, not the GUI process.
    // Remote cwd/destination deliberately remain in the remote namespace.
    var cwd: ?[]const u8 = null;
    defer if (cwd) |value| alloc.free(value);
    const transfer_path = if (std.mem.eql(u8, command.name, "ssh-download")) "destination" else "source";
    const local_path = if (std.mem.eql(u8, command.name, "browser screenshot") or
        std.mem.eql(u8, command.name, "browser download") or
        std.mem.eql(u8, command.name, "browser upload")) "path" else transfer_path;
    for ([_][]const u8{ "identity", "ssh_config", local_path }) |field| {
        if (params.object.getPtr(field)) |value| {
            if (std.fs.path.isAbsolute(value.string)) continue;
            var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const expanded = try @import("../os/homedir.zig").expandHome(value.string, &home_buffer);
            if (std.fs.path.isAbsolute(expanded)) {
                value.* = p.str(try alloc.dupe(u8, expanded));
            } else {
                if (cwd == null) cwd = try std.process.getCwdAlloc(alloc);
                value.* = p.str(try std.fs.path.resolve(alloc, &.{ cwd.?, expanded }));
            }
        }
    }
    var method = if (std.mem.eql(u8, command.name, "status") and !params.object.contains("text")) "status.get" else command.method;
    if (std.mem.eql(u8, command.name, "notify")) {
        if (params.object.get("clear")) |clear| {
            if (!clear.bool or params.object.contains("title") or params.object.contains("body") or params.object.contains("subtitle"))
                return error.InvalidArguments;
            method = "notification.clear";
        } else if (!params.object.contains("title")) return error.MissingArgument;
    }
    result.request = try p.object(alloc, .{ .method = p.str(method), .params = params });
    return result;
}

pub fn help(command_name: ?[]const u8) !void {
    if (command_name) |name| {
        const stdout = std.fs.File.stdout();
        if (std.mem.eql(u8, name, "ctl") or std.mem.eql(u8, name, "rpc")) {
            try stdout.writeAll("Usage: clm rpc METHOD ['{\"parameter\":\"value\"}']\n");
            return;
        }
        if (std.mem.eql(u8, name, "browser")) {
            try stdout.writeAll(
                "Usage: clm browser COMMAND [arguments] [options]\n" ++
                    "Commands: create list close focus status navigate back forward reload stop snapshot\n" ++
                    "          get find wait click fill select press upload download screenshot\n" ++
                    "          frames logs logs-clear dialog-policy permissions permission devtools\n" ++
                    "          state-export state-import viewport network script style annotate annotations-clear evaluate\n",
            );
            return;
        }
        const command = for (commands) |candidate| {
            if (std.mem.eql(u8, name, candidate.name)) break candidate;
        } else return error.UnknownCommand;
        try stdout.writeAll("Usage: clm ");
        try stdout.writeAll(command.name);
        if (command.positional.len > 0) {
            try stdout.writeAll(" ");
            try stdout.writeAll(command.positional);
        }
        if (command.fields.len > 0) try stdout.writeAll(" [options]");
        try stdout.writeAll("\nRPC method: ");
        try stdout.writeAll(command.method);
        try stdout.writeAll("\n");
        if (command.fields.len > 0) {
            try stdout.writeAll("Options: ");
            var fields = std.mem.tokenizeScalar(u8, command.fields, ' ');
            var first = true;
            while (fields.next()) |field| {
                if (!first) try stdout.writeAll(", ");
                first = false;
                try stdout.writeAll("--");
                for (field) |byte| try stdout.writeAll(&.{if (byte == '_') '-' else byte});
            }
            try stdout.writeAll("\n");
        }
        return;
    }
    try std.fs.File.stdout().writeAll(
        \\Usage: clm [terminal-options]                 Open Colm
        \\       clm [--socket PATH] COMMAND [options]   Control a running instance
        \\
        \\SSH:
        \\  ssh HOST [--name NAME --cwd DIR --command TEXT]
        \\           [-p PORT -i IDENTITY -F SSH_CONFIG] [-A | -a]
        \\           [--transport ssh|mosh] [--profile shell|tmux] [--session NAME]
        \\  mosh HOST | mosh-tmux HOST [--session NAME]
        \\  ssh-status | ssh-disconnect | ssh-reconnect --workspace ID
        \\  ssh-session-list | ssh-session-attach TERMINAL --workspace ID
        \\  ssh-session-cleanup [TERMINAL | --all] --workspace ID --force
        \\  ssh-upload LOCAL REMOTE | ssh-download REMOTE LOCAL --workspace ID
        \\  SSH remains the management lane. Missing Mosh capabilities fall back with status detail.
        \\
        \\Windows and workspaces:
        \\  list-windows | new-window | focus-window | rename-window NAME | close-window
        \\  list-workspaces | new-workspace [--name NAME --cwd DIR --command TEXT]
        \\  select-workspace | rename-workspace NAME | close-workspace
        \\
        \\Terminals:
        \\  list-terminals | new-terminal [--cwd DIR --command TEXT]
        \\  focus-terminal | rename-terminal NAME | close-terminal
        \\  send TEXT | send-key KEY [--ctrl --alt --shift --text TEXT] | read-screen
        \\  send pastes exactly TEXT. Use send-key enter to execute it.
        \\  Keys use Ghostty names: enter, escape, arrow_up, key_c, etc.
        \\
        \\Notifications and hooks:
        \\  notify TITLE [BODY]       (or --title TITLE --body BODY)
        \\  status [TEXT] | progress PERCENT|clear | agent-hook EVENT
        \\
        \\Browser:
        \\  browser create | list | close | focus | status | navigate URI | back | forward
        \\  browser snapshot | get | find | wait | click | fill | select | press
        \\  browser upload | download | screenshot | frames | logs | dialog-policy
        \\  browser permissions | permission | devtools | state-export | state-import
        \\  browser viewport | network | script | style | annotate | evaluate
        \\  Use --workspace ID --browser ID; element actions require --generation N.
        \\  Async operations accept --timeout-ms 1..120000.
        \\
        \\Agents and reusable instructions:
        \\  prompt list|get|set|delete|run | rule list|get|set|delete|run
        \\  agent launch|resume|team | hooks|hooks-install|hooks-uninstall
        \\  agent tmux-shim-install|tmux-shim-uninstall
        \\  deep-link preview URI, then deep-link open URI --confirm TOKEN
        \\
        \\Settings and maintenance:
        \\  settings get|set | theme list|apply | shortcut list
        \\  update status|apply | diagnostics collect PATH | platform status
        \\  Package-managed installs update through Flatpak or the distro. Standalone
        \\  replacement requires COLM_ALLOW_SELF_UPDATE=1, --force, and an exact SHA-256.
        \\
        \\Targeting:
        \\  --window ID --workspace ID --terminal ID --browser ID
        \\  Inside terminals COLM_WORKSPACE_ID/COLM_TERMINAL_ID and CMUX_* aliases
        \\  supply absent targets. Any explicit target disables ambient defaults.
        \\  Closing a window/workspace/terminal requires --force.
        \\  endpoints lists instances; --socket PATH or COLM_SOCKET selects one.
        \\  -- separates literal arguments (for example: clm send -- --help).
        \\
        \\Compatibility and migration:
        \\  Colm uses native Linux/FreeBSD GTK, XDG config/state paths, and its own
        \\  io.github.al3rez.Colm application identity. It accepts CMUX_SOCKET_PATH,
        \\  CMUX_SOCKET_PASSWORD, CMUX_* topology variables, cmux:// deep links, and
        \\  cmux-style CLI verbs where implemented. IDs are Colm-owned stable refs;
        \\  do not copy persisted IDs between applications.
        \\  Browser profiles are isolated by local/remote route. Proprietary cmux
        \\  cloud credentials, Apple binaries, and update services are never reused.
        \\
        \\JSON is the default output; --json is also accepted.
        \\Exit statuses: 0 success, 1 API error, 2 usage/transport error.
        \\Raw API: clm ctl METHOD '{"parameter":"value"}'
        \\         clm ctl request '{"method":"workspace.list","params":{}}'
        \\Terminal launch flags (-e, --working-directory, etc.) and +helper actions
        \\remain available. Use clm +help for the terminal helper action list.
        \\
    );
}

test "direct command parses SSH transport parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][:0]const u8{
        "ssh", "build-host",        "--name",        "Builder",   "-p2222",
        "-i",  "~/.ssh/id_ed25519", "-F=config/ssh", "--command", "printf ready",
        "-A",
    };
    const parsed = try parse(arena.allocator(), &args);
    const params = parsed.request.object.get("params").?.object;
    try std.testing.expectEqualStrings("ssh.create", parsed.request.object.get("method").?.string);
    try std.testing.expectEqualStrings("build-host", params.get("host").?.string);
    try std.testing.expectEqualStrings("Builder", params.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2222), params.get("port").?.integer);
    try std.testing.expect(std.fs.path.isAbsolute(params.get("identity").?.string));
    try std.testing.expect(std.fs.path.isAbsolute(params.get("ssh_config").?.string));
    try std.testing.expectEqualStrings("printf ready", params.get("command").?.string);
    try std.testing.expect(params.get("forward_agent").?.bool);

    const conflicting = [_][:0]const u8{ "ssh", "build-host", "-A", "-a" };
    try std.testing.expectError(error.InvalidArguments, parse(arena.allocator(), &conflicting));
    const attach_args = [_][:0]const u8{ "ssh-session-attach", "terminal-id", "--workspace", "workspace-id" };
    const attach = try parse(arena.allocator(), &attach_args);
    try std.testing.expectEqualStrings("ssh.session-attach", attach.request.object.get("method").?.string);

    const mosh_tmux_args = [_][:0]const u8{ "mosh-tmux", "build-host", "--session", "review" };
    const mosh_tmux = try parse(arena.allocator(), &mosh_tmux_args);
    const mosh_params = mosh_tmux.request.object.get("params").?.object;
    try std.testing.expectEqualStrings("mosh", mosh_params.get("transport").?.string);
    try std.testing.expectEqualStrings("tmux", mosh_params.get("profile").?.string);
    try std.testing.expectEqualStrings("review", mosh_params.get("session").?.string);

    const download_args = [_][:0]const u8{ "ssh-download", "/remote/file", "downloads/file", "--workspace", "workspace-id" };
    const download = try parse(arena.allocator(), &download_args);
    const download_params = download.request.object.get("params").?.object;
    try std.testing.expectEqualStrings("/remote/file", download_params.get("source").?.string);
    try std.testing.expect(std.fs.path.isAbsolute(download_params.get("destination").?.string));
}

test "direct command maps lifecycle destinations and indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workspace_args = [_][:0]const u8{
        "move-workspace-to-window",
        "--workspace",
        "workspace-id",
        "--destination-window",
        "window-id",
        "--index",
        "2",
    };
    const workspace = try parse(arena.allocator(), &workspace_args);
    const workspace_params = workspace.request.object.get("params").?.object;
    try std.testing.expectEqualStrings("workspace.move", workspace.request.object.get("method").?.string);
    try std.testing.expectEqualStrings("window-id", workspace_params.get("destination_window_id").?.string);
    try std.testing.expectEqual(@as(i64, 2), workspace_params.get("index").?.integer);

    const surface_args = [_][:0]const u8{
        "drag-surface-to-split",
        "--surface",
        "surface-id",
        "--destination-workspace",
        "workspace-id",
        "--pane",
        "pane-id",
        "--direction",
        "left",
    };
    const surface = try parse(arena.allocator(), &surface_args);
    const surface_params = surface.request.object.get("params").?.object;
    try std.testing.expectEqualStrings("surface.move", surface.request.object.get("method").?.string);
    try std.testing.expectEqualStrings("pane-id", surface_params.get("pane_id").?.string);
    try std.testing.expectEqualStrings("left", surface_params.get("direction").?.string);
}

test "direct command enforces literal input and destructive boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const send_args = [_][:0]const u8{ "send", "--terminal", "terminal-id", "--", "--help" };
    const send = try parse(arena.allocator(), &send_args);
    try std.testing.expectEqualStrings("--help", send.request.object.get("params").?.object.get("text").?.string);

    const missing_force = [_][:0]const u8{ "close-workspace", "--workspace", "workspace-id" };
    try std.testing.expectError(error.MissingArgument, parse(arena.allocator(), &missing_force));
    const false_force = [_][:0]const u8{ "close-workspace", "--workspace", "workspace-id", "--force=false" };
    try std.testing.expectError(error.ForceRequired, parse(arena.allocator(), &false_force));
    const unsupported = [_][:0]const u8{ "ssh", "host", "--transport", "telnet" };
    try std.testing.expectError(error.InvalidArguments, parse(arena.allocator(), &unsupported));
}

test "direct command raw request never receives ambient targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][:0]const u8{ "ctl", "request", "{\"method\":\"workspace.list\",\"params\":{}}" };
    const parsed = try parse(arena.allocator(), &args);
    try std.testing.expect(!parsed.ambient_targets);
    try std.testing.expectEqualStrings("workspace.list", parsed.request.object.get("method").?.string);
}

test "global control options work around commands without socket access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const request_args = [_][:0]const u8{
        "--password", "secret", "rpc", "system.ping", "--id-format", "both", "--json",
    };
    const request = try parse(arena.allocator(), &request_args);
    try std.testing.expectEqualStrings("secret", request.password.?);
    try std.testing.expectEqualStrings("both", request.id_format);
    try std.testing.expect(request.json);
    try std.testing.expectEqualStrings("system.ping", request.request.object.get("method").?.string);

    const help_args = [_][:0]const u8{ "ping", "--help" };
    const help_result = try parse(arena.allocator(), &help_args);
    try std.testing.expect(help_result.help);
    try std.testing.expectEqualStrings("ping", help_result.help_command.?);

    const version_args = [_][:0]const u8{"-v"};
    try std.testing.expect((try parse(arena.allocator(), &version_args)).version);
}

test "notification command supports rich delivery and scoped clear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const rich_args = [_][:0]const u8{
        "notify", "--title", "Done", "--subtitle", "Build", "--body", "Ready", "--level", "warning",
    };
    const rich = try parse(arena.allocator(), &rich_args);
    try std.testing.expectEqualStrings("notification.create", rich.request.object.get("method").?.string);
    try std.testing.expectEqualStrings("Build", rich.request.object.get("params").?.object.get("subtitle").?.string);

    const clear_args = [_][:0]const u8{ "notify", "--clear", "--surface", "surface:1" };
    const clear = try parse(arena.allocator(), &clear_args);
    try std.testing.expectEqualStrings("notification.clear", clear.request.object.get("method").?.string);
}
