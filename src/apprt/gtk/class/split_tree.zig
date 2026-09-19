const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gsk = @import("gsk");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const Surface = @import("surface.zig").Surface;
const SurfaceScrolledWindow = @import("surface_scrolled_window.zig").SurfaceScrolledWindow;

const log = std.log.scoped(.gtk_ghostty_split_tree);

pub const SplitTree = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitTree",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
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
                            .getter = getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const @"has-surfaces" = struct {
            pub const name = "has-surfaces";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getHasSurfaces,
                        },
                    ),
                },
            );
        };

        pub const @"is-zoomed" = struct {
            pub const name = "is-zoomed";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getIsZoomed,
                        },
                    ),
                },
            );
        };

        pub const tree = struct {
            pub const name = "tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = .{
                        .getter = getTreeValue,
                        .setter = setTreeValue,
                    },
                },
            );
        };

        pub const @"is-split" = struct {
            pub const name = "is-split";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getIsSplit,
                        },
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tree property has changed, with access
        /// to the previous and new values.
        pub const changed = struct {
            pub const name = "changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ ?*const Surface.Tree, ?*const Surface.Tree },
                void,
            );
        };
    };

    const Private = struct {
        /// The tree datastructure containing all of our surface views.
        tree: ?*Surface.Tree,

        // Each workspace owns its canvas and therefore its scroll position.
        canvas: *gtk.ScrolledWindow,
        columns: *gtk.Box,
        reveal_tick: c_uint = 0,
        reveal_ready: bool = false,

        canvas_page_size: f64 = 0,
        /// Last focused surface in the tree. We need this to handle various
        /// tree change states.
        last_focused: WeakRef(Surface) = .empty,

        /// The source that we use to rebuild the tree. This is also
        /// used to debounce updates.
        rebuild_source: ?c_uint = null,

        /// Used to store state about a pending surface close for the
        /// close dialog.
        pending_close: ?Surface.Tree.Node.Handle,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Initialize our actions
        self.initActionMap();

        // Initialize some basic state
        const priv = self.private();
        priv.pending_close = null;
    }

    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            // All of these will eventually take a target surface parameter.
            // For now all our targets originate from the focused surface.
            .init("new-split", actionNewSplit, s_variant_type),
            .init("equalize", actionEqualize, null),
            .init("zoom", actionZoom, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "split-tree", &actions);
    }

    /// Create a new split in the given direction from the currently
    /// active surface.
    ///
    /// If the tree is empty this will create a new tree with a new surface
    /// and ignore the direction.
    ///
    /// The parent will be used as the parent of the surface regardless of
    /// if that parent is in this split tree or not. This allows inheriting
    /// surface properties from anywhere.
    pub fn newSplit(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        parent_: ?*Surface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) Allocator.Error!void {
        if (overrides.command == null and @import("../automation.zig").addRemoteTerminal(self.as(gtk.Widget))) return;
        const alloc = Application.default().allocator();

        // Create our new surface.
        const surface: *Surface = .new(.{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });
        defer surface.unref();
        _ = surface.refSink();

        // Inherit properly if we were asked to.
        if (parent_) |p| {
            if (p.core()) |core| {
                surface.setParent(core, .split);
            }
        }

        // Bind is-split property for new surface
        _ = self.as(gobject.Object).bindProperty(
            "is-split",
            surface.as(gobject.Object),
            "is-split",
            .{ .sync_create = true },
        );

        // Create our tree
        var single_tree = try Surface.Tree.init(alloc, surface);
        defer single_tree.deinit();
        const active_handle = self.getActiveSurfaceHandle() orelse .root;

        // We want to move our focus to the new surface no matter what.
        // But we need to be careful to restore state if we fail.
        const old_last_focused = self.private().last_focused.get();
        defer if (old_last_focused) |v| v.unref(); // unref strong ref from get
        self.private().last_focused.set(surface);
        errdefer self.private().last_focused.set(old_last_focused);

        // If we have no tree yet, then this becomes our tree and we're done.
        const old_tree = self.getTree() orelse {
            self.setTree(&single_tree);
            return;
        };

        // Split relative to the requested parent when it belongs to this tree.
        // UI-created splits pass the active surface; automation can target any
        // existing pane without stealing focus first.
        const handle = if (parent_) |parent| target: {
            var it = old_tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == parent) break :target entry.handle;
            }
            break :target active_handle;
        } else active_handle;

        // Create our split!
        var new_tree = try old_tree.split(
            alloc,
            handle,
            direction,
            0.5, // Always split equally for new splits
            &single_tree,
        );
        defer new_tree.deinit();
        log.debug(
            "new split at={} direction={} old_tree={f} new_tree={f}",
            .{ handle, direction, old_tree, &new_tree },
        );

        // Replace our tree
        self.setTree(&new_tree);
    }

    /// A niri column that is not a terminal leaf (browser, later guests).
    /// Lives in the same horizontal strip as TerminalColumn; rebuilds skip it.
    pub fn appendGuestColumn(self: *Self, child: *gtk.Widget) void {
        const column = GuestColumn.new();
        child.setHexpand(1);
        child.setVexpand(1);
        child.setHalign(.fill);
        child.setValign(.fill);
        column.as(gtk.Box).append(child);
        const priv = self.private();
        var padding: gtk.Border = undefined;
        priv.columns.as(gtk.Widget).getStyleContext().getPadding(&padding);
        const page_width: c_int = @intFromFloat(priv.canvas.getHadjustment().getPageSize());
        var page_height: c_int = @intFromFloat(priv.canvas.getVadjustment().getPageSize());
        if (page_height <= 0) page_height = priv.canvas.as(gtk.Widget).getHeight();
        const default_width = @max(1, page_width - padding.f_left - padding.f_right);
        const default_height = @max(1, page_height - padding.f_top - padding.f_bottom);
        column.as(gtk.Widget).setSizeRequest(default_width, default_height);

        priv.columns.append(column.as(gtk.Widget));
        self.updateColumnSizes();
        self.revealGuest(column.as(gtk.Widget));

    }


    fn revealGuest(self: *Self, column: *gtk.Widget) void {
        const priv = self.private();
        var allocation: gtk.Allocation = undefined;
        column.getAllocation(&allocation);
        const adjustment = priv.canvas.getHadjustment();
        const start: f64 = @floatFromInt(allocation.f_x);
        adjustment.setValue(std.math.clamp(
            start,
            adjustment.getLower(),
            @max(adjustment.getLower(), adjustment.getUpper() - adjustment.getPageSize()),
        ));
        self.revealActive();
    }


    /// Create a new surface tab inside an existing pane without adding a
    /// layout split or restarting the parent terminal.
    pub fn newSurface(
        self: *Self,
        parent_: ?*Surface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,
        },
    ) Allocator.Error!void {
        const parent = parent_ orelse self.getActiveSurface();
        const column = if (parent) |surface|
            ext.getAncestor(TerminalColumn, surface.as(gtk.Widget))
        else
            null;
        const target = column orelse return self.newSplit(.right, parent, .{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });

        const surface: *Surface = .new(.{
            .command = overrides.command,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });
        defer surface.unref();
        _ = surface.refSink();
        if (parent) |value| {
            if (value.core()) |core| surface.setParent(core, .tab);
        }
        _ = self.as(gobject.Object).bindProperty(
            "is-split",
            surface.as(gobject.Object),
            "is-split",
            .{ .sync_create = true },
        );
        if (!target.addSurface(surface)) return error.OutOfMemory;
        self.private().last_focused.set(surface);
        self.activateColumnSurface(target, surface);
    }

    pub fn surfaceCount(self: *Self) usize {
        var count: usize = 0;
        var child = self.private().columns.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            const column = gobject.ext.cast(TerminalColumn, widget) orelse continue;
            count += column.private().surfaces.items.len;
        }
        return count;
    }

    pub fn surfaceAt(self: *Self, target: usize) ?*Surface {
        var index: usize = 0;
        var child = self.private().columns.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            const column = gobject.ext.cast(TerminalColumn, widget) orelse continue;
            for (column.private().surfaces.items) |entry| {
                if (index == target) return entry.surface;
                index += 1;
            }
        }
        return null;
    }


    pub fn paneActiveSurface(self: *Self, surface: *Surface) ?*Surface {
        _ = self;
        const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse return null;
        return column.activeSurface();
    }

    pub fn paneObject(self: *Self, surface: *Surface) ?*gobject.Object {
        if (ext.getAncestor(TerminalColumn, surface.as(gtk.Widget))) |column| {
            return column.as(gobject.Object);
        }
        self.flushPendingRebuild();
        const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse return null;
        return column.as(gobject.Object);
    }

    pub fn paneWidth(self: *Self, surface: *Surface) c_int {
        _ = self;
        const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse return 0;
        return column.private().width;
    }

    pub fn restorePaneWidth(self: *Self, surface: *Surface, width: c_int) !void {
        const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse
            return error.TargetNotFound;
        column.private().width = if (width == 0) 0 else std.math.clamp(width, 320, 4096);
        self.updateColumnSizes();
    }

    fn flushPendingRebuild(self: *Self) void {
        const source = self.private().rebuild_source orelse return;
        if (glib.Source.remove(source) == 0) {
            log.warn("unable to flush pending split tree rebuild", .{});
        }
        self.private().rebuild_source = null;
        _ = onRebuild(self);
    }

    pub fn automationFocus(self: *Self, surface: *Surface) !void {
        const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse
            return error.TargetNotFound;
        column.setVisibleSurface(surface);
        self.activateColumnSurface(column, surface);
        _ = surface.as(gtk.Widget).grabFocus();
    }

    pub fn resize(
        self: *Self,
        direction: Surface.Tree.Split.Direction,
        amount: u16,
    ) Allocator.Error!bool {
        if (amount == 0 or self.getIsZoomed()) return false;
        const surface = self.getActiveSurface() orelse return false;
        const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse return false;
        const delta: c_int = switch (direction) {
            .left => -@as(c_int, amount),
            .right => @intCast(amount),
            .up, .down => return false,
        };
        const priv = column.private();
        const current_width = if (priv.width == 0) column.as(gtk.Widget).getAllocatedWidth() else priv.width;
        const width = std.math.clamp(current_width + delta, 320, 4096);
        if (width == current_width) return false;
        priv.width = width;
        column.as(gtk.Widget).setSizeRequest(width, -1);
        self.revealActive();
        return true;
    }

    /// Move focus from the currently focused surface to the given
    /// direction. Returns true if focus switched to a new surface.
    pub fn goto(self: *Self, to: Surface.Tree.Goto) bool {
        const tree = self.getTree() orelse return false;
        const active = self.getActiveSurfaceHandle() orelse return false;
        // The canvas is the tree's left-to-right leaf order, regardless of
        // the original split orientation. Spatial up/down have no neighbor.
        const column_to: Surface.Tree.Goto = switch (to) {
            .spatial => |direction| switch (direction) {
                .left => .previous,
                .right => .next,
                .up, .down => return false,
            },
            else => to,
        };
        const target = if (tree.goto(
            Application.default().allocator(),
            active,
            column_to,
        )) |handle_|
            handle_ orelse return false
        else |err| switch (err) {
            // Nothing we can do in this scenario. This is highly unlikely
            // since split trees don't use that much memory. The application
            // is probably about to crash in other ways.
            error.OutOfMemory => return false,
        };

        // If we aren't changing targets then we did nothing.
        if (active == target) return false;

        // Get the surface at the target location and grab focus.
        const surface = tree.nodes[target.idx()].leaf;
        surface.grabFocus();

        // We also need to setup our last_focused to this because if we
        // trigger a tree change like below, the grab focus above never
        // actually triggers in time to set this and this ensures we
        // grab focus to the right thing.
        const old_last_focused = self.private().last_focused.get();
        defer if (old_last_focused) |v| v.unref(); // unref strong ref from get
        self.private().last_focused.set(surface);
        errdefer self.private().last_focused.set(old_last_focused);

        if (tree.zoomed != null) {
            const app = Application.default();
            const config_obj = app.getConfig();
            defer config_obj.unref();
            const config = config_obj.get();

            if (!config.@"split-preserve-zoom".navigation) {
                tree.zoomed = null;
            } else {
                tree.zoom(target);
            }

            // When the zoom state changes our tree state changes and
            // we need to send the proper notifications to trigger
            // relayout.
            const object = self.as(gobject.Object);
            object.notifyByPspec(properties.tree.impl.param_spec);
            object.notifyByPspec(properties.@"is-zoomed".impl.param_spec);
        }
        self.revealActive();

        return true;
    }

    fn disconnectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
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

    fn connectSurfaceHandlers(self: *Self) void {
        const tree = self.getTree() orelse return;
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = Surface.signals.@"close-request".connect(
                surface,
                *Self,
                surfaceCloseRequest,
                self,
                .{},
            );
            _ = gobject.Object.signals.notify.connect(
                surface,
                *Self,
                propSurfaceFocused,
                self,
                .{ .detail = "focused" },
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Returns true if this split tree needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getTree() orelse return false;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.core()) |core| {
                if (core.needsConfirmQuit()) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tree = self.getTree() orelse return null;
        const handle = self.getActiveSurfaceHandle() orelse return null;
        return tree.nodes[handle.idx()].leaf;
    }

    fn getActiveSurfaceHandle(self: *Self) ?Surface.Tree.Node.Handle {
        const tree = self.getTree() orelse return null;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.getFocused()) return entry.handle;
        }

        // If none are currently focused, the most previously focused
        // surface (if it exists) is our active surface. This lets things
        // like apprt actions and bell ringing continue to work in the
        // background.
        if (self.private().last_focused.get()) |v| {
            defer v.unref();

            // We need to find the handle of the last focused surface.
            it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == v) return entry.handle;
            }
        }

        return null;
    }

    /// Returns the last focused surface in the tree.
    pub fn getLastFocusedSurface(self: *Self) ?*Surface {
        const surface = self.private().last_focused.get() orelse return null;
        // We unref because get() refs the surface. We don't use the weakref
        // in a multi-threaded context so this is safe.
        surface.unref();
        return surface;
    }

    pub fn getHasSurfaces(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return !tree.isEmpty();
    }

    pub fn getIsZoomed(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        return tree.zoomed != null;
    }

    /// Get the tree data model that we're showing in this widget. This
    /// does not clone the tree.
    pub fn getTree(self: *Self) ?*Surface.Tree {
        return self.private().tree;
    }

    /// Set the tree data model that we're showing in this widget. This
    /// will clone the given tree.
    pub fn setTree(self: *Self, tree_: ?*const Surface.Tree) void {
        const priv = self.private();

        // We always normalize our tree parameter so that empty trees
        // become null so that we don't have to deal with callers being
        // confused about that.
        const tree: ?*const Surface.Tree = tree: {
            const tree = tree_ orelse break :tree null;
            if (tree.isEmpty()) break :tree null;
            break :tree tree;
        };

        // Emit the signal so that handlers can witness both the before and
        // after values of the tree.
        signals.changed.impl.emit(
            self,
            null,
            .{ priv.tree, tree },
            null,
        );

        if (priv.tree) |old_tree| {
            self.disconnectSurfaceHandlers();
            ext.boxedFree(Surface.Tree, old_tree);
            priv.tree = null;
        }

        if (tree) |new_tree| {
            assert(priv.tree == null);
            assert(!new_tree.isEmpty());
            priv.tree = ext.boxedCopy(Surface.Tree, new_tree);
            self.connectSurfaceHandlers();
        }

        self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
        @import("../automation.zig").sessionChanged();
    }

    fn getTreeValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().tree,
        );
    }

    fn setTreeValue(self: *Self, value: *const gobject.Value) void {
        self.setTree(gobject.ext.Value.get(
            value,
            ?*Surface.Tree,
        ));
    }

    pub fn getIsSplit(self: *Self) bool {
        const tree: *const Surface.Tree = self.private().tree orelse &.empty;
        if (tree.isEmpty()) return false;

        const root_handle: Surface.Tree.Node.Handle = .root;
        const root = tree.nodes[root_handle.idx()];
        return switch (root) {
            .leaf => false,
            .split => true,
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.disconnectSurfaceHandlers();
        if (priv.reveal_tick != 0) {
            self.as(gtk.Widget).removeTickCallback(priv.reveal_tick);
            priv.reveal_tick = 0;
        }
        priv.last_focused.set(null);
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }

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
        if (priv.tree) |tree| {
            ext.boxedFree(Surface.Tree, tree);
            priv.tree = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    pub fn actionNewSplit(
        _: *gio.SimpleAction,
        args_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const args = args_ orelse {
            log.warn("split-tree.new-split called without a parameter", .{});
            return;
        };

        var dir: ?[*:0]const u8 = null;
        args.get("&s", &dir);

        const direction = std.meta.stringToEnum(
            Surface.Tree.Split.Direction,
            std.mem.span(dir) orelse return,
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid split direction for split-tree.new-split: {s}", .{dir.?});
            return;
        };

        self.newSplit(
            direction,
            self.getActiveSurface(),
            .none,
        ) catch |err| {
            log.warn("new split failed error={}", .{err});
        };
    }

    pub fn actionEqualize(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = parameter_;
        var child = self.private().columns.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            const column = gobject.ext.cast(TerminalColumn, widget) orelse continue;
            column.private().width = 0;
        }

        self.updateColumnSizes();
        self.revealActive();
    }

    pub fn actionZoom(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tree = self.getTree() orelse return;
        if (tree.zoomed != null) {
            tree.zoomed = null;
        } else {
            const active = self.getActiveSurfaceHandle() orelse return;
            if (tree.zoomed == active) return;
            tree.zoom(active);
        }

        self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
    }

    /// Explicitly authorized automation close; reuse the native tree transition.
    pub fn automationClose(self: *Self, surface: *Surface) !void {
        if (ext.getAncestor(TerminalColumn, surface.as(gtk.Widget))) |column| {
            if (column.removeSurface(surface)) return;
        }
        const tree = self.getTree() orelse return error.TargetNotFound;
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) {
                self.private().pending_close = entry.handle;
                closeConfirmationClose(null, self);
                return;
            }
        }
        return error.TargetNotFound;
    }

    pub fn automationClosePane(self: *Self, surface: *Surface) !void {
        const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse
            return error.TargetNotFound;
        while (column.private().surfaces.items.len > 1) {
            const first = column.private().surfaces.items[0].surface;
            const target = if (first == surface)
                column.private().surfaces.items[1].surface
            else
                first;
            if (!column.removeSurface(target)) return error.CloseFailed;
        }
        try self.automationClose(surface);
    }

    /// Move one live surface without recreating its PTY. A tab is detached
    /// from its pane before layout reconciliation so sibling tabs remain in
    /// the source pane rather than following the moved widget.
    pub fn automationMoveTo(
        self: *Self,
        surface: *Surface,
        destination: *Self,
        direction: Surface.Tree.Split.Direction,
        relative_to: ?*Surface,
    ) !void {
        const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse
            return error.TargetNotFound;
        const had_siblings = column.private().surfaces.items.len > 1;
        _ = surface.ref();
        defer surface.unref();
        if (!column.detachSurface(surface)) return error.TargetNotFound;

        const source_tree = self.getTree() orelse return error.TargetNotFound;
        const source_handle: ?Surface.Tree.Node.Handle = if (had_siblings)
            null
        else source: {
            var it = source_tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == surface) break :source entry.handle;
            }
            return error.TargetNotFound;
        };

        const alloc = Application.default().allocator();
        var single = try Surface.Tree.init(alloc, surface);
        defer single.deinit();

        if (self == destination) {
            if (source_handle) |handle| {
                var source_after = try source_tree.remove(alloc, handle);
                defer source_after.deinit();
                try destination.automationInsertSurface(&source_after, &single, surface, direction, relative_to);
            } else {
                try destination.automationInsertSurface(source_tree, &single, surface, direction, relative_to);
            }
            return;
        }

        if (destination.getTree()) |destination_tree| {
            try destination.automationInsertSurface(destination_tree, &single, surface, direction, relative_to);
        } else {
            destination.private().last_focused.set(surface);
            destination.setTree(&single);
        }

        if (source_handle) |handle| {
            var source_after = try source_tree.remove(alloc, handle);
            defer source_after.deinit();
            self.setTree(&source_after);
        }
    }

    fn automationInsertSurface(
        self: *Self,
        tree: *const Surface.Tree,
        single: *const Surface.Tree,
        surface: *Surface,
        direction: Surface.Tree.Split.Direction,
        relative_to: ?*Surface,
    ) !void {
        if (tree.isEmpty()) {
            self.private().last_focused.set(surface);
            self.setTree(single);
            return;
        }
        const target = target: {
            if (relative_to) |relative| {
                const visible = self.paneActiveSurface(relative) orelse relative;
                var it = tree.iterator();
                while (it.next()) |entry| {
                    if (entry.view == visible) break :target entry.handle;
                }
            }
            var it = tree.iterator();
            break :target (it.next() orelse return error.TargetNotFound).handle;
        };
        var result = try tree.split(
            Application.default().allocator(),
            target,
            direction,
            0.5,
            single,
        );
        defer result.deinit();
        self.private().last_focused.set(surface);
        self.setTree(&result);
    }

    fn surfaceCloseRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const core = surface.core() orelse return;

        // Reset our pending close state
        const priv = self.private();
        priv.pending_close = null;

        // Find the surface in the tree to verify this is valid and
        // set our pending close handle.
        priv.pending_close = handle: {
            const tree = self.getTree() orelse return;
            var it = tree.iterator();
            while (it.next()) |entry| {
                if (entry.view == surface) {
                    break :handle entry.handle;
                }
            }

            return;
        };

        // If we don't need to confirm then just close immediately.
        if (!core.needsConfirmQuit()) {
            closeConfirmationClose(
                null,
                self,
            );
            return;
        }

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.surface);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Self,
            closeConfirmationClose,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }

    fn closeConfirmationClose(
        _: ?*CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        // Get the handle we're closing
        const priv = self.private();
        const handle = priv.pending_close orelse return;
        if (self.getTree()) |tree| {
            if (@import("../automation.zig").closeRemoteTerminal(tree.nodes[handle.idx()].leaf)) return;
        }
        priv.pending_close = null;

        // Figure out our next focus target. The next focus target is
        // always the "previous" surface unless we're the leftmost then
        // its the next.
        const old_tree = self.getTree() orelse return;
        const active = self.getActiveSurface();
        const next_focus: ?*Surface = next_focus: {
            // Closing a background column must not steal terminal focus.
            if (active) |surface| {
                if (surface != old_tree.nodes[handle.idx()].leaf) break :next_focus surface;
            }
            const alloc = Application.default().allocator();
            const next_handle: Surface.Tree.Node.Handle =
                (old_tree.goto(alloc, handle, .previous) catch null) orelse
                (old_tree.goto(alloc, handle, .next) catch null) orelse
                break :next_focus null;
            if (next_handle == handle) break :next_focus null;

            // Note: we don't need to ref this or anything because its
            // guaranteed to remain in the new tree since its not part
            // of the handle we're removing.
            break :next_focus old_tree.nodes[next_handle.idx()].leaf;
        };

        // Remove it from the tree.
        var new_tree = old_tree.remove(
            Application.default().allocator(),
            handle,
        ) catch |err| {
            log.warn("unable to remove surface from tree: {}", .{err});
            return;
        };
        defer new_tree.deinit();
        self.setTree(&new_tree);

        // Grab focus. We have to set this on the "last focused" because our
        // focus will be set when the tree is redrawn.
        if (next_focus) |v| priv.last_focused.set(v);
    }

    fn propSurfaceFocused(
        surface: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We never CLEAR our last_focused because the property is specifically
        // the last focused surface. We let the weakref clear itself when
        // the surface is destroyed.
        if (!surface.getFocused()) return;
        const priv = self.private();
        const previous = priv.last_focused.get();
        defer if (previous) |v| v.unref();
        priv.last_focused.set(surface);
        self.updateActiveColumn();
        // Refocusing the same workspace preserves a deliberately scrolled
        // canvas; changing the active terminal always brings it into view.
        if (previous != surface) self.revealActive();

        // Our active surface probably changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
        @import("../automation.zig").sessionChanged();
    }

    fn propTree(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();

        // No matter what we notify
        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.@"has-surfaces".impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"is-zoomed".impl.param_spec);

        // If we were planning a rebuild, always remove that so we can
        // start from a clean slate.
        if (priv.rebuild_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove rebuild source", .{});
            }
            priv.rebuild_source = null;
        }

        // If we transitioned to an empty tree, clear immediately instead of
        // waiting for an idle callback. Delaying teardown can keep the last
        // surface alive during shutdown if the main loop exits first.
        if (priv.tree == null) {
            self.clearColumns();
            return;
        }

        // Build on an idle callback so rapid tree changes are debounced.
        // We keep the existing tree attached until the rebuild runs,
        // which avoids transient empty frames.
        assert(priv.rebuild_source == null);
        priv.rebuild_source = glib.idleAdd(
            onRebuild,
            self,
        );
    }

    fn onRebuild(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always mark our rebuild source as null since we're done.
        const priv = self.private();
        priv.rebuild_source = null;

        // Reconcile columns in place: surviving terminals never leave their
        // parent, so adding, closing, and zooming cannot recreate their PTYs.
        const tree: *const Surface.Tree = priv.tree orelse &.empty;
        if (tree.isEmpty()) {
            self.clearColumns();
        } else {
            var existing = priv.columns.as(gtk.Widget).getFirstChild();
            while (existing) |widget| : (existing = widget.getNextSibling()) {
                if (gobject.ext.cast(TerminalColumn, widget)) |column|
                    column.private().retained = false;
            }
            var previous: ?*gtk.Widget = null;
            self.syncColumns(tree, .root, &previous);
            var child = priv.columns.as(gtk.Widget).getFirstChild();
            while (child) |widget| {
                child = widget.getNextSibling();
                const column = gobject.ext.cast(TerminalColumn, widget) orelse continue;
                if (!column.private().retained) {
                    priv.columns.remove(widget);
                }
            }

            self.updateColumnSizes();
        }

        // Replacing our tree widget hierarchy can reset focus state.
        // If we have a last-focused surface, restore focus to it.
        if (priv.last_focused.get()) |v| {
            defer v.unref();
            v.grabFocus();
        }
        self.updateActiveColumn();
        self.revealActive();

        // Our split status may have changed
        self.as(gobject.Object).notifyByPspec(properties.@"is-split".impl.param_spec);

        // Our active surface may have changed
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);

        return 0;
    }

    fn clearColumns(self: *Self) void {
        const columns = self.private().columns;
        var child = columns.as(gtk.Widget).getFirstChild();
        while (child) |widget| {
            child = widget.getNextSibling();
            if (gobject.ext.cast(TerminalColumn, widget) != null) columns.remove(widget);
        }
    }


    fn syncColumns(
        self: *Self,
        tree: *const Surface.Tree,
        handle: Surface.Tree.Node.Handle,
        previous: *?*gtk.Widget,
    ) void {
        switch (tree.nodes[handle.idx()]) {
            .split => |split| {
                self.syncColumns(tree, split.left, previous);
                self.syncColumns(tree, split.right, previous);
            },
            .leaf => |surface| {
                const columns = self.private().columns;
                const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse
                    TerminalColumn.new(surface);
                column.private().retained = true;
                column.setVisibleSurface(surface);
                const widget = column.as(gtk.Widget);
                if (widget.getParent()) |parent| {
                    if (parent != columns.as(gtk.Widget)) {
                        // Only an explicit transfer between workspaces needs
                        // reparenting. Ordinary reconciliation never does.
                        _ = column.ref();
                        defer column.unref();
                        gobject.ext.cast(gtk.Box, parent).?.remove(widget);
                        columns.insertChildAfter(widget, previous.*);
                    } else if (widget.getPrevSibling() != previous.*) {
                        columns.reorderChildAfter(widget, previous.*);
                    }
                } else {
                    columns.insertChildAfter(widget, previous.*);
                }
                previous.* = widget;
            },
        }
    }

    fn updateColumnSizes(self: *Self) void {
        const priv = self.private();
        const tree = priv.tree orelse return;
        const zoomed: ?*Surface = if (tree.zoomed) |handle| tree.nodes[handle.idx()].leaf else null;
        var padding: gtk.Border = undefined;
        priv.columns.as(gtk.Widget).getStyleContext().getPadding(&padding);
        const page_width: c_int = @intFromFloat(priv.canvas.getHadjustment().getPageSize());
        var page_height: c_int = @intFromFloat(priv.canvas.getVadjustment().getPageSize());
        if (page_height <= 0) page_height = priv.canvas.as(gtk.Widget).getHeight();
        const default_width = @max(1, page_width - padding.f_left - padding.f_right);
        const default_height = @max(1, page_height - padding.f_top - padding.f_bottom);
        var child = priv.columns.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            const column = gobject.ext.cast(TerminalColumn, widget) orelse {
                widget.setVisible(@intFromBool(zoomed == null));
                widget.setHexpand(@intFromBool(zoomed != null));
                widget.setSizeRequest(if (zoomed != null) -1 else default_width, default_height);
                continue;
            };
            const column_priv = column.private();
            const visible = zoomed == null or zoomed == column.activeSurface();

            widget.setVisible(@intFromBool(visible));
            widget.setHexpand(@intFromBool(zoomed != null));
            widget.setSizeRequest(
                if (zoomed != null) -1 else if (column_priv.width == 0) default_width else column_priv.width,
                -1,
            );
        }

    }

    fn updateActiveColumn(self: *Self) void {
        const active = self.getActiveSurface();
        var child = self.private().columns.as(gtk.Widget).getFirstChild();
        while (child) |widget| : (child = widget.getNextSibling()) {
            const column = gobject.ext.cast(TerminalColumn, widget) orelse continue;
            if (column.activeSurface() == active) {
                widget.addCssClass("active");
            } else {
                widget.removeCssClass("active");
            }
        }

    }

    fn activateColumnSurface(self: *Self, column: *TerminalColumn, surface: *Surface) void {
        const tree = self.private().tree orelse return;
        var handle: ?Surface.Tree.Node.Handle = null;
        for (tree.nodes, 0..) |node, index| switch (node) {
            .leaf => |current| {
                if (ext.getAncestor(TerminalColumn, current.as(gtk.Widget)) == column) {
                    handle = @enumFromInt(index);
                    break;
                }
            },
            .split => {},
        };
        const target = handle orelse return;
        if (tree.nodes[target.idx()].leaf == surface) return;

        var next = tree.replace(
            Application.default().allocator(),
            target,
            surface,
        ) catch |err| {
            log.warn("unable to activate pane surface: {}", .{err});
            return;
        };
        defer next.deinit();
        self.setTree(&next);
        _ = surface.as(gtk.Widget).grabFocus();
    }

    fn revealActive(self: *Self) void {
        const priv = self.private();
        if (priv.reveal_tick != 0) return;
        priv.reveal_ready = false;
        priv.reveal_tick = self.as(gtk.Widget).addTickCallback(revealTick, self, null);
    }

    fn revealTick(_: *gtk.Widget, _: *gdk.FrameClock, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const priv = self.private();
        // Tick runs before allocation. Let the first frame lay out any new
        // columns before using their coordinates in the second frame.
        if (!priv.reveal_ready) {
            priv.reveal_ready = true;
            return 1;
        }
        priv.reveal_tick = 0;
        const surface = self.getActiveSurface() orelse return 0;
        const column = ext.getAncestor(TerminalColumn, surface.as(gtk.Widget)) orelse return 0;
        var allocation: gtk.Allocation = undefined;
        column.as(gtk.Widget).getAllocation(&allocation);
        const adjustment = priv.canvas.getHadjustment();
        var padding: gtk.Border = undefined;
        priv.columns.as(gtk.Widget).getStyleContext().getPadding(&padding);
        const start: f64 = @floatFromInt(allocation.f_x - padding.f_left);
        const end: f64 = @floatFromInt(allocation.f_x + allocation.f_width + padding.f_right);
        const page = adjustment.getPageSize();
        const value = adjustment.getValue();
        const target = if (start < value or end - start > page)
            start
        else if (end > value + page)
            end - page
        else
            value;
        adjustment.setValue(std.math.clamp(
            target,
            adjustment.getLower(),
            @max(adjustment.getLower(), adjustment.getUpper() - page),
        ));
        return 0;
    }

    fn canvasChanged(adjustment: *gtk.Adjustment, self: *Self) callconv(.c) void {
        const priv = self.private();
        const page_size = adjustment.getPageSize();
        if (priv.canvas_page_size == page_size) return;
        priv.canvas_page_size = page_size;
        self.updateColumnSizes();
        self.revealActive();
    }

    fn canvasScroll(
        controller: *gtk.EventControllerScroll,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) c_int {
        // Capture horizontal gestures before Surface's legacy tab-swipe
        // controller sees them. Vertical wheel/trackpad input remains terminal
        // input, including scrollback and application mouse reporting.
        if (x == 0 or @abs(y) > @abs(x)) return 0;
        const adjustment = self.private().canvas.getHadjustment();
        const delta = x * @as(f64, if (controller.getUnit() == .wheel) 48 else 1);
        adjustment.setValue(adjustment.getValue() + delta);
        return 1;
    }

    //---------------------------------------------------------------
    // Class

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
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-tree",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.@"has-surfaces".impl,
                properties.@"is-zoomed".impl,
                properties.tree.impl,
                properties.@"is-split".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("canvas", .{});
            class.bindTemplateChildPrivate("columns", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_tree", &propTree);
            class.bindTemplateCallback("canvas_scroll", &canvasScroll);
            class.bindTemplateCallback("canvas_changed", &canvasChanged);

            // Signals
            signals.changed.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// Browser (and later guests) in the niri strip. CSS rounds the border;
/// WebKit paints a square native surface, so snapshot clips like TerminalColumn.

const GuestColumn = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ColumnGuestColumn",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        self.as(gtk.Orientable).setOrientation(.vertical);
        self.as(gtk.Widget).addCssClass("column-card");
        self.as(gtk.Widget).addCssClass("guest-column");
        self.as(gtk.Widget).setVexpand(1);
        self.as(gtk.Widget).setHalign(.fill);
        self.as(gtk.Widget).setValign(.fill);
        self.as(gtk.Widget).setOverflow(.hidden);
        return self;
    }

    fn snapshot(self: *Self, frame: *gtk.Snapshot) callconv(.c) void {
        var clip: gsk.RoundedRect = undefined;
        _ = clip.initFromRect(&.{
            .f_origin = .{ .f_x = 0, .f_y = 0 },
            .f_size = .{
                .f_width = @floatFromInt(self.as(gtk.Widget).getWidth()),
                .f_height = @floatFromInt(self.as(gtk.Widget).getHeight()),
            },
        }, 11);
        frame.pushRoundedClip(&clip);
        gtk.Widget.virtual_methods.snapshot.call(Class.parent, self.as(Parent), frame);
        frame.pop();
    }

    const C = Common(Self, null);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
        }

        pub const as = C.Class.as;
    };
};


