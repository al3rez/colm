const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const appearance = @import("../../../config/appearance.zig");
const Application = @import("application.zig").Application;
const alloc = std.heap.c_allocator;
const page_size = 12;

/// The caller parents the returned floating widget in its menu or dialog.
pub fn createSchemeSwitcher(app: *Application) *gtk.Widget {
    const root = gtk.Box.new(.vertical, 6);
    root.as(gtk.Widget).addCssClass("appearance-scheme-switcher");
    const state = alloc.create(SchemeSwitcher) catch {
        root.append(gtk.Label.new("Not enough memory to show appearance controls.").as(gtk.Widget));
        return root.as(gtk.Widget);
    };
    const choices = gtk.Box.new(.horizontal, 12);
    choices.setHomogeneous(1);
    choices.as(gtk.Widget).setHalign(.center);
    root.append(choices.as(gtk.Widget));
    const message = errorLabel();
    message.setMaxWidthChars(28);
    root.append(message.as(gtk.Widget));
    state.* = .{ .app = app.ref(), .message = message };
    root.as(gobject.Object).setDataFull("colm-scheme-switcher", state, SchemeSwitcher.destroy);

    const names = [_][:0]const u8{ "System", "Light", "Dark" };
    const classes = [_][:0]const u8{ "appearance-system", "appearance-light", "appearance-dark" };
    for (names, classes, 0..) |name, class, i| {
        const column = gtk.Box.new(.vertical, 4);
        const button = gtk.ToggleButton.new();
        button.as(gtk.Widget).addCssClass("appearance-scheme");
        button.as(gtk.Widget).addCssClass(class);
        button.as(gtk.Widget).setHalign(.center);
        button.as(gtk.Widget).setTooltipText(name);
        const check = gtk.Image.newFromIconName("object-select-symbolic");
        button.as(gtk.Button).setChild(check.as(gtk.Widget));
        // Set an explicit accessible name; the visible caption is a sibling.
        button.as(gtk.Accessible).updateProperty(.label, name.ptr, @as(c_int, -1));
        column.append(button.as(gtk.Widget));
        const caption = gtk.Label.new(name);
        caption.as(gtk.Widget).addCssClass("caption");
        column.append(caption.as(gtk.Widget));
        choices.append(column.as(gtk.Widget));
        state.choices[i] = .{ .owner = state, .scheme = @enumFromInt(i), .button = button, .check = check };
        _ = gtk.Button.signals.clicked.connect(button.as(gtk.Button), *SchemeChoice, SchemeChoice.clicked, &state.choices[i], .{});
    }
    state.notify = gobject.Object.signals.notify.connect(app.as(gobject.Object), *SchemeSwitcher, SchemeSwitcher.configChanged, state, .{ .detail = "config" });
    state.sync();
    return root.as(gtk.Widget);
}

const SchemeChoice = struct {
    owner: *SchemeSwitcher,
    scheme: appearance.Scheme,
    button: *gtk.ToggleButton,
    check: *gtk.Image,

    fn clicked(_: *gtk.Button, self: *SchemeChoice) callconv(.c) void {
        var prefs = self.owner.app.getAppearance();
        prefs.scheme = self.scheme;
        self.owner.message.as(gtk.Widget).setVisible(0);
        self.owner.app.setAppearance(prefs) catch |err| showError(self.owner.message, err);
        self.owner.sync();
    }
};

const SchemeSwitcher = struct {
    app: *Application,
    message: *gtk.Label,
    choices: [3]SchemeChoice = undefined,
    notify: c_ulong = 0,

    fn sync(self: *SchemeSwitcher) void {
        const scheme = self.app.getAppearance().scheme;
        for (&self.choices) |*choice| {
            const active = choice.scheme == scheme;
            choice.button.setActive(@intFromBool(active));
            choice.check.as(gtk.Widget).setOpacity(if (active) 1 else 0);
        }
    }

    fn configChanged(_: *gobject.Object, _: *gobject.ParamSpec, self: *SchemeSwitcher) callconv(.c) void {
        self.sync();
    }

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *SchemeSwitcher = @ptrCast(@alignCast(data.?));
        if (self.notify != 0) gobject.signalHandlerDisconnect(self.app.as(gobject.Object), self.notify);
        self.app.unref();
        alloc.destroy(self);
    }
};

