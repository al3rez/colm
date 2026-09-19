const GhosttyResources = @This();

const std = @import("std");
const assert = std.debug.assert;
const Config = @import("Config.zig");
const RunStep = std.Build.Step.Run;
const SharedDeps = @import("SharedDeps.zig");
const gtk_resources = @import("../apprt/gtk/build/gresource.zig");

steps: []*std.Build.Step,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !GhosttyResources {
    var steps: std.ArrayList(*std.Build.Step) = .empty;
    errdefer steps.deinit(b.allocator);
    const is_colm = cfg.target.result.os.tag == .linux;
    const resource_name = if (is_colm) "colm" else "ghostty";
    const terminfo_parent = if (is_colm) "share/colm" else "share";

    if (is_colm) {
        for ([_][]const u8{ "manager.py", "helper.py" }) |file| {
            try steps.append(b.allocator, &b.addInstallFile(
                b.path(b.fmt("src/remote/{s}", .{file})),
                b.fmt("share/colm/remote/{s}", .{file}),
            ).step);
        }
    }

    // This is the exe used to generate some build data.
    const build_data_exe = b.addExecutable(.{
        .name = "ghostty-build-data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_build_data.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });
    build_data_exe.linkLibC();

    deps.help_strings.addImport(build_data_exe);

    // Terminfo
    terminfo: {
        const os_tag = cfg.target.result.os.tag;
        const terminfo_share_dir = if (os_tag == .freebsd)
            "site-terminfo"
        else
            "terminfo";

        // Encode our terminfo
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+terminfo");
        const wf = b.addWriteFiles();
        const source = wf.addCopyFile(run.captureStdOut(), "ghostty.terminfo");

        if (cfg.emit_terminfo) {
            const source_install = b.addInstallFile(
                source,
                if (is_colm)
                    "share/colm/terminfo/ghostty.terminfo"
                else if (os_tag == .freebsd)
                    "share/site-terminfo/ghostty.terminfo"
                else
                    "share/terminfo/ghostty.terminfo",
            );

            try steps.append(b.allocator, &source_install.step);
        }

        // Windows doesn't have the binaries below.
        if (os_tag == .windows) break :terminfo;

        // Convert to termcap source format if thats helpful to people and
        // install it. The resulting value here is the termcap source in case
        // that is used for other commands.
        if (cfg.emit_termcap) {
            const run_step = RunStep.create(b, "infotocap");
            run_step.addArg("infotocap");
            run_step.addFileArg(source);
            const out_source = run_step.captureStdOut();
            _ = run_step.captureStdErr(); // so we don't see stderr

            const cap_install = b.addInstallFile(
                out_source,
                if (is_colm)
                    "share/colm/terminfo/ghostty.termcap"
                else if (os_tag == .freebsd)
                    "share/site-terminfo/ghostty.termcap"
                else
                    "share/terminfo/ghostty.termcap",
            );

            try steps.append(b.allocator, &cap_install.step);
        }

        // Compile the terminfo source into a terminfo database
        {
            const run_step = RunStep.create(b, "tic");
            run_step.addArgs(&.{ "tic", "-x", "-o" });
            const path = run_step.addOutputFileArg(terminfo_share_dir);

            run_step.addFileArg(source);
            _ = run_step.captureStdErr(); // so we don't see stderr

            // Ensure that `share/terminfo` is a directory, otherwise the `cp
            // -R` will create a file named `share/terminfo`
            const mkdir_step = RunStep.create(b, "make share/terminfo directory");
            switch (cfg.target.result.os.tag) {
                // windows mkdir shouldn't need "-p"
                .windows => mkdir_step.addArgs(&.{"mkdir"}),
                else => mkdir_step.addArgs(&.{ "mkdir", "-p" }),
            }

            mkdir_step.addArg(b.fmt(
                "{s}/{s}/{s}",
                .{ b.install_path, terminfo_parent, terminfo_share_dir },
            ));

            try steps.append(b.allocator, &mkdir_step.step);

            // Use cp -R instead of Step.InstallDir because we need to preserve
            // symlinks in the terminfo database. Zig's InstallDir step doesn't
            // handle symlinks correctly yet.
            const copy_step = RunStep.create(b, "copy terminfo db");
            copy_step.addArgs(&.{ "cp", "-R" });
            copy_step.addFileArg(path);
            copy_step.addArg(b.fmt("{s}/{s}", .{ b.install_path, terminfo_parent }));
            copy_step.step.dependOn(&mkdir_step.step);
            try steps.append(b.allocator, &copy_step.step);
        }
    }

    // Shell-integration
    {
        const install_step = b.addInstallDirectory(.{
            .source_dir = b.path("src/shell-integration"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = b.pathJoin(&.{ resource_name, "shell-integration" }),
            .exclude_extensions = &.{".md"},
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // Themes
    if (cfg.emit_themes) {
        if (b.lazyDependency("iterm2_themes", .{})) |upstream| {
            const install_step = b.addInstallDirectory(.{
                .source_dir = upstream.path(""),
                .install_dir = .{ .custom = "share" },
                .install_subdir = b.pathJoin(&.{ resource_name, "themes" }),
                .exclude_extensions = &.{".md"},
            });
            try steps.append(b.allocator, &install_step.step);
        }
    }

    // Fish shell completions
    if (!is_colm) {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+fish");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(), "ghostty.fish");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/fish/vendor_completions.d",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // zsh shell completions
    if (!is_colm) {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+zsh");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(), "_ghostty");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/zsh/site-functions",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // bash shell completions
    if (!is_colm) {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+bash");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(), "ghostty.bash");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bash-completion/completions",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // Vim and Neovim plugin
    if (!is_colm) {
        const wf = b.addWriteFiles();

        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-syntax");
            _ = wf.addCopyFile(run.captureStdOut(), "syntax/ghostty.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-ftdetect");
            _ = wf.addCopyFile(run.captureStdOut(), "ftdetect/ghostty.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-ftplugin");
            _ = wf.addCopyFile(run.captureStdOut(), "ftplugin/ghostty.vim");
        }
        {
            const run = b.addRunArtifact(build_data_exe);
            run.addArg("+vim-compiler");
            _ = wf.addCopyFile(run.captureStdOut(), "compiler/ghostty.vim");
        }

        const vim_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/vim/vimfiles",
        });
        try steps.append(b.allocator, &vim_step.step);

        const neovim_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/nvim/site",
        });
        try steps.append(b.allocator, &neovim_step.step);
    }

    // Sublime syntax highlighting for bat cli tool
    // NOTE: The current implementation requires symlinking the generated
    // 'ghostty.sublime-syntax' file from zig-out to the '~.config/bat/syntaxes'
    // directory. The syntax then needs to be mapped to the correct language in
    // the config file within the '~.config/bat' directory
    // (ex: --map-syntax "/Users/user/.config/ghostty/config.ghostty:Ghostty Config").
    if (!is_colm) {
        const run = b.addRunArtifact(build_data_exe);
        run.addArg("+sublime");
        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(run.captureStdOut(), "ghostty.sublime-syntax");

        const install_step = b.addInstallDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/bat/syntaxes",
        });
        try steps.append(b.allocator, &install_step.step);
    }

    // App (Linux)
    if (cfg.target.result.os.tag == .linux) try addLinuxAppResources(
        b,
        cfg,
        &steps,
    );

    return .{ .steps = steps.items };
}

/// Add the resource files needed to make Ghostty a proper
/// Linux desktop application (for various desktop environments).
fn addLinuxAppResources(
    b: *std.Build,
    cfg: *const Config,
    steps: *std.ArrayList(*std.Build.Step),
) !void {
    assert(cfg.target.result.os.tag == .linux);

    // Background:
    // https://developer.gnome.org/documentation/guidelines/maintainer/integrating.html

    const name = "Colm";
    const app_id = "io.github.al3rez.Colm";

    // Desktop launchers must not bake a staging --prefix into Exec=.
    // DBus/systemd units below still use the absolute installed path.
    const exe_abs_path = b.fmt(
        "{s}/bin/clm",
        .{b.install_prefix},
    );
    const desktop_exec = "clm";


    // The templates that we will process. The templates are in
    // cmake format and will be processed and saved to the
    // second element of the tuple.
    const Template = struct { std.Build.LazyPath, []const u8 };
    const templates: []const Template = templates: {
        var ts: std.ArrayList(Template) = .empty;
        defer ts.deinit(b.allocator);

        // Desktop file so that we have an icon and other metadata
        try ts.append(b.allocator, .{
            b.path("dist/linux/app.desktop.in"),
            b.fmt("share/applications/{s}.desktop", .{app_id}),
        });

        // Service for DBus activation.
        try ts.append(b.allocator, .{
            if (cfg.flatpak)
                b.path("dist/linux/dbus.service.flatpak.in")
            else
                b.path("dist/linux/dbus.service.in"),
            b.fmt("share/dbus-1/services/{s}.service", .{app_id}),
        });

        // `systemd` user service. This is kind of nasty but `systemd` looks for
        // user services in different paths depending on if we are installed
        // as a system package or not (lib vs. share) so we have to handle that
        // here. We might be able to get away with always installing to both
        // because it only ever searches in one... but I don't want to do that
        // hack until we have to.
        //
        // The XDG Freedesktop Portal has a major undocumented requirement
        // for programs that are launched/controlled by `systemd` to interact
        // with the Portal. The unit must be named `app-<appid>.service`. The
        // Portal uses the `systemd` unit name figure out what the program's
        // application ID is and it will only look at unit names that begin with
        // `app-`. I can find no place that this is documented other than by
        // inspecting the code or the issue and PR that introduced this feature.
        // See the following code:
        //
        // https://github.com/flatpak/xdg-desktop-portal/blob/7d4d48cf079147c8887da17ec6c3954acd5a285c/src/xdp-utils.c#L152-L220
        if (!cfg.flatpak) try ts.append(b.allocator, .{
            b.path("dist/linux/systemd.service.in"),
            b.fmt(
                "{s}/systemd/user/app-{s}.service",
                .{
                    if (b.graph.system_package_mode) "lib" else "share",
                    app_id,
                },
            ),
        });

        // AppStream metainfo so that application has rich metadata
        // within app stores
        try ts.append(b.allocator, .{
            b.path("dist/linux/io.github.al3rez.Colm.metainfo.xml.in"),
            b.fmt("share/metainfo/{s}.metainfo.xml", .{app_id}),
        });

        break :templates try ts.toOwnedSlice(b.allocator);
    };

    // Process all our templates
    for (templates) |template| {
        const desktop = std.mem.indexOf(u8, template[1], "applications") != null;
        const tpl = b.addConfigHeader(.{
            .style = .{ .cmake = template[0] },
        }, .{
            .NAME = name,
            .APPID = app_id,
            .GHOSTTY = if (desktop) desktop_exec else exe_abs_path,
        });


        // Template output has a single header line we want to remove.
        // We use `tail` to do it since its part of the POSIX standard.
        const tail = b.addSystemCommand(&.{ "tail", "-n", "+2" });
        tail.setStdIn(.{ .lazy_path = tpl.getOutput() });

        const copy = b.addInstallFile(
            tail.captureStdOut(),
            template[1],
        );

        try steps.append(b.allocator, &copy.step);
    }

    for (gtk_resources.icon_variants) |variant| {
        for (gtk_resources.icon_sizes) |size| {
            try steps.append(b.allocator, &b.addInstallFile(
                b.path(b.fmt("images/colm{s}/{d}.png", .{ variant, size })),
                b.fmt("share/icons/hicolor/{d}x{d}/apps/{s}{s}.png", .{ size, size, app_id, variant }),
            ).step);
        }
    }
}

pub fn install(self: *const GhosttyResources) void {
    const b = self.steps[0].owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const GhosttyResources,
    other_step: *std.Build.Step,
) void {
    for (self.steps) |step| other_step.dependOn(step);
}