/// A persistent pane. The split tree contains its active Surface while this
/// widget owns every surface tab, so selecting a tab preserves the PTY and the
/// pane's canvas width.
const TerminalColumn = extern struct {

    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "ColumnTerminalColumn",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Entry = struct {
        surface: *Surface,
        wrapper: *SurfaceScrolledWindow,
    };

    const Private = struct {
        stack: *gtk.Stack,
        switcher: *gtk.StackSwitcher,
        surfaces: std.ArrayListUnmanaged(Entry) = .{},
        /// Zero follows the viewport; a positive value is an explicit resize.
        width: c_int = 0,
        retained: bool = false,
        pub var offset: c_int = 0;
    };

    fn new(surface: *Surface) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.width = 0;
        priv.surfaces = .{};
        self.as(gtk.Orientable).setOrientation(.vertical);
        self.as(gtk.Widget).addCssClass("column-card");
        self.as(gtk.Widget).setVexpand(1);

        priv.switcher = gtk.StackSwitcher.new();
        priv.switcher.as(gtk.Widget).setHalign(.center);
        priv.switcher.as(gtk.Widget).setVisible(0);
        self.as(gtk.Box).append(priv.switcher.as(gtk.Widget));

        priv.stack = gtk.Stack.new();
        priv.stack.as(gtk.Widget).setHexpand(1);
        priv.stack.as(gtk.Widget).setVexpand(1);
        priv.switcher.setStack(priv.stack);
        self.as(gtk.Box).append(priv.stack.as(gtk.Widget));
        _ = self.addSurface(surface);
        _ = gobject.Object.signals.notify.connect(
            priv.stack.as(gobject.Object),
            *Self,
            visibleChildChanged,
            self,
            .{ .detail = "visible-child" },
        );
        return self;
    }

    fn addSurface(self: *Self, surface: *Surface) bool {
        const priv = self.private();
        for (priv.surfaces.items) |entry| {
            if (entry.surface == surface) {
                priv.stack.setVisibleChild(entry.wrapper.as(gtk.Widget));
                return true;
            }
        }
        const wrapper = gobject.ext.newInstance(SurfaceScrolledWindow, .{ .surface = surface });
        wrapper.as(gtk.Widget).setHexpand(1);
        wrapper.as(gtk.Widget).setVexpand(1);
        priv.surfaces.append(
            Application.default().allocator(),
            .{ .surface = surface, .wrapper = wrapper },
        ) catch |err| {
            log.warn("unable to add pane surface: {}", .{err});
            wrapper.as(gtk.Widget).unparent();
            return false;
        };
        _ = priv.stack.addTitled(wrapper.as(gtk.Widget), null, "Terminal");
        priv.stack.setVisibleChild(wrapper.as(gtk.Widget));
        priv.switcher.as(gtk.Widget).setVisible(@intFromBool(priv.surfaces.items.len > 1));
        return true;
    }

    fn removeSurface(self: *Self, surface: *Surface) bool {
        if (self.private().surfaces.items.len <= 1) return false;
        return self.detachSurface(surface);
    }

    fn detachSurface(self: *Self, surface: *Surface) bool {
        const priv = self.private();
        for (priv.surfaces.items, 0..) |entry, index| {
            if (entry.surface != surface) continue;
            const was_active = self.activeSurface() == surface;
            if (was_active and priv.surfaces.items.len > 1) {
                const next_index = if (index + 1 < priv.surfaces.items.len) index + 1 else index - 1;
                priv.stack.setVisibleChild(priv.surfaces.items[next_index].wrapper.as(gtk.Widget));
            }
            priv.stack.remove(entry.wrapper.as(gtk.Widget));
            _ = priv.surfaces.orderedRemove(index);
            priv.switcher.as(gtk.Widget).setVisible(@intFromBool(priv.surfaces.items.len > 1));
            return true;
        }
        return false;
    }

    fn setVisibleSurface(self: *Self, surface: *Surface) void {
        for (self.private().surfaces.items) |entry| {
            if (entry.surface == surface) {
                self.private().stack.setVisibleChild(entry.wrapper.as(gtk.Widget));
                return;
            }
        }
    }

    fn activeSurface(self: *Self) ?*Surface {
        const visible = self.private().stack.getVisibleChild() orelse return null;
        for (self.private().surfaces.items) |entry| {
            if (entry.wrapper.as(gtk.Widget) == visible) return entry.surface;
        }
        return null;
    }

    fn visibleChildChanged(
        _: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const surface = self.activeSurface() orelse return;
        const tree = ext.getAncestor(SplitTree, self.as(gtk.Widget)) orelse return;
        tree.activateColumnSurface(self, surface);
    }

    fn snapshot(self: *Self, frame: *gtk.Snapshot) callconv(.c) void {
        // GTK CSS rounds the border, not the GL terminal child. Clip its
        // content to the inner radius (12px border radius minus 1px border).
        var clip: gsk.RoundedRect = undefined;
        _ = clip.initFromRect(&.{
            .f_origin = .{ .f_x = 0, .f_y = 0 },
            .f_size = .{
                .f_width = @floatFromInt(self.as(gtk.Widget).getWidth()),
                .f_height = @floatFromInt(self.as(gtk.Widget).getHeight()),
            },
        }, 11);
        frame.pushRoundedClip(&clip);
        gtk.Widget.virtual_methods.snapshot.call(Class.parent, self.as(Parent), frame);
        frame.pop();
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.private().surfaces.deinit(Application.default().allocator());
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
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
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