/// Present a native, parent-owned dialog. No retained parent-window pointer is needed.
pub fn present(parent: *gtk.Window) void {
    const gtk_app = parent.getApplication() orelse return;
    const app = gobject.ext.cast(Application, gtk_app) orelse return;
    const state = alloc.create(AppearanceDialog) catch {
        const alert = adw.AlertDialog.new("Could not open Appearance", "Not enough memory to create the appearance dialog.");
        alert.addResponse("close", "_Close");
        alert.as(adw.Dialog).present(parent.as(gtk.Widget));
        return;
    };
    const dialog = adw.Dialog.new();
    dialog.setTitle("Settings");
    dialog.setContentWidth(760);
    dialog.setContentHeight(760);
    dialog.as(gtk.Widget).addCssClass("appearance-dialog");

    const toolbar = adw.ToolbarView.new();
    toolbar.addTopBar(adw.HeaderBar.new().as(gtk.Widget));
    const body = gtk.Box.new(.vertical, 18);
    body.as(gtk.Widget).setMarginTop(12);
    body.as(gtk.Widget).setMarginBottom(20);
    body.as(gtk.Widget).setMarginStart(24);
    body.as(gtk.Widget).setMarginEnd(24);
    const scroll = gtk.ScrolledWindow.new();
    scroll.setPolicy(.never, .automatic);
    scroll.setChild(body.as(gtk.Widget));
    scroll.as(gtk.Widget).setVexpand(1);
    toolbar.setContent(scroll.as(gtk.Widget));
    dialog.setChild(toolbar.as(gtk.Widget));

    const window_group = adw.PreferencesGroup.new();
    window_group.setTitle("Window appearance");
    const inherit = adw.SwitchRow.new();
    inherit.as(adw.PreferencesRow).setTitle("Match window colours to terminal");
    inherit.as(adw.ActionRow).setSubtitle("Tint the sidebar and window using the terminal palette.");
    window_group.add(inherit.as(gtk.Widget));

    const theme_group = adw.PreferencesGroup.new();
    theme_group.setTitle("Palette");
    const reset = gtk.Button.newFromIconName("edit-undo-symbolic");
    reset.as(gtk.Widget).addCssClass("flat");
    reset.as(gtk.Widget).setTooltipText("Use configuration theme");
    reset.as(gtk.Accessible).updateProperty(.label, @as([*:0]const u8, "Use configuration theme"), @as(c_int, -1));
    theme_group.setHeaderSuffix(reset.as(gtk.Widget));
    const selected = gtk.Label.new(null);
    selected.setWrap(1);
    selected.setXalign(0);
    selected.as(gtk.Widget).addCssClass("dim-label");
    selected.as(gtk.Widget).addCssClass("caption");
    theme_group.add(selected.as(gtk.Widget));
    body.append(theme_group.as(gtk.Widget));

    const search = gtk.SearchEntry.new();
    search.setPlaceholderText("Search palettes");
    search.as(gtk.Accessible).updateProperty(.label, @as([*:0]const u8, "Search palettes"), @as(c_int, -1));
    body.append(search.as(gtk.Widget));
    const message = errorLabel();
    body.append(message.as(gtk.Widget));
    const empty = gtk.Label.new(null);
    empty.setWrap(1);
    empty.as(gtk.Widget).addCssClass("dim-label");
    body.append(empty.as(gtk.Widget));
    const gallery = gtk.FlowBox.new();
    gallery.setSelectionMode(.none);
    gallery.setHomogeneous(1);
    gallery.setMinChildrenPerLine(1);
    gallery.setMaxChildrenPerLine(3);
    gallery.setColumnSpacing(9);
    gallery.setRowSpacing(9);
    gallery.as(gtk.Widget).addCssClass("appearance-gallery");
    body.append(gallery.as(gtk.Widget));

    const pager = gtk.Box.new(.horizontal, 12);
    pager.as(gtk.Widget).setHalign(.center);
    const previous = gtk.Button.newFromIconName("go-previous-symbolic");
    previous.as(gtk.Widget).setTooltipText("Previous themes");
    previous.as(gtk.Accessible).updateProperty(.label, @as([*:0]const u8, "Previous themes"), @as(c_int, -1));
    const page_label = gtk.Label.new(null);
    const next = gtk.Button.newFromIconName("go-next-symbolic");
    next.as(gtk.Widget).setTooltipText("Next themes");
    next.as(gtk.Accessible).updateProperty(.label, @as([*:0]const u8, "Next themes"), @as(c_int, -1));
    pager.append(previous.as(gtk.Widget));
    pager.append(page_label.as(gtk.Widget));
    pager.append(next.as(gtk.Widget));
    body.append(pager.as(gtk.Widget));
    body.append(window_group.as(gtk.Widget));

    state.* = .{
        .app = app.ref(),
        .arena = std.heap.ArenaAllocator.init(alloc),
        .inherit = inherit,
        .reset = reset,
        .selected = selected,
        .search = search,
        .message = message,
        .empty = empty,
        .gallery = gallery,
        .previous = previous,
        .next = next,
        .page_label = page_label,
    };
    dialog.as(gobject.Object).setDataFull("colm-appearance-dialog", state, AppearanceDialog.destroy);
    state.themes = appearance.listThemes(state.arena.allocator()) catch |err| blk: {
        var buf: [192]u8 = undefined;
        message.setText(std.fmt.bufPrintZ(&buf, "Could not load terminal themes: {s}.", .{@errorName(err)}) catch unreachable);
        message.as(gtk.Widget).setVisible(1);
        break :blk &.{};
    };
    // Initially show the selected palette, even if it lies on a later page.
    if (app.getAppearance().theme) |name| {
        for (state.themes, 0..) |theme, i| {
            if (std.mem.eql(u8, theme.name, name)) {
                state.page = i / page_size;
                break;
            }
        }
    }
    _ = gobject.Object.signals.notify.connect(inherit.as(gobject.Object), *AppearanceDialog, AppearanceDialog.inheritChanged, state, .{ .detail = "active" });
    _ = gtk.Button.signals.clicked.connect(reset, *AppearanceDialog, AppearanceDialog.resetClicked, state, .{});
    _ = gtk.SearchEntry.signals.search_changed.connect(search, *AppearanceDialog, AppearanceDialog.searchChanged, state, .{});
    _ = gtk.Button.signals.clicked.connect(previous, *AppearanceDialog, AppearanceDialog.previousClicked, state, .{});
    _ = gtk.Button.signals.clicked.connect(next, *AppearanceDialog, AppearanceDialog.nextClicked, state, .{});
    state.notify = gobject.Object.signals.notify.connect(app.as(gobject.Object), *AppearanceDialog, AppearanceDialog.configChanged, state, .{ .detail = "config" });
    state.render();
    dialog.present(parent.as(gtk.Widget));
}

