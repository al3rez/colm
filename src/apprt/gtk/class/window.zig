const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const TitlebarStyle = configpkg.Config.GtkTitlebarStyle;
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gtk_version = @import("../gtk_version.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const winprotopkg = @import("../winproto.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const AppearanceDialog = @import("appearance_dialog.zig");
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const WeakRef = @import("../weak_ref.zig").WeakRef;

const log = std.log.scoped(.gtk_ghostty_window);
const a = std.heap.c_allocator;

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const SidebarMode = enum { activity, files, find, vault, sessions, feed, dock, machines, notifications };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the focus that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Self) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };

        pub const @"titlebar-style" = struct {
            pub const name = "titlebar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                TitlebarStyle,
                .{
                    .default = .native,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        TitlebarStyle,
                        .{
                            .getter = Self.getTitlebarStyle,
                        },
                    ),
                },
            );
        };

        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };

        pub const @"quick-terminal" = struct {
            pub const name = "quick-terminal";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "quick_terminal",
                    ),
                },
            );
        };

        pub const @"toolbar-style" = struct {
            pub const name = "toolbar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                adw.ToolbarStyle,
                .{
                    .default = .raised,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        adw.ToolbarStyle,
                        .{
                            .getter = Self.getToolbarStyle,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// Whether this window is a quick terminal. If it is then it
        /// behaves slightly differently under certain scenarios.
        quick_terminal: bool = false,

        /// The window decoration override. If this is not set then we'll
        /// inherit whatever the config has. This allows overriding the
        /// config on a per-window basis.
        window_decoration: ?configpkg.WindowDecoration = null,

        /// Binding group for our active tab.
        tab_bindings: *gobject.BindingGroup,

        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// State and logic for windowing protocol for a window.
        winproto: winprotopkg.Window,

        /// Kind of hacky to have this but this lets us know if we've
        /// initialized any single surface yet. We need this because we
        /// gate default size on this so that we don't resize the window
        /// after surfaces already exist.
        ///
        /// I think long term we can probably get rid of this by implementing
        /// a property or method that gets us all the surfaces in all the
        /// tabs and checking if we have zero or one that isn't initialized.
        ///
        /// For now, this logic is more similar to our legacy GTK side.
        surface_init: bool = false,

        /// A weak reference to a command palette.
        command_palette: WeakRef(CommandPalette) = .empty,

        /// Tab page that the context menu was opened for.
        /// setup by `setup-menu`.
        context_menu_page: ?*adw.TabPage = null,
        context_workspace: ?*Tab = null,

        workspace_serial: usize = 0,
        syncing_workspace: bool = false,
        automation_closing: bool = false,
        right_sidebar_mode: SidebarMode = .activity,
        multi_selected: std.ArrayList([32]u8) = .empty,
        dock_focus: bool = false,
        collapsed_groups: std.ArrayListUnmanaged([]u8) = .empty,

        // Template bindings
        workspace_list: *gtk.ListBox,
        tab_view: *adw.TabView,
        toast_overlay: *adw.ToastOverlay,
        main_popover: *gtk.PopoverMenu,
        right_sidebar_panel: *adw.ToolbarView,
        right_sidebar: *adw.OverlaySplitView,
        right_sidebar_title: *gtk.Label,
        activity_list: *gtk.ListBox,
        column_overview: *gtk.Revealer,
        column_overview_grid: *gtk.FlowBox,
        column_overview_title: *adw.WindowTitle,
        column_overview_search_bar: *gtk.SearchBar,
        column_overview_search: *gtk.SearchEntry,

        pub var offset: c_int = 0;
    };

    pub fn new(
        app: *Application,
        overrides: struct {
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *Self {
        const win = gobject.ext.newInstance(Self, .{
            .application = app,
        });

        if (overrides.title) |title| {
            // If the overrides have a title set, we set that immediately
            // so that any applications inspecting the window states see an
            // immediate title set when the window appears, rather than waiting
            // possibly a few event loop ticks for it to sync from the surface.
            win.as(gtk.Window).setTitle(title);
        }

        return win;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();

        const config = config: {
            if (priv.config) |config| break :config config.get();
            const app = Application.default();
            const config = app.getConfig();
            priv.config = config;
            break :config config.get();
        };

        // We initialize our windowing protocol to none because we can't
        // actually initialize this until we get realized.
        priv.winproto = .none;

        // Add our dev CSS class if we're in debug mode.
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        // Setup our tab binding group. This ensures certain properties
        // are only synced from the currently active tab.
        priv.tab_bindings = gobject.BindingGroup.new();
        priv.tab_bindings.bind("title", self.as(gobject.Object), "title", .{});

        // Set our window icon. We can't set this in the blueprint file
        // because its dependent on the build config.
        self.as(gtk.Window).setIconName(build_config.bundle_id);

        // Initialize our actions
        self.initActionMap();
        _ = priv.main_popover.addChild(
            AppearanceDialog.createSchemeSwitcher(Application.default()),
            "appearance-scheme",
        );

        const pages = priv.tab_view.getPages();
        defer pages.as(gobject.Object).unref();
        priv.workspace_list.bindModel(
            pages.as(gio.ListModel),
            &createWorkspaceRow,
            null,
            null,
        );
        priv.workspace_list.setHeaderFunc(workspaceGroupHeader, self, null);

        // Escape closes the column overview no matter what has focus;
        // the native AdwTabOverview behaves the same. Window-level
        // capture because the overlay's children may not hold focus.
        const overview_keys = gtk.EventControllerKey.new();
        overview_keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            overview_keys,
            *Self,
            columnOverviewKeyPressed,
            self,
            .{},
        );
        self.as(gtk.Widget).addController(overview_keys.as(gtk.EventController));

        const drop = gtk.DropTarget.new(gobject.ext.typeFor(c_int), .{ .move = true });
        _ = gtk.DropTarget.signals.drop.connect(drop, *Self, workspaceDrop, self, .{});
        _ = gtk.DropTarget.signals.motion.connect(drop, *Self, workspaceDropMotion, self, .{});
        _ = gtk.DropTarget.signals.leave.connect(drop, *Self, workspaceDropLeave, self, .{});
        priv.workspace_list.as(gtk.Widget).addController(drop.as(gtk.EventController));

        // Start states based on config.
        if (config.maximize) self.as(gtk.Window).maximize();
        if (config.fullscreen != .false) self.as(gtk.Window).fullscreen();

        // If we have an explicit title set, we set that immediately
        // so that any applications inspecting the window states see
        // an immediate title set when the window appears, rather than
        // waiting possibly a few event loop ticks for it to sync from
        // the surface.
        if (config.title) |title| {
            self.as(gtk.Window).setTitle(title);
        }

        // We always sync our appearance at the end because loading our
        // config and such can affect our bindings which are setup initially
        // in initTemplate.
        self.syncAppearance();

        // We need to do this so that the title initializes properly,
        // I think because its a dynamic getter.
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
        self.refreshActivity();
    }

    /// Setup our action map.
    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("about", actionAbout, null),
            .init("appearance", actionAppearance, null),
            .init("close", actionClose, null),
            .init("close-terminal", actionCloseTerminal, null),
            .init("close-tab", actionCloseTab, s_variant_type),
            .init("workspace-pin", actionWorkspacePin, null),
            .init("workspace-mute", actionWorkspaceMute, null),
            .init("workspace-group", actionWorkspaceGroup, null),
            .init("workspace-close", actionWorkspaceClose, null),
            .init("workspace-task-status", actionWorkspaceTaskStatus, s_variant_type),
            .init("show-activity", actionShowActivity, null),
            .init("toggle-column-overview", actionToggleColumnOverview, null),

            .init("hide-right-sidebar", actionHideRightSidebar, null),
            .init("new-tab", actionNewTab, null),
            .init("new-window", actionNewWindow, null),
            .init("prompt-surface-title", actionPromptSurfaceTitle, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-context-tab-title", actionPromptContextTabTitle, null),
            .init("ring-bell", actionRingBell, null),
            .init("split-right", actionSplitRight, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("split-down", actionSplitDown, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            // TODO: accept the surface that toggled the command palette
            .init("toggle-command-palette", actionToggleCommandPalette, null),
            .init("toggle-inspector", actionToggleInspector, null),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Winproto backend for this window.
    pub fn winproto(self: *Self) *winprotopkg.Window {
        return &self.private().winproto;
    }

    /// Create a new tab with the given parent. The tab will be inserted
    /// at the position dictated by the `window-new-tab-position` config.
    /// The new tab will be selected.
    pub fn newTab(self: *Self, parent_: ?*CoreSurface) void {
        _ = self.newTabPage(parent_, .tab, .none);
    }

    pub fn newEmptyGroup(self: *Self) void {
        const tab = self.automationNewTab(null, null);
        const automation = @import("../automation.zig");
        const key = automation.randomId();
        automation.assignWorkspaceGroup(tab, &key, "Group");
    }

    pub fn groupWorkspaces(self: *Self, anchor: *Tab) void {
        const automation = @import("../automation.zig");
        const tabs = self.selectedTabs(anchor);
        defer a.free(tabs);
        const key = automation.randomId();
        for (tabs) |tab| automation.assignWorkspaceGroup(tab, &key, "Group");
        self.clearMultiSelect();
        self.refreshWorkspaceRows();
    }

    pub fn automationNewTab(self: *Self, command: ?configpkg.Command, cwd: ?[:0]const u8) *Tab {
        const page = self.newTabPage(null, .tab, .{ .command = command, .working_directory = cwd });
        return gobject.ext.cast(Tab, page.getChild()).?;
    }

    pub fn automationCloseTab(self: *Self, tab: *Tab) void {
        self.private().automation_closing = true;
        defer self.private().automation_closing = false;
        const view = self.getTabView();
        view.closePage(view.getPage(tab.as(gtk.Widget)));
    }
    const ActivityButton = struct {
        notification_id: [32]u8,

        fn destroy(ptr: ?*anyopaque) callconv(.c) void {
            a.destroy(@as(*ActivityButton, @ptrCast(@alignCast(ptr.?))));
        }

        fn clicked(_: *gtk.Button, self: *ActivityButton) callconv(.c) void {
            _ = @import("../automation.zig").openActivity(&self.notification_id);
        }
    };

    const FeedAction = struct {
        id: [32]u8,
        verb: [:0]const u8,

        fn destroy(ptr: ?*anyopaque) callconv(.c) void {
            a.destroy(@as(*FeedAction, @ptrCast(@alignCast(ptr.?))));
        }

        fn clicked(_: *gtk.Button, self: *FeedAction) callconv(.c) void {
            @import("../automation.zig").replyFeed(&self.id, self.verb);
        }
    };

    pub fn rightSidebarVisible(self: *Self) bool {
        return self.private().right_sidebar.getShowSidebar() != 0;
    }

    pub fn rightSidebarPanelWidth(self: *Self) c_int {
        return self.private().right_sidebar_panel.as(gtk.Widget).getWidth();
    }

    pub fn rightSidebarPanelMapped(self: *Self) bool {
        return self.private().right_sidebar_panel.as(gtk.Widget).getMapped() != 0;
    }

    pub fn rightSidebarPanelX(self: *Self) c_int {
        var x: f64 = 0;
        var y: f64 = 0;
        _ = self.private().right_sidebar_panel.as(gtk.Widget).translateCoordinates(
            self.as(gtk.Widget),
            0,
            0,
            &x,
            &y,
        );
        return @intFromFloat(x);
    }

    pub fn rightSidebarCollapsed(self: *Self) bool {
        return self.private().right_sidebar.getCollapsed() != 0;
    }

    pub fn rightSidebarMode(self: *Self) SidebarMode {
        return self.private().right_sidebar_mode;
    }

    pub fn setRightSidebarVisible(self: *Self, visible: bool) void {
        self.private().right_sidebar.setShowSidebar(@intFromBool(visible));
    }

    pub fn setRightSidebarMode(self: *Self, mode: SidebarMode, focus_sidebar: bool) void {
        const priv = self.private();
        priv.right_sidebar_mode = mode;
        const title: [:0]const u8 = switch (mode) {
            .activity => "Activity",
            .files => "Files",
            .find => "Find",
            .vault => "Vault",
            .sessions => "Sessions",
            .feed => "Feed",
            .dock => "Dock",
            .machines => "Machines",
            .notifications => "Notifications",
        };
        priv.right_sidebar_title.setLabel(title);
        priv.right_sidebar.setShowSidebar(1);
        self.refreshActivity();
        if (focus_sidebar) _ = priv.activity_list.as(gtk.Widget).grabFocus();
    }

    pub fn setDockFocus(self: *Self, focused: bool) void {
        self.private().dock_focus = focused;
    }

    pub fn focusRightSidebar(self: *Self) void {
        _ = self.private().activity_list.as(gtk.Widget).grabFocus();
    }

    fn appendActivityHeading(list: *gtk.ListBox, text: [:0]const u8) void {
        const label = gtk.Label.new(text);
        label.setXalign(0);
        label.as(gtk.Widget).addCssClass("heading");
        label.as(gtk.Widget).setMarginTop(12);
        label.as(gtk.Widget).setMarginStart(12);
        label.as(gtk.Widget).setMarginEnd(12);
        list.append(label.as(gtk.Widget));
    }

    fn appendActivityText(list: *gtk.ListBox, text: []const u8, dim: bool) void {
        const value = a.dupeZ(u8, text) catch return;
        defer a.free(value);
        const label = gtk.Label.new(value);
        label.setXalign(0);
        label.setWrap(1);
        if (dim) label.as(gtk.Widget).addCssClass("dim-label");
        label.as(gtk.Widget).setMarginTop(4);
        label.as(gtk.Widget).setMarginStart(12);
        label.as(gtk.Widget).setMarginEnd(12);
        list.append(label.as(gtk.Widget));
    }

    pub fn refreshActivity(self: *Self) void {
        const priv = self.private();
        while (priv.activity_list.as(gtk.Widget).getFirstChild()) |child|
            priv.activity_list.remove(child);

        if (priv.right_sidebar_mode == .feed) {
            self.refreshFeed();
            return;
        }
        if (priv.right_sidebar_mode == .dock) {
            self.refreshDock();
            return;
        }
        if (priv.right_sidebar_mode == .notifications) {
            self.refreshNotifications();
            return;
        }
        if (priv.right_sidebar_mode == .find) {
            self.refreshFind();
            return;
        }
        if (priv.right_sidebar_mode == .sessions) {
            self.refreshSessions();
            return;
        }
        if (priv.right_sidebar_mode == .machines) {
            self.refreshMachines();
            return;
        }
        if (priv.right_sidebar_mode == .files) {
            self.refreshCustomSidebars();
            return;
        }

        if (priv.right_sidebar_mode != .activity) {
            const name = @tagName(priv.right_sidebar_mode);

            const label_text = std.fmt.allocPrintSentinel(a, "{s} tools appear here.", .{name}, 0) catch return;
            defer a.free(label_text);
            appendActivityText(priv.activity_list, label_text, true);
            return;
        }

        const automation = @import("../automation.zig");
        const metadata_view = automation.sidebarMetadata(a, self) catch return;
        defer metadata_view.deinit(a);
        const items = automation.activityItems(a, self) catch return;
        defer a.free(items);
        if (metadata_view.statuses.len == 0 and metadata_view.progress == null and metadata_view.logs.len == 0 and metadata_view.git_branch == null and metadata_view.pull_request == null and metadata_view.listening_ports.len == 0 and items.len == 0) {
            appendActivityText(priv.activity_list, "No activity", true);
            return;
        }

        if (metadata_view.statuses.len > 0) {
            appendActivityHeading(priv.activity_list, "Status");
            const row = gtk.Box.new(.horizontal, 6);
            row.setHomogeneous(0);
            row.as(gtk.Widget).setMarginTop(4);
            row.as(gtk.Widget).setMarginStart(12);
            row.as(gtk.Widget).setMarginEnd(12);
            for (metadata_view.statuses) |item| {
                const text = if (item.icon) |icon|
                    std.fmt.allocPrintSentinel(a, "{s} {s}", .{ icon, item.text }, 0) catch continue
                else
                    a.dupeZ(u8, item.text) catch continue;
                defer a.free(text);
                const pill = gtk.Label.new(text);
                pill.as(gtk.Widget).addCssClass("card");
                pill.as(gtk.Widget).setMarginTop(2);
                pill.as(gtk.Widget).setMarginBottom(2);
                pill.as(gtk.Widget).setMarginStart(4);
                pill.as(gtk.Widget).setMarginEnd(4);
                row.append(pill.as(gtk.Widget));
            }
            priv.activity_list.append(row.as(gtk.Widget));
        }

        if (metadata_view.progress) |value| {
            appendActivityHeading(priv.activity_list, "Progress");
            const progress = gtk.ProgressBar.new();
            progress.setFraction(@as(f64, @floatFromInt(value)) / 100.0);
            progress.setShowText(1);
            if (metadata_view.progress_label) |label| {
                const text = std.fmt.allocPrintSentinel(a, "{s} — {d}%", .{ label, value }, 0) catch return;
                defer a.free(text);
                progress.setText(text);
            }
            progress.as(gtk.Widget).setMarginTop(4);
            progress.as(gtk.Widget).setMarginStart(12);
            progress.as(gtk.Widget).setMarginEnd(12);
            priv.activity_list.append(progress.as(gtk.Widget));
        }

        if (metadata_view.git_branch != null or metadata_view.pull_request != null) {
            appendActivityHeading(priv.activity_list, "Source");
            if (metadata_view.git_branch) |branch| {
                const text = std.fmt.allocPrintSentinel(a, "git: {s}{s}", .{
                    branch,
                    if (metadata_view.git_dirty) " • modified" else "",
                }, 0) catch return;
                defer a.free(text);
                appendActivityText(priv.activity_list, text, false);
            }
            if (metadata_view.pull_request) |request| {
                const text = std.fmt.allocPrintSentinel(a, "#{d} {s} · {s}", .{
                    request.number,
                    request.label,
                    request.status,
                }, 0) catch return;
                defer a.free(text);
                appendActivityText(priv.activity_list, text, false);
            }
        }

        if (metadata_view.listening_ports.len > 0) {
            appendActivityHeading(priv.activity_list, "Listening ports");
            for (metadata_view.listening_ports) |port| {
                const text = std.fmt.allocPrintSentinel(a, "localhost:{d}", .{port}, 0) catch continue;
                defer a.free(text);
                appendActivityText(priv.activity_list, text, false);
            }
        }

        if (metadata_view.logs.len > 0) {
            appendActivityHeading(priv.activity_list, "Recent logs");
            for (metadata_view.logs) |item| {
                const text = std.fmt.allocPrintSentinel(a, "{s}: {s}", .{ item.level, item.text }, 0) catch continue;
                defer a.free(text);
                appendActivityText(priv.activity_list, text, true);
            }
        }

        if (items.len > 0) appendActivityHeading(priv.activity_list, "Notifications");
        for (items) |item| {
            const button = gtk.Button.new();
            button.as(gtk.Widget).addCssClass("flat");
            const content = gtk.Box.new(.vertical, 3);
            content.as(gtk.Widget).setMarginTop(8);
            content.as(gtk.Widget).setMarginBottom(8);
            content.as(gtk.Widget).setMarginStart(8);
            content.as(gtk.Widget).setMarginEnd(8);
            const title_text = if (item.read)
                a.dupeZ(u8, item.title) catch continue
            else
                std.fmt.allocPrintSentinel(a, "● {s}", .{item.title}, 0) catch continue;
            defer a.free(title_text);
            const title = gtk.Label.new(title_text);
            title.setXalign(0);
            title.setWrap(1);
            if (!item.read) title.as(gtk.Widget).addCssClass("heading");
            content.append(title.as(gtk.Widget));
            if (item.subtitle.len > 0) {
                const subtitle_text = a.dupeZ(u8, item.subtitle) catch continue;
                defer a.free(subtitle_text);
                const subtitle = gtk.Label.new(subtitle_text);
                subtitle.setXalign(0);
                subtitle.setWrap(1);
                subtitle.as(gtk.Widget).addCssClass("caption");
                content.append(subtitle.as(gtk.Widget));
            }
            if (item.body.len > 0) {
                const body_text = a.dupeZ(u8, item.body) catch continue;
                defer a.free(body_text);
                const body = gtk.Label.new(body_text);
                body.setXalign(0);
                body.setWrap(1);
                body.as(gtk.Widget).addCssClass("dim-label");
                content.append(body.as(gtk.Widget));
            }
            button.setChild(content.as(gtk.Widget));
            const state = a.create(ActivityButton) catch continue;
            state.* = .{ .notification_id = item.notification_id[0..32].* };
            button.as(gobject.Object).setDataFull("colm-activity", state, ActivityButton.destroy);
            _ = gtk.Button.signals.clicked.connect(button, *ActivityButton, ActivityButton.clicked, state, .{});
            priv.activity_list.append(button.as(gtk.Widget));
        }
    }

    fn refreshNotifications(self: *Self) void {
        const priv = self.private();
        const automation = @import("../automation.zig");
        const items = automation.activityItems(a, self) catch return;
        defer a.free(items);
        if (items.len == 0) {
            appendActivityText(priv.activity_list, "No notifications", true);
            return;
        }
        var index = items.len;
        while (index > 0) {
            index -= 1;
            const item = items[index];
            const button = gtk.Button.new();
            button.as(gtk.Widget).addCssClass("flat");
            const label_src = std.fmt.allocPrintSentinel(a, "{s}{s}{s}", .{
                if (item.read) "" else "● ",
                item.title,
                if (item.subtitle.len > 0) item.subtitle else item.body,
            }, 0) catch continue;
            defer a.free(label_src);
            const title = if (item.subtitle.len > 0)
                std.fmt.allocPrintSentinel(a, "{s}{s} — {s}", .{
                    if (item.read) "" else "● ",
                    item.title,
                    item.subtitle,
                }, 0) catch continue
            else
                std.fmt.allocPrintSentinel(a, "{s}{s}", .{
                    if (item.read) "" else "● ",
                    item.title,
                }, 0) catch continue;
            defer a.free(title);
            const label = gtk.Label.new(title);
            label.setXalign(0);
            label.setWrap(1);
            if (!item.read) label.as(gtk.Widget).addCssClass("heading");
            button.setChild(label.as(gtk.Widget));
            const state = a.create(ActivityButton) catch continue;
            state.* = .{ .notification_id = item.notification_id[0..32].* };
            button.as(gobject.Object).setDataFull("colm-activity", state, ActivityButton.destroy);
            _ = gtk.Button.signals.clicked.connect(button, *ActivityButton, ActivityButton.clicked, state, .{});
            priv.activity_list.append(button.as(gtk.Widget));
        }
    }

    fn refreshFind(self: *Self) void {
        const priv = self.private();
        const entry = gtk.Entry.new();
        entry.setPlaceholderText("Find in directory (Enter)");
        entry.as(gtk.Widget).setMarginStart(8);
        entry.as(gtk.Widget).setMarginEnd(8);
        entry.as(gtk.Widget).setMarginTop(8);
        _ = gtk.Entry.signals.activate.connect(entry, *Self, findActivated, self, .{});
        priv.activity_list.append(entry.as(gtk.Widget));
        appendActivityText(priv.activity_list, "ripgrep the current workspace directory.", true);
    }

    fn findActivated(entry: *gtk.Entry, self: *Self) callconv(.c) void {
        const query = std.mem.span(entry.as(gtk.Editable).getText());
        if (query.len == 0) return;
        const surface = self.getActiveSurface() orelse return;
        const cwd = surface.getPwd() orelse @import("../automation.zig").localDirectory(surface) orelse return;
        var child = std.process.Child.init(&.{ "rg", "-n", "--max-count", "40", "--max-filesize", "1M", query, cwd }, a);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {
            self.addToast("rg is not installed");
            return;
        };
        const stdout = child.stdout orelse return;
        const bytes = stdout.readToEndAlloc(a, 64 * 1024) catch return;
        defer a.free(bytes);
        _ = child.wait() catch {};
        const priv = self.private();
        while (priv.activity_list.as(gtk.Widget).getFirstChild()) |node|
            priv.activity_list.remove(node);
        self.refreshFind();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            count += 1;
            if (count > 40) break;
            appendActivityText(priv.activity_list, line, false);
        }
        if (count == 0) appendActivityText(priv.activity_list, "No matches", true);
    }

    fn refreshSessions(self: *Self) void {
        const priv = self.private();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const sessions = @import("../agent_store.zig").listSessions(alloc) catch {
            appendActivityText(priv.activity_list, "No agent sessions", true);
            return;
        };
        if (sessions != .array or sessions.array.items.len == 0) {
            appendActivityText(priv.activity_list, "No agent sessions", true);
            return;
        }
        appendActivityHeading(priv.activity_list, "Agent sessions");
        for (sessions.array.items) |item| {
            if (item != .object) continue;
            const provider = if (item.object.get("provider")) |value| if (value == .string) value.string else "?" else "?";
            const session_id = if (item.object.get("session_id")) |value| if (value == .string) value.string else "" else "";
            const text = std.fmt.allocPrintSentinel(a, "{s}  {s}", .{ provider, session_id }, 0) catch continue;
            defer a.free(text);
            appendActivityText(priv.activity_list, text, false);
        }
    }

    fn refreshMachines(self: *Self) void {
        const priv = self.private();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const records = @import("../feature_store.zig").list(alloc, "machines") catch {
            appendActivityText(priv.activity_list, "No machines registered", true);
            return;
        };
        if (records != .array or records.array.items.len == 0) {
            appendActivityText(priv.activity_list, "No machines registered", true);
            return;
        }
        appendActivityHeading(priv.activity_list, "Machines");
        for (records.array.items) |item| {
            if (item != .object) continue;
            const key = if (item.object.get("key")) |value| if (value == .string) value.string else "?" else "?";
            appendActivityText(priv.activity_list, key, false);
        }
    }

    const ColumnTile = struct {
        window: *Self,
        tab: *Tab,
        surface: *Surface,
        title: [:0]u8,

        fn destroy(ptr: ?*anyopaque) callconv(.c) void {
            const self: *ColumnTile = @ptrCast(@alignCast(ptr.?));
            self.tab.as(gobject.Object).unref();
            self.surface.as(gobject.Object).unref();
            a.free(self.title);
            a.destroy(self);
        }

        fn activate(self: *ColumnTile) void {
            self.window.setColumnOverviewVisible(false);
            self.tab.getSplitTree().automationFocus(self.surface) catch {};
        }

        fn closeClicked(_: *gtk.Button, self: *ColumnTile) callconv(.c) void {
            self.tab.getSplitTree().automationClosePane(self.surface) catch {};
        }
    };

    /// Fill the overview grid with one live thumbnail per column of the
    /// active workspace. Widget structure, sizing, and styling mirror
    /// libadwaita's AdwTabThumbnail/AdwTabGrid so this looks exactly
    /// like the native tab overview, but over columns.
    fn populateColumnOverview(self: *Self) void {
        const priv = self.private();
        const grid = priv.column_overview_grid;
        while (grid.as(gtk.Widget).getFirstChild()) |child| grid.remove(child);
        const page = priv.tab_view.getSelectedPage() orelse return;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
        const split_tree = tab.getSplitTree();
        const count = split_tree.surfaceCount();

        // AdwTabGrid interpolates the natural thumbnail width between
        // 200 (grid width <= 360) and 360 (grid width >= 2560).
        const overview_width = priv.column_overview.as(gtk.Widget).getWidth();
        const grid_width: f64 = if (overview_width > 0)
            @floatFromInt(overview_width)
        else
            1280;
        const ratio = std.math.clamp((grid_width - 360.0) / (2560.0 - 360.0), 0.0, 1.0);
        const thumb_width = 200.0 + (360.0 - 200.0) * ratio;

        var previous_pane: ?*gobject.Object = null;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const surface = split_tree.surfaceAt(index) orelse continue;
            const pane = split_tree.paneObject(surface) orelse continue;
            if (pane == previous_pane) continue;
            previous_pane = pane;
            const active = split_tree.paneActiveSurface(surface) orelse surface;
            const pane_widget = gobject.ext.cast(gtk.Widget, pane) orelse continue;

            // Thumbnail keeps the column's own aspect ratio, like the
            // native overview keeps each page's aspect ratio.
            const pane_w = pane_widget.getWidth();
            const pane_h = pane_widget.getHeight();
            const aspect: f64 = if (pane_w > 0 and pane_h > 0)
                @as(f64, @floatFromInt(pane_h)) / @as(f64, @floatFromInt(pane_w))
            else
                2.0 / 3.0;
            const thumb_height = thumb_width * aspect;

            // AdwTabThumbnail: vertical box (spacing 6, margin 6) with a
            // .card overlay (overflow hidden) holding a fill-fit picture,
            // then a centered icon+title box.
            const tile = gtk.Box.new(.vertical, 6);
            tile.as(gtk.Widget).addCssClass("column-thumbnail");
            tile.as(gtk.Widget).setMarginTop(6);
            tile.as(gtk.Widget).setMarginBottom(6);
            tile.as(gtk.Widget).setMarginStart(6);
            tile.as(gtk.Widget).setMarginEnd(6);
            const card = gtk.Overlay.new();
            card.as(gtk.Widget).addCssClass("card");
            card.as(gtk.Widget).setOverflow(.hidden);
            const paintable = gtk.WidgetPaintable.new(pane_widget);
            defer paintable.as(gobject.Object).unref();
            const picture = gtk.Picture.newForPaintable(paintable.as(gdk.Paintable));
            picture.setContentFit(.fill);
            picture.as(gtk.Widget).setVexpand(1);
            picture.as(gtk.Widget).setSizeRequest(
                @intFromFloat(thumb_width),
                @intFromFloat(thumb_height),
            );
            card.setChild(picture.as(gtk.Widget));
            // FlowBox honors the paintable's natural size (the live
            // widget's full size); AdwTabGrid instead allocates exactly.
            // Clamp both axes to the computed thumbnail size.
            const hclamp = adw.Clamp.new();
            hclamp.setMaximumSize(@intFromFloat(thumb_width));
            hclamp.setChild(card.as(gtk.Widget));
            const vclamp = adw.Clamp.new();
            vclamp.as(gtk.Orientable).setOrientation(.vertical);
            vclamp.setMaximumSize(@intFromFloat(thumb_height));
            vclamp.setChild(hclamp.as(gtk.Widget));
            tile.append(vclamp.as(gtk.Widget));
            const title_box = gtk.Box.new(.horizontal, 6);
            title_box.as(gtk.Widget).addCssClass("icon-title-box");
            title_box.as(gtk.Widget).setHalign(.center);
            const title_text = a.dupeZ(u8, active.getEffectiveTitle() orelse "Terminal") catch continue;
            errdefer a.free(title_text);
            const title = gtk.Label.new(title_text);
            title.setEllipsize(.end);
            title.setMaxWidthChars(20);
            title_box.append(title.as(gtk.Widget));
            tile.append(title_box.as(gtk.Widget));
            const state = a.create(ColumnTile) catch {
                a.free(title_text);
                continue;
            };
            _ = tab.as(gobject.Object).ref();
            _ = active.as(gobject.Object).ref();
            state.* = .{ .window = self, .tab = tab, .surface = active, .title = title_text };
            // Close button in the card's top-right corner, like the
            // native thumbnail's tab-close-button.
            const close = gtk.Button.newFromIconName("window-close-symbolic");
            close.as(gtk.Widget).addCssClass("image-button");
            close.as(gtk.Widget).setValign(.start);
            close.as(gtk.Widget).setHalign(.end);
            close.as(gtk.Widget).setCanFocus(0);
            close.as(gtk.Widget).setTooltipText("Close Column");
            _ = gtk.Button.signals.clicked.connect(close, *ColumnTile, ColumnTile.closeClicked, state, .{});
            card.addOverlay(close.as(gtk.Widget));
            tile.as(gobject.Object).setDataFull("colm-column-tile", state, ColumnTile.destroy);
            grid.append(tile.as(gtk.Widget));
        }

        var title_buf: [32]u8 = undefined;
        const columns = grid_columns: {
            var n: usize = 0;
            var child = grid.as(gtk.Widget).getFirstChild();
            while (child) |widget| : (child = widget.getNextSibling()) n += 1;
            break :grid_columns n;
        };
        const title_z = if (columns == 1)
            std.fmt.bufPrintZ(&title_buf, "{d} Column", .{columns}) catch "Columns"
        else
            std.fmt.bufPrintZ(&title_buf, "{d} Columns", .{columns}) catch "Columns";
        priv.column_overview_title.setTitle(title_z);
    }
    fn columnOverviewChildActivated(
        _: *gtk.FlowBox,
        child: *gtk.FlowBoxChild,
        _: *Self,
    ) callconv(.c) void {
        const tile_widget = child.getChild() orelse return;
        const data = tile_widget.as(gobject.Object).getData("colm-column-tile") orelse return;
        const tile: *ColumnTile = @ptrCast(@alignCast(data));
        tile.activate();
    }

    fn setColumnOverviewVisible(self: *Self, visible: bool) void {
        const priv = self.private();
        if (!visible) {
            priv.column_overview.setRevealChild(0);
            priv.column_overview.as(gtk.Widget).setVisible(0);
            if (self.getActiveSurface()) |surface| surface.grabFocus();
            return;
        }
        self.populateColumnOverview();
        priv.column_overview_search.as(gtk.Editable).setText("");
        priv.column_overview_search_bar.setSearchMode(0);
        priv.column_overview.as(gtk.Widget).setVisible(1);
        priv.column_overview.setRevealChild(1);
        // Focus the first tile once the overlay is mapped so keyboard
        // navigation works; grabbing before the map would fail.
        _ = glib.idleAdd(columnOverviewFocusIdle, self);
    }

    fn columnOverviewKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        _: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        if (priv.column_overview.getRevealChild() == 0) return 0;
        // Let the search bar's own key capture handle Escape while the
        // search is open, like the native overview.
        if (priv.column_overview_search_bar.getSearchMode() != 0) return 0;
        if (keyval != gdk.KEY_Escape) return 0;
        self.setColumnOverviewVisible(false);
        return 1;
    }

    fn columnOverviewFocusIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        if (priv.column_overview.getRevealChild() != 0) {
            if (priv.column_overview_grid.as(gtk.Widget).getFirstChild()) |child|
                _ = child.grabFocus();
        }
        return 0;
    }

    fn columnOverviewSearchChanged(
        entry: *gtk.SearchEntry,
        self: *Self,
    ) callconv(.c) void {
        const query = std.mem.span(entry.as(gtk.Editable).getText());
        const grid = self.private().column_overview_grid;
        var child = grid.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            const flow_child = gobject.ext.cast(gtk.FlowBoxChild, widget) orelse continue;
            const tile_widget = flow_child.getChild() orelse continue;
            const data = tile_widget.as(gobject.Object).getData("colm-column-tile") orelse continue;
            const tile: *ColumnTile = @ptrCast(@alignCast(data));
            const visible = query.len == 0 or
                std.ascii.indexOfIgnoreCase(tile.title, query) != null;
            widget.setVisible(@intFromBool(visible));
        }
    }

    fn columnOverviewNewClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.setColumnOverviewVisible(false);
        const page = self.private().tab_view.getSelectedPage() orelse return;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
        tab.getSplitTree().newSplit(.right, null, .{}) catch {};
    }

    fn refreshCustomSidebars(self: *Self) void {
        const priv = self.private();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const cwd = if (self.getActiveSurface()) |surface|
            surface.getPwd() orelse @import("../automation.zig").localDirectory(surface)
        else
            null;
        const sidebars = @import("../notify_policy.zig").loadSidebars(alloc, cwd);
        if (sidebars.len == 0) {
            appendActivityText(priv.activity_list, "No customSidebars in cmux.json", true);
            return;
        }
        appendActivityHeading(priv.activity_list, "Extension sidebars");
        for (sidebars) |bar| {
            const button = gtk.Button.newWithLabel(tryAllocZ(bar.title) orelse continue);
            const payload = a.create(SidebarOpen) catch continue;
            const url_z = a.dupeZ(u8, bar.url) catch {
                a.destroy(payload);
                continue;
            };
            payload.* = .{ .window = self, .url = url_z };
            button.as(gobject.Object).setDataFull("colm-sidebar-open", payload, SidebarOpen.destroy);
            _ = gtk.Button.signals.clicked.connect(button, *SidebarOpen, SidebarOpen.clicked, payload, .{});
            priv.activity_list.append(button.as(gtk.Widget));
        }
    }

    fn tryAllocZ(text: []const u8) ?[:0]const u8 {
        return a.dupeZ(u8, text) catch null;
    }

    const SidebarOpen = struct {
        window: *Self,
        url: [:0]u8,

        fn destroy(ptr: ?*anyopaque) callconv(.c) void {
            const self: *SidebarOpen = @ptrCast(@alignCast(ptr.?));
            a.free(self.url);
            a.destroy(self);
        }

        fn clicked(_: *gtk.Button, self: *SidebarOpen) callconv(.c) void {
            const page = self.window.getTabView().getSelectedPage() orelse return;
            const workspace = gobject.ext.cast(Tab, page.getChild()) orelse return;
            @import("../automation.zig").openBrowserColumn(workspace, self.url);
        }
    };

    fn refreshFeed(self: *Self) void {
        const priv = self.private();
        const cards = @import("../automation.zig").feedCards();
        if (cards.len == 0) {
            appendActivityText(priv.activity_list, "No feed cards", true);
            return;
        }
        for (cards) |card| {
            const box = gtk.Box.new(.vertical, 4);
            box.as(gtk.Widget).addCssClass("card");
            box.as(gtk.Widget).setMarginStart(8);
            box.as(gtk.Widget).setMarginEnd(8);
            box.as(gtk.Widget).setMarginTop(6);
            const heading_text = std.fmt.allocPrintSentinel(a, "{s} · {s}", .{ card.kind, card.status }, 0) catch continue;
            defer a.free(heading_text);
            const heading = gtk.Label.new(heading_text);
            heading.setXalign(0);
            heading.as(gtk.Widget).addCssClass("heading");
            box.append(heading.as(gtk.Widget));
            const title = a.dupeZ(u8, card.title) catch continue;
            defer a.free(title);
            const title_label = gtk.Label.new(title);
            title_label.setXalign(0);
            title_label.setWrap(1);
            box.append(title_label.as(gtk.Widget));
            if (card.body.len > 0) {
                const body = a.dupeZ(u8, card.body) catch continue;
                defer a.free(body);
                const body_label = gtk.Label.new(body);
                body_label.setXalign(0);
                body_label.setWrap(1);
                body_label.as(gtk.Widget).addCssClass("dim-label");
                box.append(body_label.as(gtk.Widget));
            }
            if (std.mem.eql(u8, card.status, "pending")) {
                const actions = gtk.Box.new(.horizontal, 4);
                const verbs: []const struct { verb: [:0]const u8, label: [:0]const u8 } = if (std.mem.eql(u8, card.kind, "permission"))
                    &.{
                        .{ .verb = "once", .label = "Once" },
                        .{ .verb = "always", .label = "Always" },
                        .{ .verb = "all_tools", .label = "All tools" },
                        .{ .verb = "bypass", .label = "Bypass" },
                        .{ .verb = "deny", .label = "Deny" },
                    }
                else if (std.mem.eql(u8, card.kind, "exit_plan"))
                    &.{
                        .{ .verb = "ultraplan", .label = "Ultraplan" },
                        .{ .verb = "manual", .label = "Manual" },
                        .{ .verb = "auto", .label = "Auto" },
                    }
                else if (std.mem.eql(u8, card.kind, "question"))
                    &.{.{ .verb = "answer", .label = "Answer" }}
                else
                    &.{.{ .verb = "once", .label = "Ack" }};
                for (verbs) |entry| {
                    const button = gtk.Button.newWithLabel(entry.label);
                    button.as(gtk.Widget).addCssClass("flat");
                    const action = a.create(FeedAction) catch continue;
                    action.* = .{ .id = card.id, .verb = entry.verb };
                    button.as(gobject.Object).setDataFull("colm-feed-action", action, FeedAction.destroy);
                    _ = gtk.Button.signals.clicked.connect(button, *FeedAction, FeedAction.clicked, action, .{});
                    actions.append(button.as(gtk.Widget));
                }
                box.append(actions.as(gtk.Widget));
            }
            priv.activity_list.append(box.as(gtk.Widget));
        }
    }

    fn refreshDock(self: *Self) void {
        const priv = self.private();
        const box = gtk.Box.new(.vertical, 6);
        box.as(gtk.Widget).setMarginStart(8);
        box.as(gtk.Widget).setMarginEnd(8);
        box.as(gtk.Widget).setMarginTop(8);
        const kinds = [_]struct { label: [:0]const u8, kind: u8 }{
            .{ .label = "New terminal column", .kind = 0 },
            .{ .label = "New browser column", .kind = 1 },
        };

        for (kinds) |entry| {
            const button = gtk.Button.newWithLabel(entry.label);
            const action = a.create(DockAction) catch continue;
            action.* = .{ .window = self, .kind = entry.kind };
            button.as(gobject.Object).setDataFull("colm-dock-action", action, DockAction.destroy);
            _ = gtk.Button.signals.clicked.connect(button, *DockAction, DockAction.clicked, action, .{});
            box.append(button.as(gtk.Widget));
        }
        priv.activity_list.append(box.as(gtk.Widget));
        appendActivityText(priv.activity_list, "Adds a column on this workspace’s niri strip — same as New Terminal, not a nested dock tree.", true);
    }

    const DockAction = struct {
        window: *Self,
        kind: u8,

        fn destroy(ptr: ?*anyopaque) callconv(.c) void {
            a.destroy(@as(*DockAction, @ptrCast(@alignCast(ptr.?))));
        }

        fn clicked(_: *gtk.Button, self: *DockAction) callconv(.c) void {
            self.window.runDockAction(self.kind);
        }
    };

    fn runDockAction(self: *Self, kind: u8) void {
        self.private().dock_focus = true;
        const page = self.getTabView().getSelectedPage() orelse return;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
        const automation = @import("../automation.zig");
        if (kind == 1) {
            automation.createDockBrowser(tab);
        } else if (kind == 3) {
            tab.getSplitTree().newSplit(.down, null, .{}) catch return;
            if (tab.getActiveSurface()) |surface| automation.markDock(surface);
        } else {
            tab.getSplitTree().newSplit(.right, null, .{}) catch return;
            if (tab.getActiveSurface()) |surface| automation.markDock(surface);
        }
        self.refreshActivity();
    }

    fn actionHideRightSidebar(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.setRightSidebarVisible(false);
    }
    fn actionShowActivity(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.setRightSidebarMode(.activity, true);
    }
    fn actionToggleColumnOverview(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        self.toggleColumnOverview();
    }

    pub fn newTabForWindow(
        self: *Self,
        parent_: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) void {
        _ = self.newTabPage(
            parent_,
            .window,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }

    fn newTabPage(
        self: *Self,
        parent_: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *adw.TabPage {
        const priv: *Private = self.private();
        const tab_view = priv.tab_view;
        const previous = if (tab_view.getSelectedPage()) |selected|
            gobject.ext.cast(Tab, selected.getChild())
        else
            null;

        // Create our new tab object
        const tab = Tab.new(
            priv.config,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );

        priv.workspace_serial += 1;
        var name_buf: [64]u8 = undefined;
        const workspace_name = std.fmt.bufPrintZ(
            &name_buf,
            "Workspace {d}",
            .{priv.workspace_serial},
        ) catch unreachable;
        tab.setTitleOverride(workspace_name);
        if (overrides.working_directory) |cwd| {
            const base = std.fs.path.basename(cwd);
            if (base.len > 0 and base.len < 60) {
                var auto: [64]u8 = undefined;
                const named = std.fmt.bufPrintZ(&auto, "{s}", .{base}) catch workspace_name;
                tab.setTitleOverride(named);
            }
        }

        if (parent_) |p| {
            // For a new window's first tab, inherit the parent's initial size hints.
            if (context == .window) {
                surfaceInit(p.rt_surface.gobj(), self);
            }
            tab.setParentWithContext(p, context);
        }

        // Get the position that we should insert the new tab at.
        const config = if (priv.config) |v| v.get() else {
            // If we don't have a config we just append it at the end.
            // This should never happen.
            return tab_view.append(tab.as(gtk.Widget));
        };
        const position = switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },

            .end => tab_view.getNPages(),
        };

        // Add the page and select it
        const page = tab_view.insert(tab.as(gtk.Widget), position);
        tab_view.setSelectedPage(page);
        if (previous) |old| {
            const automation = @import("../automation.zig");
            if (automation.workspaceGroup(old)) |group| {
                automation.assignWorkspaceGroup(tab, group.key, group.name);
            }
        }

        // Create some property bindings
        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );

        // Bind signals
        const split_tree = tab.getSplitTree();
        _ = SplitTree.signals.changed.connect(
            split_tree,
            *Self,
            tabSplitTreeChanged,
            self,
            .{},
        );

        // Run an initial notification for the surface tree so we can setup
        // initial state.
        tabSplitTreeChanged(
            split_tree,
            null,
            split_tree.getTree(),
            self,
        );

        return page;
    }

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    /// Select the tab as requested. Returns true if the tab selection
    /// changed.
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // Get our current tab numeric position
        const selected = tab_view.getSelectedPage() orelse return false;
        const current = tab_view.getPagePosition(selected);

        // Get our total
        const total = tab_view.getNPages();

        const goto: c_int = switch (n) {
            .previous => if (current > 0)
                current - 1
            else
                total - 1,

            .next => if (current < total - 1)
                current + 1
            else
                0,

            .last => total - 1,

            .n => |v| n: {
                // 1-indexed
                if (v == 0) return false;

                const n_int = std.math.cast(
                    c_int,
                    v,
                ) orelse return false;
                break :n @min(n_int - 1, total - 1);
            },
        };
        assert(goto >= 0);
        assert(goto < total);

        // If our target is the same as our current then we do nothing.
        if (goto == current) return false;

        // Add the page and select it
        const page = tab_view.getNthPage(goto);
        tab_view.setSelectedPage(page);

        return true;
    }

    /// Move the tab containing the given surface by the given amount.
    /// Returns if this affected any tab positioning.
    pub fn moveTab(
        self: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // If we have one tab we never move.
        const total = tab_view.getNPages();
        if (total == 1) return false;

        // Get the tab that contains the given surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;

        // Get the page position that contains the tab.
        const page = tab_view.getPage(tab.as(gtk.Widget));
        const pos = tab_view.getPagePosition(page);

        // Move it
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        assert(desired_pos >= 0);
        assert(desired_pos < total);

        return tab_view.reorderPage(page, desired_pos) != 0;
    }

    /// Toggle the column overview grid over the active workspace. This
    /// is bound to the `toggle_tab_overview` keybind action, which used
    /// to open the workspace (tab) overview.
    pub fn toggleColumnOverview(self: *Self) void {
        const priv = self.private();
        self.setColumnOverviewVisible(priv.column_overview.getRevealChild() == 0);
    }

    /// Toggle the visible property.
    pub fn toggleVisibility(self: *Self) void {
        const widget = self.as(gtk.Widget);
        widget.setVisible(@intFromBool(widget.isVisible() == 0));
    }

    /// Updates various appearance properties. This should always be safe
    /// to call multiple times. This should be called whenever a change
    /// happens that might affect how the window appears (config change,
    /// fullscreen, etc.).
    fn syncAppearance(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);

        // Toggle style classes based on whether we're using CSDs or SSDs.
        //
        // These classes are defined in the gtk.Window documentation:
        // https://docs.gtk.org/gtk4/class.Window.html#css-nodes.
        {
            // Reset all style classes first
            inline for (&.{
                "ssd",
                "csd",
                "solid-csd",
                "no-border-radius",
            }) |class|
                widget.removeCssClass(class);

            const csd_enabled = priv.winproto.clientSideDecorationEnabled();
            self.as(gtk.Window).setDecorated(@intFromBool(csd_enabled));

            if (csd_enabled) {
                const display = widget.getDisplay();

                // We do the exact same check GTK is doing internally and toggle
                // either the `csd` or `solid-csd` style, based on whether the user's
                // window manager is deemed _non-compositing_.
                //
                // In practice this only impacts users of traditional X11 window
                // managers (e.g. i3, dwm, awesomewm, etc.) and not X11 desktop
                // environments or Wayland compositors/DEs.
                if (display.isRgba() != 0 and display.isComposited() != 0) {
                    widget.addCssClass("csd");
                } else {
                    widget.addCssClass("solid-csd");
                }
            } else {
                widget.addCssClass("ssd");
                // Fix any artifacting that may occur in window corners.
                widget.addCssClass("no-border-radius");
            }
        }

        // Trigger all our dynamic properties that depend on the config.
        inline for (&.{
            "headerbar-visible",
            "toolbar-style",
            "titlebar-style",
        }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }

        // Remainder uses the config
        const config = if (priv.config) |v| v.get() else return;

        // Only add a solid background if we're opaque.
        self.toggleCssClass(
            "background",
            config.@"background-opacity" >= 1,
        );

        // Apply class to color headerbar if window-theme is set to `ghostty` and
        // GTK version is before 4.16. The conditional is because above 4.16
        // we use GTK CSS color variables.
        self.toggleCssClass(
            "window-theme-ghostty",
            !gtk_version.atLeast(4, 16, 0) and
                config.@"window-theme" == .ghostty,
        );

        // Do our window-protocol specific appearance sync.
        priv.winproto.syncAppearance() catch |err| {
            log.warn("failed to sync winproto appearance error={}", .{err});
        };
    }

    /// Sync the state of any actions on this window.
    fn syncActions(self: *Self) void {
        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };

        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }

    fn toggleCssClass(self: *Self, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Perform a binding action on the window's active surface.
    fn performBindingAction(
        self: *Self,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    /// Queue a simple text-based toast. All text-based toasts share the
    /// same timeout for consistency.
    pub fn addToast(self: *Self, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }

    fn connectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        const priv = self.private();
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            // Before adding any new signal handlers, disconnect any that we may
            // have added before. Otherwise we may get multiple handlers for the
            // same signal.
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );

            _ = Surface.signals.@"present-request".connect(
                surface,
                *Self,
                surfacePresentRequest,
                self,
                .{},
            );
            _ = Surface.signals.@"clipboard-write".connect(
                surface,
                *Self,
                surfaceClipboardWrite,
                self,
                .{},
            );
            _ = Surface.signals.menu.connect(
                surface,
                *Self,
                surfaceMenu,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-fullscreen".connect(
                surface,
                *Self,
                surfaceToggleFullscreen,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-maximize".connect(
                surface,
                *Self,
                surfaceToggleMaximize,
                self,
                .{},
            );

            // If we've never had a surface initialize yet, then we register
            // this signal. Its theoretically possible to launch multiple surfaces
            // before init so we could register this on multiple and that is not
            // a problem because we'll check the flag again in each handler.
            if (!priv.surface_init) {
                _ = Surface.signals.init.connect(
                    surface,
                    *Self,
                    surfaceInit,
                    self,
                    .{},
                );
            }
        }
    }

    /// Disconnect all the surface handlers for the given tree. This should
    /// be called whenever a tree is no longer present in the window, e.g.
    /// when a tab is detached or the tree changes.
    fn disconnectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Whether this terminal is a quick terminal or not.
    pub fn isQuickTerminal(self: *Self) bool {
        return self.private().quick_terminal;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tab = self.getSelectedTab() orelse return null;
        return tab.getActiveSurface();
    }

    /// Returns the configuration for this window. The reference count
    /// is not increased.
    pub fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }

    /// Get the tab view for this window.
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }

    /// Get the current window decoration value for this window.
    pub fn getWindowDecoration(self: *Self) configpkg.WindowDecoration {
        const priv = self.private();
        if (priv.window_decoration) |v| return v;
        if (priv.config) |v| return v.get().@"window-decoration";
        return .auto;
    }

    /// Toggle the window decorations for this window.
    pub fn toggleWindowDecorations(self: *Self) void {
        const priv = self.private();

        if (priv.window_decoration) |_| {
            // Unset any previously set window decoration settings
            self.setWindowDecoration(null);
            return;
        }

        const config = if (priv.config) |v| v.get() else return;
        self.setWindowDecoration(switch (config.@"window-decoration") {
            // Use auto when the decoration is initially none
            .none => .auto,

            // Anything non-none to none
            .auto, .client, .server => .none,
        });
    }

    /// Set the window decoration override for this window. If this is null,
    /// then we'll revert back to the configuration's default.
    fn setWindowDecoration(
        self: *Self,
        new_: ?configpkg.WindowDecoration,
    ) void {
        const priv = self.private();
        priv.window_decoration = new_;
        self.syncAppearance();
    }

    /// Get the currently selected tab as a Tab object.
    fn getSelectedTab(self: *Self) ?*Tab {
        const priv = self.private();
        const page = priv.tab_view.getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        return gobject.ext.cast(Tab, child);
    }

    /// Returns true if this window needs confirmation before quitting.
    fn getNeedsConfirmQuit(self: *Self) bool {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        assert(n >= 0);

        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child) orelse {
                log.warn("unexpected non-Tab child in tab view", .{});
                continue;
            };
            if (tab.getNeedsConfirmQuit()) return true;
        }

        return false;
    }

    fn isFullscreen(self: *Window) bool {
        return self.as(gtk.Window).isFullscreen() != 0;
    }

    fn isMaximized(self: *Window) bool {
        return self.as(gtk.Window).isMaximized() != 0;
    }

    fn getHeaderbarVisible(self: *Self) bool {
        const priv = self.private();

        // Never display the header bar when CSDs are disabled.
        const csd_enabled = priv.winproto.clientSideDecorationEnabled();
        if (!csd_enabled) return false;

        // Never display the header bar as a quick terminal.
        if (priv.quick_terminal) return false;

        // If we're fullscreen we never show the header bar.
        if (self.isFullscreen()) return false;

        // The remainder needs a config
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();

        // *Conditionally* disable the header bar when maximized, and
        // gtk-titlebar-hide-when-maximized is set
        if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") {
            return false;
        }

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs never show the titlebar.
            .tabs => false,

            // If the titlebar style is native show the titlebar if configured
            // to do so.
            .native => config.@"gtk-titlebar",
        };
    }

    fn getToolbarStyle(self: *Self) adw.ToolbarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .raised;
        return switch (config.@"gtk-toolbar-style") {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
    }

    fn getTitlebarStyle(self: *Self) TitlebarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .native;
        return config.@"gtk-titlebar-style";
    }

    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.@"app-notifications".@"config-reload") {
                self.addToast(i18n._("Reloaded the configuration"));
            }
        }

        self.syncAppearance();
    }

    fn propGdkSurfaceHeight(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn propIsActive(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Hide quick-terminal if set to autohide
        if (self.isQuickTerminal()) {
            if (self.getConfig()) |cfg| {
                if (cfg.get().@"quick-terminal-autohide" and self.as(gtk.Window).isActive() == 0) {
                    self.toggleVisibility();
                }
            }
        }

        // Don't change urgency if we're not the active window.
        if (self.as(gtk.Window).isActive() == 0) return;

        self.winproto().setUrgent(false) catch |err| {
            log.warn(
                "winproto failed to reset urgency={}",
                .{err},
            );
        };
    }

    fn propGdkSurfaceWidth(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Debian 12 is stuck on GTK 4.8
        if (!gtk_version.atLeast(4, 10, 0)) return;

        // We only care if we're activating. If we're activating then
        // we need to check the validity of our menu items.
        const active = button.getActive() != 0;
        if (!active) return;

        self.syncActions();
    }

    fn propQuickTerminal(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) {
            log.warn("quick terminal property can't be changed after surfaces have been initialized", .{});
            return;
        }

        if (priv.quick_terminal) {
            // Initialize the quick terminal at the app-layer
            Application.default().winproto().initQuickTerminal(self) catch |err| {
                log.warn("failed to initialize quick terminal error={}", .{err});
                return;
            };
        }
    }

    fn propScaleFactor(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // On some platforms (namely X11) we need to refresh our appearance when
        // the scale factor changes. In theory this could be more fine-grained as
        // a full refresh could be expensive, but a) this *should* be rare, and
        // b) quite noticeable visual bugs would occur if this is not present.
        self.private().winproto.syncAppearance() catch |err| {
            log.warn(
                "failed to sync appearance after scale factor has been updated={}",
                .{err},
            );
            return;
        };
    }

    fn closureSubtitle(
        _: *Self,
        config_: ?*Config,
        pwd_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const config = if (config_) |v| v.get() else return null;
        return switch (config.@"window-subtitle") {
            .false => null,
            .@"working-directory" => pwd: {
                const pwd = pwd_ orelse return null;
                break :pwd glib.ext.dupeZ(u8, std.mem.span(pwd));
            },
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.command_palette.set(null);

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        priv.tab_bindings.setSource(null);

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.multi_selected.deinit(a);
        for (priv.collapsed_groups.items) |key| a.free(key);
        priv.collapsed_groups.deinit(a);
        priv.tab_bindings.unref();
        priv.winproto.deinit(Application.default().allocator());

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn windowRealize(_: *gtk.Widget, self: *Window) callconv(.c) void {
        const app = Application.default();

        // Initialize our window protocol logic
        if (winprotopkg.Window.init(
            app.allocator(),
            app.winproto(),
            self,
        )) |wp| {
            self.private().winproto = wp;
        } else |err| {
            log.warn("failed to initialize window protocol error={}", .{err});
            return;
        }

        // We need to setup resize notifications on our surface,
        // which is only available after the window had been realized.
        if (self.as(gtk.Native).getSurface()) |gdk_surface| {
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceWidth,
                self,
                .{ .detail = "width" },
            );
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceHeight,
                self,
                .{ .detail = "height" },
            );
        }

        // When we are realized we always setup our appearance since this
        // calls some winproto functions.
        self.syncAppearance();
    }

    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        if (self.getNeedsConfirmQuit()) {
            // Show a confirmation dialog
            const dialog: *CloseConfirmationDialog = .new(.window);
            _ = CloseConfirmationDialog.signals.@"close-request".connect(
                dialog,
                *Self,
                closeConfirmationClose,
                self,
                .{},
            );

            // Show it
            dialog.present(self.as(gtk.Widget));
            return @intFromBool(true);
        }
        if (@import("../automation.zig").closeRemoteWindow(self)) return 1;

        self.as(gtk.Window).destroy();
        return @intFromBool(false);
    }

    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        if (@import("../automation.zig").closeRemoteWindow(self)) return;
        self.as(gtk.Window).destroy();
    }

    fn closeConfirmationCloseTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        if (gobject.ext.cast(Tab, page.getChild())) |tab| {
            if (@import("../automation.zig").closeRemoteWorkspace(tab)) {
                tab_view.closePageFinish(page, 0);
                return;
            }
        }
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    fn closeConfirmationCancelTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(false));
    }

    fn tabViewClosePage(
        _: *adw.TabView,
        page: *adw.TabPage,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse
            return @intFromBool(false);

        // If the tab says it doesn't need confirmation then we go ahead
        // and close immediately.
        if (priv.automation_closing or !tab.getNeedsConfirmQuit()) {
            if (!priv.automation_closing and @import("../automation.zig").closeRemoteWorkspace(tab)) {
                priv.tab_view.closePageFinish(page, 0);
                return 1;
            }
            priv.tab_view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }

        // Show a confirmation dialog
        const dialog = CloseConfirmationDialog.new(.tab);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCloseTab,
            page,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCancelTab,
            page,
            .{},
        );

        // Show it
        dialog.present(child);
        return @intFromBool(true);
    }

    fn tabViewSelectedPage(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        self.syncWorkspaceSelection();
        @import("../automation.zig").sessionChanged();
        // Always reset our binding source in case we have no pages.
        priv.tab_bindings.setSource(null);

        // Get our current page which MUST be a Tab object.
        const page = priv.tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));

        // Setup our binding group. This ensures things like the title
        // are synced from the active tab.
        priv.tab_bindings.setSource(child.as(gobject.Object));

        @import("../automation.zig").workspaceFocused(gobject.ext.cast(Tab, child).?);

        if (priv.column_overview.getRevealChild() != 0)
            self.populateColumnOverview();
    }

    const WorkspaceRow = struct {
        tab: *Tab,
        page: *adw.TabPage,
        row: *gtk.ListBoxRow,
        unread: *gtk.Label,
        pin: *gtk.Image,
        mute: *gtk.Image,
        remote: *gtk.Image,
        spinner: *gtk.Spinner,

        task: *gtk.Image,
        description: *gtk.Label,
        statuses: *gtk.Box,
        status_toggle: *gtk.Button,
        preview: *gtk.Label,
        progress: *gtk.ProgressBar,
        last_log: *gtk.Label,
        extras: *gtk.Box,
        branch: *gtk.Label,
        directory: *gtk.Label,
        tooltip_handler: c_ulong,
        /// cmux collapses the status list to three rows behind a
        /// "Show more" toggle (SidebarWorkspaceRowCellView.configureMetadata).
        expanded: bool = false,

        const collapsed_status_limit: usize = 3;

        fn destroy(ptr: ?*anyopaque) callconv(.c) void {
            const self: *WorkspaceRow = @ptrCast(@alignCast(ptr.?));
            gobject.signalHandlerDisconnect(self.page.as(gobject.Object), self.tooltip_handler);
            self.page.as(gobject.Object).unref();
            self.tab.unref();
            a.destroy(self);
        }
        fn setText(label: *gtk.Label, value: []const u8) void {
            if (std.mem.eql(u8, std.mem.span(label.getText()), value)) return;
            const text = a.dupeZ(u8, value) catch return;
            defer a.free(text);
            label.setText(text);
        }

        fn taskGlyph(status: ?[]const u8) []const u8 {
            const value = status orelse return "○";
            if (std.mem.eql(u8, value, "done")) return "✓";
            if (std.mem.eql(u8, value, "running")) return "●";
            if (std.mem.eql(u8, value, "error")) return "⚠";
            if (std.mem.eql(u8, value, "blocked")) return "◼";
            return value;
        }

        fn updateTask(self: *WorkspaceRow, status: ?[]const u8) void {
            const widget = self.task.as(gtk.Widget);
            widget.removeCssClass("unset");
            widget.removeCssClass("running");
            widget.removeCssClass("blocked");
            widget.removeCssClass("error");
            widget.removeCssClass("done");
            var icon: [:0]const u8 = "colm-task-none-symbolic";
            if (status) |value| {
                if (std.mem.eql(u8, value, "running")) {
                    widget.addCssClass("running");
                    icon = "colm-task-filled-symbolic";
                } else if (std.mem.eql(u8, value, "blocked")) {
                    widget.addCssClass("blocked");
                    icon = "colm-task-blocked-symbolic";
                } else if (std.mem.eql(u8, value, "error")) {
                    widget.addCssClass("error");
                } else if (std.mem.eql(u8, value, "done")) {
                    widget.addCssClass("done");
                    icon = "colm-task-filled-symbolic";
                }
            } else widget.addCssClass("unset");
            self.task.setFromIconName(icon);
            widget.setVisible(1);
        }

        fn setGlyph(widget: *gtk.Widget, on: bool) void {
            widget.setVisible(@intFromBool(on));
        }

        fn update(self: *WorkspaceRow, tab: *Tab) void {
            const automation = @import("../automation.zig");
            const data = automation.workspaceRowData(a, tab);
            defer a.free(data.statuses);
            defer {
                for (data.todos) |item| a.free(item.text);
                a.free(data.todos);
            }
            var count_buf: [32]u8 = undefined;
            setText(self.unread, if (data.unread_count > 0)
                std.fmt.bufPrint(&count_buf, "{d}", .{data.unread_count}) catch unreachable
            else
                "•");
            var tooltip_buf: [80]u8 = undefined;
            self.unread.as(gtk.Widget).setTooltipText(if (data.unread_count > 0)
                std.fmt.bufPrintZ(&tooltip_buf, "{d} unread notifications", .{data.unread_count}) catch unreachable
            else
                "Terminal requests attention");

            setGlyph(self.pin.as(gtk.Widget), data.pinned);
            setGlyph(self.mute.as(gtk.Widget), data.muted);
            setGlyph(self.remote.as(gtk.Widget), data.remote);
            if (data.agent_busy) self.spinner.start() else self.spinner.stop();
            setGlyph(self.spinner.as(gtk.Widget), data.agent_busy);

            var branch_buf: [96]u8 = undefined;
            const branch = data.git_branch orelse "";
            setText(self.branch, if (data.git_dirty)
                std.fmt.bufPrint(&branch_buf, "{s}*", .{branch}) catch branch
            else
                branch);
            self.branch.as(gtk.Widget).setVisible(@intFromBool(branch.len > 0));
            self.updateDirectory();
            setMarkdown(self.description, data.description);
            setPreview(self.preview, data.preview);
            self.updateStatuses(data.statuses);
            if (data.progress) |value| {
                self.progress.setFraction(@as(f64, @floatFromInt(value)) / 100.0);
                self.progress.as(gtk.Widget).setVisible(1);
                if (data.progress_label) |label| {
                    const text = a.dupeZ(u8, label) catch null;
                    if (text) |value_z| {
                        defer a.free(value_z);
                        self.progress.setText(value_z);
                    }
                } else self.progress.setText(null);
            } else {
                self.progress.as(gtk.Widget).setVisible(0);
            }
            setPreview(self.last_log, data.last_log);
            self.updateTask(data.task_status);
            self.updateExtras(data);
            const done = if (data.task_status) |status| std.mem.eql(u8, status, "done") else false;
            if (done) self.row.as(gtk.Widget).addCssClass("workspace-done") else self.row.as(gtk.Widget).removeCssClass("workspace-done");
            if (ext.getAncestor(Window, self.row.as(gtk.Widget))) |win| {
                if (win.tabIsMultiSelected(tab)) self.row.as(gtk.Widget).addCssClass("workspace-multi") else self.row.as(gtk.Widget).removeCssClass("workspace-multi");
            }
        }

        /// One line per status key, three lines collapsed. Status text is its
        /// own tier: it never replaces the description or the notification
        /// line, so an agent writing status on every turn cannot pin stale
        /// text into the description slot.
        fn updateStatuses(
            self: *WorkspaceRow,
            statuses: []const @import("../automation.zig").SidebarStatusItem,
        ) void {
            while (self.statuses.as(gtk.Widget).getFirstChild()) |child|
                self.statuses.remove(child);
            const visible = if (self.expanded)
                statuses.len
            else
                @min(statuses.len, collapsed_status_limit);
            for (statuses[0..visible]) |entry| {
                const line = gtk.Box.new(.horizontal, 3);
                if (statusIcon(entry.icon)) |icon| line.append(icon);
                const label = gtk.Label.new(null);
                label.setXalign(0);
                label.setEllipsize(.end);
                label.setMaxWidthChars(1);
                label.as(gtk.Widget).setHexpand(1);
                label.as(gtk.Widget).addCssClass("workspace-status");
                // An explicit status color yields to the selected row's
                // foreground, otherwise blue "Running" text vanishes into the
                // blue selection highlight (cmux configureMetadata).
                const color = if (self.row.isSelected() == 0) entry.color else null;
                if (color) |value| setColoredText(label, entry.text, value) else setText(label, entry.text);
                line.append(label.as(gtk.Widget));
                self.statuses.append(line.as(gtk.Widget));
            }
            self.statuses.as(gtk.Widget).setVisible(@intFromBool(visible > 0));
            const has_toggle = statuses.len > collapsed_status_limit;
            self.status_toggle.as(gtk.Widget).setVisible(@intFromBool(has_toggle));
            if (has_toggle) self.status_toggle.setLabel(if (self.expanded)
                "Show less"
            else
                "Show more");
        }

        fn updateExtras(self: *WorkspaceRow, data: @import("../automation.zig").WorkspaceRowData) void {
            while (self.extras.as(gtk.Widget).getFirstChild()) |child|
                self.extras.remove(child);
            if (data.pr_url) |url| {
                const uri = a.dupeZ(u8, url) catch null;
                if (uri) |value| {
                    defer a.free(value);
                    const label = data.pr_label orelse url;
                    const text = a.dupeZ(u8, label) catch value;
                    defer if (text.ptr != value.ptr) a.free(text);
                    const link = gtk.LinkButton.newWithLabel(value, text);
                    link.as(gtk.Widget).addCssClass("workspace-pr");
                    link.as(gtk.Widget).setHalign(.start);
                    self.extras.append(link.as(gtk.Widget));
                }
            }
            for (data.ports) |port| {
                var uri_buf: [64]u8 = undefined;
                var label_buf: [24]u8 = undefined;
                const uri = std.fmt.bufPrintZ(&uri_buf, "http://127.0.0.1:{d}", .{port}) catch continue;
                const text = std.fmt.bufPrintZ(&label_buf, ":{d}", .{port}) catch continue;
                const link = gtk.LinkButton.newWithLabel(uri, text);
                link.as(gtk.Widget).addCssClass("workspace-port");
                link.as(gtk.Widget).setHalign(.start);
                self.extras.append(link.as(gtk.Widget));
            }
            for (data.todos) |item| {
                var line_buf: [256]u8 = undefined;
                const mark: u8 = if (item.done) 'x' else ' ';
                const text = std.fmt.bufPrint(&line_buf, "[{c}] {s}", .{ mark, item.text }) catch item.text;
                const label = gtk.Label.new(null);
                label.setXalign(0);
                label.setEllipsize(.end);
                setText(label, text);
                label.as(gtk.Widget).addCssClass("workspace-todo");
                if (item.done) label.as(gtk.Widget).addCssClass("dim-label");
                self.extras.append(label.as(gtk.Widget));
            }
            self.extras.as(gtk.Widget).setVisible(@intFromBool(
                data.pr_url != null or data.ports.len > 0 or data.todos.len > 0,
            ));
        }

        /// Colors a status line with Pango markup. Status text is untrusted
        /// automation input, so it is escaped, and an unusable color string
        /// falls back to the plain label instead of a markup parse error.
        fn setColoredText(label: *gtk.Label, value: []const u8, color: []const u8) void {
            for (color) |byte| switch (byte) {
                'a'...'z', 'A'...'Z', '0'...'9', '#' => {},
                else => return setText(label, value),
            };
            const text = a.dupeZ(u8, value) catch return setText(label, value);
            defer a.free(text);
            const escaped = glib.markupEscapeText(text, @intCast(text.len));
            defer glib.free(escaped);
            const markup = std.fmt.allocPrintSentinel(
                a,
                "<span foreground=\"{s}\">{s}</span>",
                .{ color, std.mem.span(escaped) },
                0,
            ) catch return setText(label, value);
            defer a.free(markup);
            label.setMarkup(markup);
        }

        fn statusIcon(icon_: ?[]const u8) ?*gtk.Widget {
            const icon = icon_ orelse return null;
            // cmux icon grammar: "emoji:X", "text:X", "sf:name", or a bare
            // SF symbol. Linux maps the bell family to Adwaita symbolic
            // names (FeedCoordinator uses "bell.fill" for Needs input).
            if (std.mem.startsWith(u8, icon, "emoji:") or
                std.mem.startsWith(u8, icon, "text:"))
            {
                const text = icon[std.mem.indexOfScalar(u8, icon, ':').? + 1 ..];
                if (text.len == 0) return null;
                const label = gtk.Label.new(null);
                label.as(gtk.Widget).addCssClass("workspace-status-icon");
                setText(label, text);
                return label.as(gtk.Widget);
            }
            const raw = if (std.mem.startsWith(u8, icon, "sf:")) icon["sf:".len..] else icon;
            if (raw.len == 0) return null;
            const mapped: []const u8 = if (std.mem.eql(u8, raw, "bell.fill") or
                std.mem.eql(u8, raw, "bell") or
                std.mem.eql(u8, raw, "bell.badge"))
                "notification-symbolic"
            else if (std.mem.eql(u8, raw, "bell.slash.fill") or
                std.mem.eql(u8, raw, "bell.slash"))
                "notifications-disabled-symbolic"
            else
                raw;
            const name_z = a.dupeZ(u8, mapped) catch return null;
            defer a.free(name_z);
            const display = gdk.Display.getDefault() orelse return null;
            const theme = gtk.IconTheme.getForDisplay(display);
            if (theme.hasIcon(name_z) != 0) {
                const image = gtk.Image.newFromIconName(name_z);
                image.as(gtk.Widget).addCssClass("workspace-status-icon");
                return image.as(gtk.Widget);
            }
            if (std.mem.eql(u8, mapped, "notification-symbolic")) {
                const label = gtk.Label.new(null);
                label.as(gtk.Widget).addCssClass("workspace-status-icon");
                setText(label, "🔔");
                return label.as(gtk.Widget);
            }
            return null;
        }

        fn toggleStatuses(_: *gtk.Button, self: *WorkspaceRow) callconv(.c) void {
            self.expanded = !self.expanded;
            self.update(self.tab);
        }

        fn taskClicked(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *WorkspaceRow) callconv(.c) void {
            _ = gesture.as(gtk.Gesture).setState(.claimed);
            const popover = gtk.Popover.new();
            popover.as(gtk.Widget).setParent(self.task.as(gtk.Widget));
            popover.setHasArrow(1);
            const box = gtk.Box.new(.vertical, 0);
            const current = @import("../automation.zig").workspaceTaskStatus(self.tab);
            const choices = [_]struct { id: [:0]const u8, label: [:0]const u8 }{
                .{ .id = "running", .label = "●  Running" },
                .{ .id = "blocked", .label = "◼  Blocked" },
                .{ .id = "error", .label = "⚠  Error" },
                .{ .id = "done", .label = "✓  Done" },
                .{ .id = "clear", .label = "Clear" },
            };
            for (choices) |choice| {
                const line = gtk.Button.newWithLabel(choice.label);
                line.as(gtk.Widget).addCssClass("flat");
                line.as(gtk.Widget).setHalign(.fill);
                line.as(gtk.Widget).setName(choice.id);
                const selected = if (current) |value|
                    std.mem.eql(u8, value, choice.id)
                else
                    std.mem.eql(u8, choice.id, "clear");
                if (selected) line.as(gtk.Widget).addCssClass("workspace-task-current");
                _ = gtk.Button.signals.clicked.connect(
                    line,
                    *WorkspaceRow,
                    WorkspaceRow.taskPicked,
                    self,
                    .{},
                );
                box.append(line.as(gtk.Widget));
            }
            popover.setChild(box.as(gtk.Widget));
            _ = gtk.Popover.signals.closed.connect(
                popover,
                *gtk.Popover,
                WorkspaceRow.taskPopoverClosed,
                popover,
                .{},
            );
            popover.popup();
        }

        fn taskPicked(button: *gtk.Button, self: *WorkspaceRow) callconv(.c) void {
            var widget: ?*gtk.Widget = button.as(gtk.Widget);
            while (widget) |w| {
                if (gobject.ext.cast(gtk.Popover, w)) |popover| {
                    popover.popdown();
                    break;
                }
                widget = w.getParent();
            }
            const name = std.mem.span(button.as(gtk.Widget).getName());
            @import("../automation.zig").setWorkspaceTaskStatus(
                self.tab,
                if (std.mem.eql(u8, name, "clear")) null else name,
            );
            self.update(self.tab);
        }

        fn taskPopoverClosed(popover: *gtk.Popover, _: *gtk.Popover) callconv(.c) void {
            popover.as(gtk.Widget).unparent();
        }

        fn closeClicked(_: *gtk.Button, self: *WorkspaceRow) callconv(.c) void {
            const win = ext.getAncestor(Window, self.row.as(gtk.Widget)) orelse return;
            win.closeSelectedWorkspaces(self.tab);
        }

        fn primaryPressed(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *WorkspaceRow) callconv(.c) void {
            const win = ext.getAncestor(Window, self.row.as(gtk.Widget)) orelse return;
            const mods = gesture.as(gtk.EventController).getCurrentEventState();
            if (mods.control_mask) {
                win.toggleMultiSelect(self.tab);
                return;
            }
            if (mods.shift_mask) {
                win.rangeSelect(self.tab);
                return;
            }
            win.clearMultiSelect();
        }

        fn menuPressed(gesture: *gtk.GestureClick, _: c_int, _: f64, _: f64, self: *WorkspaceRow) callconv(.c) void {
            _ = gesture.as(gtk.Gesture).setState(.claimed);
            const win = ext.getAncestor(Window, self.row.as(gtk.Widget)) orelse return;
            win.popupWorkspaceMenu(self);
        }

        fn tooltipChanged(_: *adw.TabPage, _: *gobject.ParamSpec, self: *WorkspaceRow) callconv(.c) void {
            self.updateDirectory();
        }

        fn updateDirectory(self: *WorkspaceRow) void {
            const raw = std.mem.span(self.page.getTooltip() orelse "");
            const home = std.posix.getenv("HOME") orelse "";
            var buf: [1024]u8 = undefined;
            const display = if (home.len > 0 and std.mem.eql(u8, raw, home))
                "~"
            else if (home.len > 0 and raw.len > home.len and
                std.mem.startsWith(u8, raw, home) and raw[home.len] == '/')
                std.fmt.bufPrint(&buf, "~{s}", .{raw[home.len..]}) catch raw
            else
                raw;
            setText(self.directory, display);
        }

        fn setPreview(label: *gtk.Label, value: ?[]const u8) void {
            // Keep previews to one paragraph so embedded newlines cannot defeat
            // the two-line layout limit. Never poll or copy terminal scrollback.
            const preview = value orelse "";
            var preview_buf: [1024]u8 = undefined;
            var len: usize = 0;
            var pending_space = false;
            var iter = std.unicode.Utf8View.initUnchecked(preview).iterator();
            while (iter.nextCodepointSlice()) |cp| {
                if (cp.len == 1 and std.ascii.isWhitespace(cp[0])) {
                    pending_space = len > 0;
                    continue;
                }
                const space: usize = @intFromBool(pending_space);
                if (len + space + cp.len > preview_buf.len - "…".len) {
                    @memcpy(preview_buf[len..][0.."…".len], "…");
                    len += "…".len;
                    break;
                }
                if (pending_space) {
                    preview_buf[len] = ' ';
                    len += 1;
                    pending_space = false;
                }
                @memcpy(preview_buf[len..][0..cp.len], cp);
                len += cp.len;
            }
            setText(label, preview_buf[0..len]);
            label.as(gtk.Widget).setVisible(@intFromBool(len > 0));
        }

        fn setMarkdown(label: *gtk.Label, value: ?[]const u8) void {
            const src = value orelse "";
            if (src.len == 0) {
                label.as(gtk.Widget).setVisible(0);
                return;
            }
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(a);
            var index: usize = 0;
            var bold = false;
            var code = false;
            while (index < src.len) {
                if (!code and index + 1 < src.len and src[index] == '*' and src[index + 1] == '*') {
                    buf.appendSlice(a, if (bold) "</b>" else "<b>") catch break;
                    bold = !bold;
                    index += 2;
                    continue;
                }
                if (src[index] == '`') {
                    buf.appendSlice(a, if (code) "</tt>" else "<tt>") catch break;
                    code = !code;
                    index += 1;
                    continue;
                }
                switch (src[index]) {
                    '&' => buf.appendSlice(a, "&amp;") catch break,
                    '<' => buf.appendSlice(a, "&lt;") catch break,
                    '>' => buf.appendSlice(a, "&gt;") catch break,
                    '\n' => buf.append(a, ' ') catch break,
                    else => buf.append(a, src[index]) catch break,
                }
                index += 1;
            }
            if (bold) buf.appendSlice(a, "</b>") catch {};
            if (code) buf.appendSlice(a, "</tt>") catch {};
            const markup = buf.toOwnedSliceSentinel(a, 0) catch {
                setPreview(label, src);
                return;
            };
            defer a.free(markup);
            label.setMarkup(markup);
            label.as(gtk.Widget).setVisible(1);
        }
    };

    pub fn refreshWorkspaceRows(self: *Self) void {
        const priv = self.private();
        const automation = @import("../automation.zig");
        var index: c_int = 0;
        var prev_key: ?[]const u8 = null;
        while (priv.workspace_list.getRowAtIndex(index)) |row| : (index += 1) {
            const ptr = row.as(gobject.Object).getData("colm-workspace-row") orelse continue;
            const state: *WorkspaceRow = @ptrCast(@alignCast(ptr));
            state.update(state.tab);
            const group = automation.workspaceGroup(state.tab);
            const key = if (group) |g| g.key else null;
            const collapsed = if (key) |k| self.groupIsCollapsed(k) else false;
            const anchor = key != null and (prev_key == null or !std.mem.eql(u8, prev_key.?, key.?));
            row.as(gtk.Widget).setVisible(@intFromBool(!collapsed or anchor));
            prev_key = key;
        }
        priv.workspace_list.invalidateHeaders();
    }

    fn workspaceActiveSurfaceChanged(
        _: *Tab,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refreshWorkspaceRows();
    }
    fn createWorkspaceRow(
        item: *gobject.Object,
        _: ?*anyopaque,
    ) callconv(.c) *gtk.Widget {
        const page = gobject.ext.cast(adw.TabPage, item).?;
        const row = gtk.ListBoxRow.new();
        // cmux title line: unread, pin, mute, task, cloud, title,
        // trailing close/spinner overlay. Hidden accessories collapse.
        const box = gtk.Box.new(.vertical, 4);
        const heading = gtk.Box.new(.horizontal, 4);
        const unread = gtk.Label.new("•");
        unread.as(gtk.Widget).addCssClass("workspace-unread");
        unread.as(gtk.Widget).setValign(.center);
        _ = page.as(gobject.Object).bindProperty(
            "needs-attention",
            unread.as(gobject.Object),
            "visible",
            .{ .sync_create = true },
        );
        heading.append(unread.as(gtk.Widget));
        const pin = gtk.Image.newFromIconName("colm-pin-symbolic");
        pin.setPixelSize(9);
        pin.as(gtk.Widget).addCssClass("workspace-glyph");
        pin.as(gtk.Widget).setTooltipText("Pinned");
        pin.as(gtk.Widget).setValign(.center);
        pin.as(gtk.Widget).setSizeRequest(13, 13);
        pin.as(gtk.Widget).setVisible(0);
        heading.append(pin.as(gtk.Widget));
        const mute = gtk.Image.newFromIconName("notifications-disabled-symbolic");
        mute.setPixelSize(9);
        mute.as(gtk.Widget).addCssClass("workspace-glyph");
        mute.as(gtk.Widget).setTooltipText("Muted");
        mute.as(gtk.Widget).setValign(.center);
        mute.as(gtk.Widget).setSizeRequest(13, 13);
        mute.as(gtk.Widget).setVisible(0);
        heading.append(mute.as(gtk.Widget));
        const task = gtk.Image.newFromIconName("colm-task-none-symbolic");
        task.setPixelSize(9);
        task.as(gtk.Widget).addCssClass("workspace-task");
        task.as(gtk.Widget).addCssClass("unset");
        task.as(gtk.Widget).setTooltipText("Task status");
        task.as(gtk.Widget).setValign(.center);
        task.as(gtk.Widget).setSizeRequest(9, 9);
        heading.append(task.as(gtk.Widget));
        const remote = gtk.Image.newFromIconName("weather-overcast-symbolic");
        remote.setPixelSize(9);
        remote.as(gtk.Widget).addCssClass("workspace-glyph");
        remote.as(gtk.Widget).setTooltipText("Remote workspace");
        remote.as(gtk.Widget).setValign(.center);
        remote.as(gtk.Widget).setSizeRequest(13, 13);
        remote.as(gtk.Widget).setVisible(0);
        heading.append(remote.as(gtk.Widget));
        const label = gtk.Label.new(null);
        label.setXalign(0);
        label.setEllipsize(.end);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).addCssClass("workspace-title");
        _ = page.as(gobject.Object).bindProperty(
            "title",
            label.as(gobject.Object),
            "label",
            .{ .sync_create = true },
        );
        heading.append(label.as(gtk.Widget));
        const spinner = gtk.Spinner.new();
        spinner.as(gtk.Widget).setTooltipText("Agent running");
        spinner.as(gtk.Widget).setHalign(.center);
        spinner.as(gtk.Widget).setValign(.center);
        spinner.as(gtk.Widget).setSizeRequest(12, 12);
        spinner.as(gtk.Widget).setVisible(0);
        const close_img = gtk.Image.newFromIconName("window-close-symbolic");
        close_img.setPixelSize(9);
        const close = gtk.Button.new();
        close.setChild(close_img.as(gtk.Widget));
        close.as(gtk.Widget).addCssClass("workspace-close");
        close.as(gtk.Widget).addCssClass("flat");
        close.as(gtk.Widget).setTooltipText("Close workspace");
        close.as(gtk.Widget).setHalign(.center);
        close.as(gtk.Widget).setValign(.center);
        close.as(gtk.Widget).setCanFocus(0);
        close.as(gtk.Widget).setFocusOnClick(0);
        const trailing = gtk.Overlay.new();
        trailing.as(gtk.Widget).addCssClass("workspace-trailing");
        trailing.as(gtk.Widget).setValign(.center);
        trailing.as(gtk.Widget).setSizeRequest(16, 16);
        trailing.setChild(spinner.as(gtk.Widget));
        trailing.addOverlay(close.as(gtk.Widget));
        heading.append(trailing.as(gtk.Widget));
        box.append(heading.as(gtk.Widget));
        const description = gtk.Label.new(null);
        const preview = gtk.Label.new(null);
        for ([_]*gtk.Label{ description, preview }) |detail| {
            detail.setXalign(0);
            detail.setWrap(1);
            detail.setWrapMode(.word_char);
            detail.setEllipsize(.end);
            detail.setLines(2);
            detail.setMaxWidthChars(1);
            detail.as(gtk.Widget).setHexpand(1);
            detail.as(gtk.Widget).addCssClass("workspace-preview");
        }
        description.setLines(12);
        description.as(gtk.Widget).addCssClass("workspace-description");
        preview.as(gtk.Widget).addCssClass("workspace-notification");
        box.append(description.as(gtk.Widget));
        box.append(preview.as(gtk.Widget));
        const statuses = gtk.Box.new(.vertical, 2);
        box.append(statuses.as(gtk.Widget));
        const status_toggle = gtk.Button.newWithLabel("Show more");
        status_toggle.as(gtk.Widget).addCssClass("workspace-status-toggle");
        status_toggle.as(gtk.Widget).addCssClass("flat");
        status_toggle.as(gtk.Widget).setHalign(.start);
        status_toggle.as(gtk.Widget).setVisible(@intFromBool(false));
        box.append(status_toggle.as(gtk.Widget));
        const progress = gtk.ProgressBar.new();
        progress.setShowText(1);
        progress.as(gtk.Widget).setVisible(0);
        box.append(progress.as(gtk.Widget));
        const last_log = gtk.Label.new(null);
        last_log.setXalign(0);
        last_log.setEllipsize(.end);
        last_log.as(gtk.Widget).addCssClass("workspace-log");
        last_log.as(gtk.Widget).setVisible(0);
        box.append(last_log.as(gtk.Widget));
        const extras = gtk.Box.new(.vertical, 2);
        extras.as(gtk.Widget).addCssClass("workspace-extras");
        extras.as(gtk.Widget).setVisible(0);
        box.append(extras.as(gtk.Widget));
        const location = gtk.Box.new(.vertical, 1);
        location.as(gtk.Widget).addCssClass("workspace-location");
        const branch = gtk.Label.new(null);
        branch.setXalign(0);
        branch.setEllipsize(.end);
        location.append(branch.as(gtk.Widget));
        const directory = gtk.Label.new(null);
        directory.setXalign(0);
        directory.setEllipsize(.start);
        location.append(directory.as(gtk.Widget));
        box.append(location.as(gtk.Widget));
        const state = a.create(WorkspaceRow) catch @panic("out of memory");
        _ = page.as(gobject.Object).ref();
        state.* = .{
            .tab = gobject.ext.cast(Tab, page.getChild()).?.ref(),
            .page = page,
            .row = row,
            .unread = unread,
            .pin = pin,
            .mute = mute,
            .remote = remote,
            .spinner = spinner,
            .task = task,
            .description = description,
            .statuses = statuses,
            .status_toggle = status_toggle,
            .preview = preview,
            .progress = progress,
            .last_log = last_log,
            .extras = extras,
            .branch = branch,
            .directory = directory,
            .tooltip_handler = gobject.Object.signals.notify.connect(
                page,
                *WorkspaceRow,
                WorkspaceRow.tooltipChanged,
                state,
                .{ .detail = "tooltip" },
            ),
        };
        row.as(gobject.Object).setDataFull("colm-workspace-row", state, WorkspaceRow.destroy);
        const drag = gtk.DragSource.new();
        drag.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(drag, *gtk.ListBoxRow, workspaceDragPrepare, row, .{});
        row.as(gtk.Widget).addController(drag.as(gtk.EventController));
        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(1);
        _ = gtk.GestureClick.signals.pressed.connect(click, *WorkspaceRow, WorkspaceRow.primaryPressed, state, .{});
        row.as(gtk.Widget).addController(click.as(gtk.EventController));
        const right = gtk.GestureClick.new();
        right.as(gtk.GestureSingle).setButton(3);
        _ = gtk.GestureClick.signals.pressed.connect(right, *WorkspaceRow, WorkspaceRow.menuPressed, state, .{});
        row.as(gtk.Widget).addController(right.as(gtk.EventController));

        _ = gtk.Button.signals.clicked.connect(
            status_toggle,
            *WorkspaceRow,
            WorkspaceRow.toggleStatuses,
            state,
            .{},
        );
        const task_click = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(task_click, *WorkspaceRow, WorkspaceRow.taskClicked, state, .{});
        task.as(gtk.Widget).addController(task_click.as(gtk.EventController));
        _ = gtk.Button.signals.clicked.connect(
            close,
            *WorkspaceRow,
            WorkspaceRow.closeClicked,
            state,
            .{},
        );
        state.update(state.tab);
        row.setChild(box.as(gtk.Widget));
        return row.as(gtk.Widget);
    }

    fn syncWorkspaceSelection(self: *Self) void {
        const priv = self.private();
        priv.syncing_workspace = true;
        defer priv.syncing_workspace = false;
        const page = priv.tab_view.getSelectedPage() orelse return;
        const index = priv.tab_view.getPagePosition(page);
        priv.workspace_list.selectRow(priv.workspace_list.getRowAtIndex(index));
        // Selection drives status-line color (explicit colors yield to the
        // selected foreground), so rows repaint when the selection moves.
        self.refreshWorkspaceRows();
    }

    fn workspaceBackgroundPressed(
        gesture: *gtk.GestureClick,
        n_press: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        if (n_press != 2) return;
        const widget = gesture.as(gtk.EventController).getWidget() orelse return;
        var target = widget.pick(x, y, .{});
        while (target) |child| : (target = child.getParent()) {
            // Rows keep their selection behavior; scrollbars keep scrolling.
            if (gobject.ext.cast(gtk.ListBoxRow, child) != null or
                gobject.ext.cast(gtk.Scrollbar, child) != null) return;
            if (child == widget) break;
        }
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        self.newTab(if (self.getActiveSurface()) |surface| surface.core() else null);
    }

    fn workspaceSelected(
        _: *gtk.ListBox,
        row_: ?*gtk.ListBoxRow,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.syncing_workspace) return;
        const row = row_ orelse return;
        const index = row.getIndex();
        if (index < 0 or index >= priv.tab_view.getNPages()) return;
        priv.tab_view.setSelectedPage(priv.tab_view.getNthPage(index));
        if (self.getActiveSurface()) |surface| {
            surface.grabFocus();
        }
    }

    fn tabFromWorkspaceRow(row: *gtk.ListBoxRow) ?*Tab {
        const ptr = row.as(gobject.Object).getData("colm-workspace-row") orelse return null;
        const state: *WorkspaceRow = @ptrCast(@alignCast(ptr));
        return state.tab;
    }

    fn groupIsCollapsed(self: *Self, key: []const u8) bool {
        for (self.private().collapsed_groups.items) |item| {
            if (std.mem.eql(u8, item, key)) return true;
        }
        return false;
    }

    fn toggleGroupCollapsed(self: *Self, key: []const u8) void {
        const list = &self.private().collapsed_groups;
        for (list.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item, key)) continue;
            a.free(item);
            _ = list.swapRemove(index);
            self.refreshWorkspaceRows();
            return;
        }
        const copy = a.dupe(u8, key) catch return;
        list.append(a, copy) catch {
            a.free(copy);
            return;
        };
        self.refreshWorkspaceRows();
    }

    fn workspaceGroupHeader(row: *gtk.ListBoxRow, before: ?*gtk.ListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const tab = tabFromWorkspaceRow(row) orelse {
            row.setHeader(null);
            return;
        };
        const automation = @import("../automation.zig");
        const group = automation.workspaceGroup(tab) orelse {
            row.setHeader(null);
            return;
        };
        if (before) |prev| {
            if (tabFromWorkspaceRow(prev)) |prev_tab| {
                if (automation.workspaceGroup(prev_tab)) |previous| {
                    if (std.mem.eql(u8, previous.key, group.key)) {
                        row.setHeader(null);
                        return;
                    }
                }
            }
        }
        const collapsed = self.groupIsCollapsed(group.key);
        const label = std.fmt.allocPrintSentinel(a, "{s} {s}", .{ if (collapsed) "▸" else "▾", group.name }, 0) catch {
            row.setHeader(null);
            return;
        };
        defer a.free(label);
        const button = gtk.Button.newWithLabel(label);
        button.as(gtk.Widget).addCssClass("flat");
        button.as(gtk.Widget).addCssClass("workspace-group");
        button.as(gtk.Widget).setHalign(.start);

        const payload = a.create(GroupToggle) catch {
            row.setHeader(null);
            return;
        };
        payload.* = .{ .window = self, .key = a.dupe(u8, group.key) catch {
            a.destroy(payload);
            row.setHeader(null);
            return;
        } };
        button.as(gobject.Object).setDataFull("colm-group-toggle", payload, GroupToggle.destroy);
        _ = gtk.Button.signals.clicked.connect(button, *GroupToggle, GroupToggle.clicked, payload, .{});
        row.setHeader(button.as(gtk.Widget));
    }

    const GroupToggle = struct {
        window: *Self,
        key: []u8,

        fn destroy(ptr: ?*anyopaque) callconv(.c) void {
            const self: *GroupToggle = @ptrCast(@alignCast(ptr.?));
            a.free(self.key);
            a.destroy(self);
        }

        fn clicked(_: *gtk.Button, self: *GroupToggle) callconv(.c) void {
            self.window.toggleGroupCollapsed(self.key);
        }
    };

    fn workspaceDragPrepare(_: *gtk.DragSource, _: f64, _: f64, row: *gtk.ListBoxRow) callconv(.c) ?*gdk.ContentProvider {
        var value = gobject.ext.Value.newFrom(row.getIndex());
        defer value.unset();
        return gdk.ContentProvider.newForValue(&value);
    }

    fn workspaceDropMotion(_: *gtk.DropTarget, _: f64, y: f64, self: *Self) callconv(.c) gdk.DragAction {
        const list = self.private().workspace_list;
        list.dragUnhighlightRow();
        if (list.getRowAtY(@intFromFloat(y))) |row| list.dragHighlightRow(row);
        return .{ .move = true };
    }

    fn workspaceDropLeave(_: *gtk.DropTarget, self: *Self) callconv(.c) void {
        self.private().workspace_list.dragUnhighlightRow();
    }

    fn workspaceDrop(_: *gtk.DropTarget, value: *gobject.Value, _: f64, y: f64, self: *Self) callconv(.c) c_int {
        const priv = self.private();
        priv.workspace_list.dragUnhighlightRow();
        const source = gobject.ext.Value.get(value, c_int);
        const dest_row = priv.workspace_list.getRowAtY(@intFromFloat(y)) orelse return 0;
        var dest = dest_row.getIndex();
        if (source < 0 or dest < 0 or source == dest) return 0;
        const view = priv.tab_view;
        if (source >= view.getNPages() or dest >= view.getNPages()) return 0;
        const automation = @import("../automation.zig");
        const source_tab = gobject.ext.cast(Tab, view.getNthPage(source).getChild()) orelse return 0;
        const pinned = automation.workspacePinned(source_tab);
        var first_unpinned: c_int = 0;
        while (first_unpinned < view.getNPages()) : (first_unpinned += 1) {
            const tab = gobject.ext.cast(Tab, view.getNthPage(first_unpinned).getChild()) orelse continue;
            if (!automation.workspacePinned(tab)) break;
        }
        if (pinned) {
            const last_pinned = @max(first_unpinned - 1, 0);
            dest = @min(dest, last_pinned);
        } else dest = @max(dest, first_unpinned);
        if (source < dest) dest -= 1;
        if (dest < 0 or dest >= view.getNPages() or dest == source) return 0;
        return view.reorderPage(view.getNthPage(source), dest);
    }

    fn workspaceId(tab: *Tab) [32]u8 {
        return @import("../automation.zig").id(tab)[0..32].*;
    }

    fn tabIsMultiSelected(self: *Self, tab: *Tab) bool {
        const id = workspaceId(tab);
        for (self.private().multi_selected.items) |item| {
            if (std.mem.eql(u8, &item, &id)) return true;
        }
        return false;
    }

    fn toggleMultiSelect(self: *Self, tab: *Tab) void {
        const id = workspaceId(tab);
        const list = &self.private().multi_selected;
        for (list.items, 0..) |item, index| {
            if (!std.mem.eql(u8, &item, &id)) continue;
            _ = list.orderedRemove(index);
            self.refreshWorkspaceRows();
            return;
        }
        list.append(a, id) catch return;
        self.refreshWorkspaceRows();
    }

    fn clearMultiSelect(self: *Self) void {
        if (self.private().multi_selected.items.len == 0) return;
        self.private().multi_selected.clearRetainingCapacity();
        self.refreshWorkspaceRows();
    }

    fn rangeSelect(self: *Self, tab: *Tab) void {
        const view = self.private().tab_view;
        const dest_page = view.getPage(tab.as(gtk.Widget));
        const dest = view.getPagePosition(dest_page);
        const start = if (view.getSelectedPage()) |page| view.getPagePosition(page) else dest;
        const lo = @min(start, dest);
        const hi = @max(start, dest);
        var index = lo;
        while (index <= hi) : (index += 1) {
            const other = gobject.ext.cast(Tab, view.getNthPage(index).getChild()) orelse continue;
            const id = workspaceId(other);
            const list = &self.private().multi_selected;
            var found = false;
            for (list.items) |item| {
                if (std.mem.eql(u8, &item, &id)) {
                    found = true;
                    break;
                }
            }
            if (!found) list.append(a, id) catch break;
        }
        self.refreshWorkspaceRows();
    }

    fn selectedTabs(self: *Self, clicked: *Tab) []const *Tab {
        const view = self.private().tab_view;
        if (!self.tabIsMultiSelected(clicked) or self.private().multi_selected.items.len == 0) {
            const one = a.alloc(*Tab, 1) catch return &.{};
            one[0] = clicked;
            return one;
        }
        var tabs: std.ArrayList(*Tab) = .empty;
        var index: c_int = 0;
        while (index < view.getNPages()) : (index += 1) {
            const tab = gobject.ext.cast(Tab, view.getNthPage(index).getChild()) orelse continue;
            if (self.tabIsMultiSelected(tab)) tabs.append(a, tab) catch break;
        }
        return tabs.toOwnedSlice(a) catch &.{};
    }

    fn closeSelectedWorkspaces(self: *Self, clicked: *Tab) void {
        const automation = @import("../automation.zig");
        const tabs = self.selectedTabs(clicked);
        defer a.free(tabs);
        for (tabs) |tab| {
            if (automation.workspacePinned(tab)) continue;
            self.automationCloseTab(tab);
        }
        self.clearMultiSelect();
    }

    fn popupWorkspaceMenu(self: *Self, row: *WorkspaceRow) void {
        const automation = @import("../automation.zig");
        self.private().context_workspace = row.tab;
        const tabs = self.selectedTabs(row.tab);
        defer a.free(tabs);
        const count = tabs.len;
        const pin_label: [:0]const u8 = if (count > 1) "Pin selected" else if (automation.workspacePinned(row.tab)) "Unpin" else "Pin";
        const mute_label: [:0]const u8 = if (count > 1) "Mute selected" else if (automation.workspaceMuted(row.tab)) "Unmute" else "Mute";
        const close_label: [:0]const u8 = if (count > 1) "Close selected" else "Close";
        const group_label: [:0]const u8 = if (count > 1) "Group selected" else "New group";
        const menu = gio.Menu.new();
        const actions = gio.Menu.new();
        actions.append(pin_label, "win.workspace-pin");
        actions.append(mute_label, "win.workspace-mute");
        const status_menu = gio.Menu.new();
        status_menu.append("●  Running", "win.workspace-task-status::running");
        status_menu.append("◼  Blocked", "win.workspace-task-status::blocked");
        status_menu.append("⚠  Error", "win.workspace-task-status::error");
        status_menu.append("✓  Done", "win.workspace-task-status::done");
        status_menu.append("Clear", "win.workspace-task-status::clear");
        actions.appendSubmenu("Task status", status_menu.as(gio.MenuModel));
        actions.append(group_label, "win.workspace-group");
        menu.appendSection(null, actions.as(gio.MenuModel));
        const danger = gio.Menu.new();
        danger.append(close_label, "win.workspace-close");
        menu.appendSection(null, danger.as(gio.MenuModel));
        const popover = gtk.PopoverMenu.newFromModel(menu.as(gio.MenuModel));
        popover.as(gtk.Popover).setHasArrow(0);
        popover.as(gtk.Widget).setParent(row.row.as(gtk.Widget));
        _ = gtk.Popover.signals.closed.connect(
            popover.as(gtk.Popover),
            *Self,
            workspaceMenuClosed,
            self,
            .{},
        );
        popover.as(gtk.Popover).popup();
    }

    fn workspaceMenuClosed(popover: *gtk.Popover, self: *Self) callconv(.c) void {
        // Do not clear context_workspace here: PopoverMenu activates the
        // GAction after `closed`. Unparent on idle so activate still runs.
        _ = self;
        _ = popover.as(gobject.Object).ref();
        _ = glib.idleAdd(unparentWorkspaceMenu, popover);
    }

    fn unparentWorkspaceMenu(data: ?*anyopaque) callconv(.c) c_int {
        const popover: *gtk.Popover = @ptrCast(@alignCast(data.?));
        const widget = popover.as(gtk.Widget);
        if (widget.getParent() != null) widget.unparent();
        popover.as(gobject.Object).unref();
        return 0;
    }

    fn actionWorkspacePin(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const tab = self.private().context_workspace orelse return;
        const automation = @import("../automation.zig");
        const tabs = self.selectedTabs(tab);
        defer a.free(tabs);
        const pin = if (tabs.len == 1) !automation.workspacePinned(tab) else true;
        for (tabs) |item| automation.setWorkspacePinned(item, pin);
        self.clearMultiSelect();
        self.refreshWorkspaceRows();
    }

    fn actionWorkspaceMute(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const tab = self.private().context_workspace orelse return;
        const automation = @import("../automation.zig");
        const tabs = self.selectedTabs(tab);
        defer a.free(tabs);
        const mute = if (tabs.len == 1) !automation.workspaceMuted(tab) else true;
        for (tabs) |item| automation.setWorkspaceMuted(item, mute);
        self.clearMultiSelect();
        self.refreshWorkspaceRows();
    }

    fn actionWorkspaceGroup(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const tab = self.private().context_workspace orelse return;
        self.groupWorkspaces(tab);
    }

    fn actionWorkspaceClose(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void {
        const tab = self.private().context_workspace orelse return;
        self.closeSelectedWorkspaces(tab);
    }

    fn actionWorkspaceTaskStatus(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab = self.private().context_workspace orelse return;
        const param = param_ orelse return;
        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);
        const value = std.mem.span(str orelse return);
        const status: ?[]const u8 = if (value.len == 0 or std.mem.eql(u8, value, "clear"))
            null
        else
            value;
        const tabs = self.selectedTabs(tab);
        defer a.free(tabs);
        for (tabs) |item| @import("../automation.zig").setWorkspaceTaskStatus(item, status);
        self.refreshWorkspaceRows();
    }

    fn tabViewPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // Get the attached page which must be a Tab object.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;

        // Attach listeners for the tab.
        _ = Tab.signals.@"close-request".connect(
            tab,
            *Self,
            tabCloseRequest,
            self,
            .{},
        );

        // Attach listeners for the surface.
        //
        // Interesting behavior here that was previously undocumented but
        // I'm going to make it explicit here: we accept all the signals here
        // (like toggle-fullscreen) regardless of whether the surface or tab
        // is focused. At the time of writing this we have no API that could
        // really trigger these that way but its theoretically possible.
        //
        // What is DEFINITELY possible is something like OSC52 triggering
        // a clipboard-write signal on an unfocused tab/surface. We definitely
        // want to show the user a notification about that but our notification
        // right now is a toast that doesn't make it clear WHO used the
        // clipboard. We probably want to change that in the future.
        //
        // I'm not sure how desirable all the above is, and we probably
        // should be thoughtful about future signals here. But all of this
        // behavior is consistent with macOS and the previous GTK apprt,
        // but that behavior was all implicit and not documented, so here
        // I am.
        if (tab.getSurfaceTree()) |tree| {
            self.connectSurfaceHandlers(tree);
        }
        _ = gobject.Object.signals.notify.connect(
            tab,
            *Self,
            workspaceActiveSurfaceChanged,
            self,
            .{ .detail = "active-surface" },
        );
    }

    fn tabViewPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // We need to get the tab to disconnect the signals.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        const id = workspaceId(tab);
        const list = &self.private().multi_selected;
        for (list.items, 0..) |item, index| {
            if (!std.mem.eql(u8, &item, &id)) continue;
            _ = list.orderedRemove(index);
            break;
        }

        _ = gobject.signalHandlersDisconnectMatched(
            tab.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        // Remove the tree handlers
        if (tab.getSurfaceTree()) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }
    }

    fn tabViewCreateWindow(
        _: *adw.TabView,
        _: *Self,
    ) callconv(.c) *adw.TabView {
        // Create a new window without creating a new tab.
        const win = gobject.ext.newInstance(
            Self,
            .{
                .application = Application.default(),
            },
        );

        // We have to show it otherwise it'll just be hidden.
        gtk.Window.present(win.as(gtk.Window));

        // Get our tab view
        return win.private().tab_view;
    }

    fn tabCloseRequest(
        tab: *Tab,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.tab_view.getPage(tab.as(gtk.Widget));
        // TODO: connect close page handler to tab to check for confirmation
        priv.tab_view.closePage(page);
    }

    fn tabViewNPages(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        self.syncWorkspaceSelection();
        @import("../automation.zig").sessionChanged();
        if (priv.tab_view.getNPages() == 0) {
            // If we have no pages left then we want to close window.
            self.as(gtk.Window).close();
        }
    }
    fn setupTabMenu(
        _: *adw.TabView,
        page: ?*adw.TabPage,
        self: *Self,
    ) callconv(.c) void {
        self.private().context_menu_page = page;
    }

    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        // We only toast for the standard clipboard.
        if (clipboard_type != .standard) return;

        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }

        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }

    fn surfaceMenu(
        _: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.syncActions();
    }

    fn surfacePresentRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        // Verify that this surface is actually in this window.
        {
            const surface_window = ext.getAncestor(
                Self,
                surface.as(gtk.Widget),
            ) orelse {
                log.warn(
                    "present request called for non-existent surface",
                    .{},
                );
                return;
            };
            if (surface_window != self) {
                log.warn(
                    "present request called for surface in different window",
                    .{},
                );
                return;
            }
        }

        // Get the tab for this surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse {
            log.warn("present request surface not found", .{});
            return;
        };

        // Get the page that contains this tab
        const priv = self.private();
        const tab_view = priv.tab_view;
        const page = tab_view.getPage(tab.as(gtk.Widget));
        tab_view.setSelectedPage(page);

        // Grab focus
        surface.grabFocus();

        // Bring the window to the front.
        self.as(gtk.Window).present();
    }

    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }

        // We react to the changes in the propFullscreen callback
    }

    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }

        // We react to the changes in the propMaximized callback
    }

    fn surfaceInit(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Make sure we init only once
        if (priv.surface_init) return;
        priv.surface_init = true;

        // Setup our default and minimum size.
        if (surface.getDefaultSize()) |size| {
            self.as(gtk.Window).setDefaultSize(
                @intCast(@max(size.width, 1280)),
                @intCast(@max(size.height, 800)),
            );
        }
        if (surface.getMinSize()) |size| {
            self.as(gtk.Widget).setSizeRequest(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
    }

    fn tabSplitTreeChanged(
        _: *SplitTree,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        if (old_tree) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        if (new_tree) |tree| {
            self.connectSurfaceHandlers(tree);
        }

        if (self.private().column_overview.getRevealChild() != 0)
            self.populateColumnOverview();
    }

    fn actionAppearance(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        AppearanceDialog.present(self.as(gtk.Window));
    }

    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = "Colm";
        const icon = "io.github.al3rez.Colm";
        const copyright = "© 2024 Mitchell Hashimoto, Ghostty contributors";

        if (adw_version.supportsDialogs()) {
            const dialog = adw.AboutDialog.new();
            dialog.setApplicationName(name);
            dialog.setApplicationIcon(icon);
            dialog.setVersion(build_config.version_string);
            dialog.setLicenseType(.mit_x11);
            dialog.setCopyright(copyright);
            var engine = [_:null]?[*:0]const u8{
                "Ghostty contributors https://github.com/ghostty-org/ghostty",
            };
            dialog.addCreditSection("Terminal engine", @ptrCast(&engine));
            dialog.as(adw.Dialog).present(self.as(gtk.Widget));
        } else {
            gtk.showAboutDialog(
                self.as(gtk.Window),
                "program-name",
                name,
                "logo-icon-name",
                icon,
                "title",
                i18n._("About Colm"),
                "version",
                build_config.version_string.ptr,
                "license-type",
                @as(c_int, @intFromEnum(gtk.License.mit_x11)),
                "copyright",
                copyright,
                @as(?*anyopaque, null),
            );
        }
    }

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionCloseTab(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("win.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const mode = std.meta.stringToEnum(
            input.Binding.Action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to win.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            log.warn("invalid mode provided to win.close-tab: {s}", .{str.?});
            return;
        };

        self.performBindingAction(.{ .close_tab = mode });
    }

    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }

    fn actionNewTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.showWorkspaceSetup();
    }

    fn showWorkspaceSetup(self: *Self) void {
        const state = std.heap.c_allocator.create(WorkspaceSetup) catch {
            self.addToast("Not enough memory to create a workspace.");
            return;
        };
        const dialog = adw.AlertDialog.new("New workspace", "Keep a project's terminals together.");
        const name = adw.EntryRow.new();
        name.as(adw.PreferencesRow).setTitle("Name");
        var name_buf: [64]u8 = undefined;
        const default_name = std.fmt.bufPrintZ(
            &name_buf,
            "Workspace {d}",
            .{self.private().workspace_serial + 1},
        ) catch unreachable;
        name.as(gtk.Editable).setText(default_name);

        const description = adw.EntryRow.new();
        description.as(adw.PreferencesRow).setTitle("Description (optional)");

        const folder = adw.ActionRow.new();
        folder.as(adw.PreferencesRow).setTitle("Starting folder");
        folder.as(adw.PreferencesRow).setUseMarkup(0);
        folder.setSubtitleLines(2);
        const pwd = if (self.getActiveSurface()) |surface| @import("../automation.zig").localDirectory(surface) else null;
        folder.setSubtitle(if (pwd) |path| path.ptr else glib.getHomeDir());
        const browse = gtk.Button.newFromIconName("folder-open-symbolic");
        browse.as(gtk.Widget).setValign(.center);
        browse.as(gtk.Widget).setTooltipText("Choose starting folder");
        browse.as(gtk.Widget).addCssClass("flat");
        folder.addSuffix(browse.as(gtk.Widget));
        folder.setActivatableWidget(browse.as(gtk.Widget));

        const fields = gtk.ListBox.new();
        fields.setSelectionMode(.none);
        fields.as(gtk.Widget).addCssClass("boxed-list");
        fields.append(name.as(gtk.Widget));
        fields.append(description.as(gtk.Widget));
        fields.append(folder.as(gtk.Widget));
        dialog.setExtraChild(fields.as(gtk.Widget));
        dialog.addResponse("cancel", "_Cancel");
        dialog.addResponse("create", "_Create");
        dialog.setDefaultResponse("create");
        dialog.setCloseResponse("cancel");
        dialog.setResponseAppearance("create", .suggested);
        _ = self.as(gobject.Object).ref();
        state.* = .{
            .window = self,
            .dialog = dialog,
            .name = name,
            .description = description,
            .folder = folder,
        };
        dialog.as(gobject.Object).setDataFull("colm-workspace-setup", state, WorkspaceSetup.destroy);
        _ = gtk.Button.signals.clicked.connect(browse, *WorkspaceSetup, WorkspaceSetup.browse, state, .{});
        _ = adw.AlertDialog.signals.response.connect(dialog, *WorkspaceSetup, WorkspaceSetup.respond, state, .{});
        for ([_]*adw.EntryRow{ name, description }) |entry| {
            _ = adw.EntryRow.signals.entry_activated.connect(
                entry,
                *WorkspaceSetup,
                WorkspaceSetup.entryActivated,
                state,
                .{},
            );
        }
        dialog.as(adw.Dialog).present(self.as(gtk.Widget));
        _ = name.as(gtk.Widget).grabFocus();
        name.as(gtk.Editable).selectRegion(0, -1);
    }

    const WorkspaceSetup = struct {
        window: *Window,
        dialog: *adw.AlertDialog,
        name: *adw.EntryRow,
        description: *adw.EntryRow,
        folder: *adw.ActionRow,
        created: bool = false,

        fn destroy(data: ?*anyopaque) callconv(.c) void {
            const self: *WorkspaceSetup = @ptrCast(@alignCast(data.?));
            self.window.as(gobject.Object).unref();
            std.heap.c_allocator.destroy(self);
        }

        fn respond(_: *adw.AlertDialog, response: [*:0]u8, self: *WorkspaceSetup) callconv(.c) void {
            if (!std.mem.eql(u8, std.mem.span(response), "create")) return;
            self.create();
        }

        fn entryActivated(_: *adw.EntryRow, self: *WorkspaceSetup) callconv(.c) void {
            self.create();
            self.dialog.as(adw.Dialog).forceClose();
        }

        fn create(self: *WorkspaceSetup) void {
            if (self.created) return;
            self.created = true;
            const path = self.folder.getSubtitle() orelse glib.getHomeDir();
            const page = self.window.newTabPage(null, .tab, .{ .working_directory = std.mem.span(path) });
            const name = std.mem.span(self.name.as(gtk.Editable).getText());
            if (name.len != 0) {
                gobject.ext.cast(Tab, page.getChild()).?.setTitleOverride(name);
            }
            const description = std.mem.span(self.description.as(gtk.Editable).getText());
            if (description.len != 0) {
                @import("../automation.zig").setWorkspaceDescription(
                    gobject.ext.cast(Tab, page.getChild()).?,
                    description,
                );
            }
        }

        fn browse(_: *gtk.Button, self: *WorkspaceSetup) callconv(.c) void {
            const chooser = gtk.FileDialog.new();
            defer chooser.as(gobject.Object).unref();
            chooser.setTitle("Choose starting folder");
            const folder = gio.File.newForPath(self.folder.getSubtitle() orelse glib.getHomeDir());
            defer folder.as(gobject.Object).unref();
            chooser.setInitialFolder(folder);
            // Keep dialog-owned callback data alive even if its parent closes.
            _ = self.dialog.as(gobject.Object).ref();
            chooser.selectFolder(self.window.as(gtk.Window), null, folderChosen, self);
        }

        fn folderChosen(source: ?*gobject.Object, result: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
            const self: *WorkspaceSetup = @ptrCast(@alignCast(data.?));
            defer self.dialog.as(gobject.Object).unref();
            const chooser = gobject.ext.cast(gtk.FileDialog, source.?).?;
            var err: ?*glib.Error = null;
            const folder = chooser.selectFolderFinish(result, &err) orelse {
                if (err) |e| e.free();
                return;
            };
            defer folder.as(gobject.Object).unref();
            const path = folder.getPath() orelse return;
            defer glib.free(path);
            self.folder.setSubtitle(path);
        }
    };

    fn actionPromptContextTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.context_menu_page orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        tab.promptTabTitle();
    }

    fn actionPromptSurfaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_surface_title);
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_tab_title);
    }

    fn actionCloseTerminal(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.close_surface);
    }

    fn actionSplitRight(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        if (self.private().dock_focus) {
            self.runDockAction(2);
            return;
        }
        self.performBindingAction(.{ .new_split = .right });
    }

    fn actionSplitLeft(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }

    fn actionSplitUp(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }

    fn actionSplitDown(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        if (self.private().dock_focus) {
            self.runDockAction(3);
            return;
        }
        self.performBindingAction(.{ .new_split = .down });
    }

    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }

    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;

        if (config.@"bell-features".system) system: {
            const native = self.as(gtk.Native).getSurface() orelse {
                log.warn("unable to get native surface from window", .{});
                break :system;
            };
            native.beep();
        }

        if (config.@"bell-features".attention) attention: {
            // Dont set urgency if the window is already active.
            if (self.as(gtk.Window).isActive() != 0) break :attention;

            // Request user attention
            self.winproto().setUrgent(true) catch |err| {
                log.warn("winproto failed to set urgency={}", .{err});
            };
        }
    }

    /// Toggle the command palette.
    ///
    /// TODO: accept the surface that toggled the command palette as a parameter
    fn toggleCommandPalette(self: *Window) void {
        const priv = self.private();

        // Get a reference to a command palette. First check the weak reference
        // that we save to see if we already have one stored. If we don't then
        // create a new one.
        const command_palette = priv.command_palette.get() orelse command_palette: {
            // Create a fresh command palette.
            const command_palette = CommandPalette.new();

            // Synchronize our config to the command palette's config.
            _ = gobject.Object.bindProperty(
                self.as(gobject.Object),
                "config",
                command_palette.as(gobject.Object),
                "config",
                .{ .sync_create = true },
            );

            // Listen to the activate signal to know if the user selected an option in
            // the command palette.
            _ = CommandPalette.signals.trigger.connect(
                command_palette,
                *Window,
                signalCommandPaletteTrigger,
                self,
                .{},
            );

            // Save a weak reference to the command palette. We use a weak reference to avoid
            // reference counting cycles that might cause problems later.
            priv.command_palette.set(command_palette);

            break :command_palette command_palette;
        };
        defer command_palette.unref();

        // Tell the command palette to toggle itself. If the dialog gets
        // presented (instead of hidden) it will be modal over our window.
        command_palette.toggle(self);
    }

    // React to a signal from a command palette asking an action to be performed.
    fn signalCommandPaletteTrigger(_: *CommandPalette, action: *const input.Binding.Action, self: *Self) callconv(.c) void {
        // If the activation actually has an action, perform it.
        self.performBindingAction(action.*);
    }

    /// React to a GTK action requesting that the command palette be toggled.
    fn actionToggleCommandPalette(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleCommandPalette();
    }

    /// Toggle the Ghostty inspector for the active surface.
    fn toggleInspector(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        _ = surface.controlInspector(.toggle);
    }

    /// React to a GTK action requesting that the Ghostty inspector be toggled.
    fn actionToggleInspector(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleInspector();
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(Tab);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"quick-terminal".impl,
                properties.@"toolbar-style".impl,
                properties.@"titlebar-style".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("workspace_list", .{});
            class.bindTemplateChildPrivate("right_sidebar_panel", .{});
            class.bindTemplateChildPrivate("tab_view", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateChildPrivate("main_popover", .{});
            class.bindTemplateChildPrivate("right_sidebar", .{});
            class.bindTemplateChildPrivate("right_sidebar_title", .{});
            class.bindTemplateChildPrivate("activity_list", .{});
            class.bindTemplateChildPrivate("column_overview", .{});
            class.bindTemplateChildPrivate("column_overview_grid", .{});
            class.bindTemplateChildPrivate("column_overview_title", .{});
            class.bindTemplateChildPrivate("column_overview_search_bar", .{});
            class.bindTemplateChildPrivate("column_overview_search", .{});

            // Template Callbacks
            class.bindTemplateCallback("realize", &windowRealize);
            class.bindTemplateCallback("workspace_selected", &workspaceSelected);
            class.bindTemplateCallback("workspace_background_pressed", &workspaceBackgroundPressed);
            class.bindTemplateCallback("column_overview_child_activated", &columnOverviewChildActivated);
            class.bindTemplateCallback("column_overview_search_changed", &columnOverviewSearchChanged);
            class.bindTemplateCallback("column_overview_new_clicked", &columnOverviewNewClicked);
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("close_page", &tabViewClosePage);
            class.bindTemplateCallback("page_attached", &tabViewPageAttached);
            class.bindTemplateCallback("page_detached", &tabViewPageDetached);
            class.bindTemplateCallback("setup_tab_menu", &setupTabMenu);
            class.bindTemplateCallback("tab_create_window", &tabViewCreateWindow);
            class.bindTemplateCallback("notify_n_pages", &tabViewNPages);
            class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_is_active", &propIsActive);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_quick_terminal", &propQuickTerminal);
            class.bindTemplateCallback("notify_scale_factor", &propScaleFactor);
            class.bindTemplateCallback("computed_subtitle", &closureSubtitle);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