const AppearanceDialog = struct {
    app: *Application,
    arena: std.heap.ArenaAllocator,
    themes: []appearance.Theme = &.{},
    inherit: *adw.SwitchRow,
    reset: *gtk.Button,
    selected: *gtk.Label,
    search: *gtk.SearchEntry,
    message: *gtk.Label,
    empty: *gtk.Label,
    gallery: *gtk.FlowBox,
    previous: *gtk.Button,
    next: *gtk.Button,
    page_label: *gtk.Label,
    notify: c_ulong = 0,
    syncing: bool = false,
    page: usize = 0,
    matches: usize = 0,
    cards: [page_size]Card = undefined,
    card_count: usize = 0,

    fn destroy(data: ?*anyopaque) callconv(.c) void {
        const self: *AppearanceDialog = @ptrCast(@alignCast(data.?));
        if (self.notify != 0) gobject.signalHandlerDisconnect(self.app.as(gobject.Object), self.notify);
        self.app.unref();
        self.arena.deinit();
        alloc.destroy(self);
    }

    fn configChanged(_: *gobject.Object, _: *gobject.ParamSpec, self: *AppearanceDialog) callconv(.c) void {
        self.sync();
    }

    fn sync(self: *AppearanceDialog) void {
        self.syncing = true;
        defer self.syncing = false;
        const prefs = self.app.getAppearance();
        self.inherit.setActive(@intFromBool(prefs.inherit_terminal_colors));
        self.reset.as(gtk.Widget).setSensitive(@intFromBool(prefs.theme != null));
        if (prefs.theme) |name| {
            const text = std.fmt.allocPrintSentinel(alloc, "Selected: {s}", .{name}, 0) catch null;
            if (text) |value| {
                defer alloc.free(value);
                self.selected.setText(value);
            }
        } else self.selected.setText("Using the configuration-defined theme");
        for (self.cards[0..self.card_count]) |*card| {
            const active = if (prefs.theme) |name| std.mem.eql(u8, card.theme.name, name) else false;
            card.button.setActive(@intFromBool(active));
            card.check.as(gtk.Widget).setOpacity(if (active) 1 else 0);
        }
    }

    fn apply(self: *AppearanceDialog, prefs: appearance.Preferences) void {
        self.message.as(gtk.Widget).setVisible(0);
        self.app.setAppearance(prefs) catch |err| showError(self.message, err);
        self.sync();
    }

    fn inheritChanged(_: *gobject.Object, _: *gobject.ParamSpec, self: *AppearanceDialog) callconv(.c) void {
        if (self.syncing) return;
        var prefs = self.app.getAppearance();
        prefs.inherit_terminal_colors = self.inherit.getActive() != 0;
        self.apply(prefs);
    }

    fn resetClicked(_: *gtk.Button, self: *AppearanceDialog) callconv(.c) void {
        var prefs = self.app.getAppearance();
        prefs.theme = null;
        self.apply(prefs);
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *AppearanceDialog) callconv(.c) void {
        self.page = 0;
        self.render();
    }

    fn previousClicked(_: *gtk.Button, self: *AppearanceDialog) callconv(.c) void {
        if (self.page == 0) return;
        self.page -= 1;
        self.render();
    }

    fn nextClicked(_: *gtk.Button, self: *AppearanceDialog) callconv(.c) void {
        if ((self.page + 1) * page_size >= self.matches) return;
        self.page += 1;
        self.render();
    }

    // Keep one page of live cards, regardless of the number of installed themes.
    // Search scans the lightweight palette metadata, not a widget per theme.
    fn render(self: *AppearanceDialog) void {
        while (self.gallery.as(gtk.Widget).getFirstChild()) |child| self.gallery.remove(child);
        self.card_count = 0;
        self.matches = 0;
        const query = std.mem.trim(u8, std.mem.span(self.search.as(gtk.Editable).getText()), " \t\r\n");
        for (self.themes) |*theme| {
            if (!matchesQuery(theme.name, query)) continue;
            const index = self.matches;
            self.matches += 1;
            if (index < self.page * page_size or self.card_count == page_size) continue;
            const card = &self.cards[self.card_count];
            card.* = .{ .owner = self, .theme = theme, .button = undefined, .check = undefined };
            card.build();
            self.gallery.insert(card.button.as(gtk.Widget), -1);
            self.card_count += 1;
        }
        self.empty.setText(if (self.themes.len == 0)
            "No terminal themes were found. Install Ghostty themes in your configuration themes directory, then reopen Appearance."
        else
            "No themes match your search.");
        self.empty.as(gtk.Widget).setVisible(@intFromBool(self.matches == 0));
        self.previous.as(gtk.Widget).setSensitive(@intFromBool(self.page > 0));
        self.next.as(gtk.Widget).setSensitive(@intFromBool((self.page + 1) * page_size < self.matches));
        var buf: [96]u8 = undefined;
        self.page_label.setText(std.fmt.bufPrintZ(&buf, "{d}–{d} of {d} themes", .{
            if (self.matches == 0) @as(usize, 0) else self.page * page_size + 1,
            @min((self.page + 1) * page_size, self.matches),
            self.matches,
        }) catch unreachable);
        self.sync();
    }
};

const Card = struct {
    owner: *AppearanceDialog,
    theme: *const appearance.Theme,
    button: *gtk.ToggleButton,
    check: *gtk.Image,

    fn build(self: *Card) void {
        const button = gtk.ToggleButton.new();
        button.as(gtk.Widget).addCssClass("appearance-theme-card");
        button.as(gtk.Widget).setTooltipText(self.theme.name);
        button.as(gtk.Accessible).updateProperty(.label, self.theme.name.ptr, @as(c_int, -1));

        const content = gtk.Box.new(.vertical, 12);
        content.as(gtk.Widget).addCssClass("appearance-theme-preview");
        const header = gtk.Box.new(.horizontal, 8);
        const name = gtk.Label.new(self.theme.name);
        name.setXalign(0);
        name.setEllipsize(.end);
        name.setMaxWidthChars(20);
        name.as(gtk.Widget).setHexpand(1);
        name.as(gtk.Widget).addCssClass("heading");
        const check = gtk.Image.newFromIconName("object-select-symbolic");
        check.as(gtk.Widget).addCssClass("appearance-theme-check");
        header.append(name.as(gtk.Widget));
        header.append(check.as(gtk.Widget));
        content.append(header.as(gtk.Widget));

        const sample = gtk.Label.new("The quick brown\nfox jumps over\nthe lazy dog");
        sample.setXalign(0);
        sample.as(gtk.Widget).addCssClass("monospace");
        content.append(sample.as(gtk.Widget));

        var css: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&css);
        const bg = self.theme.background;
        const fg = self.theme.foreground;
        writer.print("button.appearance-theme-card {{ background: rgb({d},{d},{d}); color: rgb({d},{d},{d}); }}\n", .{
            bg.r, bg.g, bg.b, fg.r, fg.g, fg.b,
        }) catch unreachable;
        const swatches = gtk.Box.new(.horizontal, 3);
        swatches.setHomogeneous(1);
        var swatch_widgets: [6]*gtk.Widget = undefined;
        for (self.theme.palette[1..7], 0..) |color, i| {
            const swatch = gtk.Box.new(.horizontal, 0).as(gtk.Widget);
            swatch.addCssClass("appearance-swatch");
            swatch.setHexpand(1);
            var class_buf: [32]u8 = undefined;
            swatch.addCssClass(std.fmt.bufPrintZ(&class_buf, "appearance-swatch-{d}", .{i}) catch unreachable);
            var color_buf: [8]u8 = undefined;
            swatch.setTooltipText(std.fmt.bufPrintZ(&color_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ color.r, color.g, color.b }) catch unreachable);
            writer.print(".appearance-swatch-{d} {{ background-color: rgb({d},{d},{d}); }}\n", .{
                i, color.r, color.g, color.b,
            }) catch unreachable;
            swatches.append(swatch);
            swatch_widgets[i] = swatch;
        }
        content.append(swatches.as(gtk.Widget));
        const provider = gtk.CssProvider.new();
        defer provider.as(gobject.Object).unref();
        const css_len = writer.buffered().len;
        css[css_len] = 0;
        provider.loadFromData(css[0..css_len :0], -1);
        button.as(gtk.Widget).getStyleContext().addProvider(provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        for (swatch_widgets) |swatch| {
            swatch.getStyleContext().addProvider(provider.as(gtk.StyleProvider), gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
        button.as(gtk.Button).setChild(content.as(gtk.Widget));
        self.button = button;
        self.check = check;
        _ = gtk.Button.signals.clicked.connect(button.as(gtk.Button), *Card, clicked, self, .{});
    }

    fn clicked(_: *gtk.Button, self: *Card) callconv(.c) void {
        var prefs = self.owner.app.getAppearance();
        prefs.theme = self.theme.name;
        self.owner.apply(prefs);
    }
};

fn matchesQuery(name: []const u8, query: []const u8) bool {
    if (query.len > name.len) return false;
    for (0..name.len - query.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(name[i..][0..query.len], query)) return true;
    }
    return false;
}

fn errorLabel() *gtk.Label {
    const label = gtk.Label.new(null);
    label.setWrap(1);
    label.setXalign(0);
    label.as(gtk.Widget).addCssClass("error");
    label.as(gtk.Widget).setVisible(0);
    return label;
}

fn showError(label: *gtk.Label, err: anyerror) void {
    var buf: [256]u8 = undefined;
    label.setText(std.fmt.bufPrintZ(&buf, "Could not update appearance: {s}. Check that your configuration directory is writable.", .{@errorName(err)}) catch unreachable);
    label.as(gtk.Widget).setVisible(1);
}
