# Colm: next implementation goal

## Objective and approved decisions

Complete the existing native Linux Column application as **Colm (Ka-Lom)**, with the **`clm`** executable, a real automation API/CLI, managed persistent SSH workspaces, and native browser panes with browser automation and remote-network routing.

The user explicitly selected:

- Display name **Colm**, command **`clm`**. This deliberately accepts the potential command-name collision with MCL's `clm`; the installer must still refuse to overwrite an unrelated executable.
- **Terminal + SSH automation AND browser automation**, not a terminal-only subset.
- A new OMP session using **`openai-codex/gpt-6-astra`**, working in goal mode on this plan.

The first working CLI milestone is not the end of the goal. Complete all four phases and verify their integration. Do not present mocks, placeholders, or an SSH-launch wrapper as completed managed SSH.

## Current project and constraints

- Checkout: `/home/al3rez/Work/column`. Keep this checkout path stable while the new OMP session is working in it.
- Existing binary: `~/.local/opt/column/bin/column`; convenience link: `~/.local/bin/column`.
- Existing app ID: `io.github.al3rez.Column`.
- Existing configuration: `~/.config/column/config.ghostty`; appearance preferences: `~/.config/column/auto/appearance.ghostty`.
- Foundation: Ghostty 1.3.1, Zig 0.15.2, GTK4 and libadwaita. Linux only. Preserve the native UI and Ghostty renderer; do not introduce Electron.
- Existing `/usr/bin/ghostty` and `~/.config/ghostty/` are a separate user installation. Never modify them.
- Preserve user settings and live sessions. Do not kill existing user terminals to install or test changes. Existing edits in this checkout are the application, not disposable work.
- Preserve Ghostty's MIT license and legal attribution. cmux currently uses GPL-3.0-or-later: use its public behavior as a reference, not copied implementation code that silently changes this project's licensing.
- The public repo `al3rez/colm` appeared unused through the user's authenticated GitHub account on 2026-09-17. `colm.com`, `colm.dev`, `colm.app`, and `getcolm.com` were registered. `colm.sh` returned no RDAP record but registrar availability/pricing was not confirmed. No repo/domain was created or bought; do not publish, register, or purchase anything without authorization.

## Existing behavior to preserve

- Multiple sidebar workspaces, retaining their running terminals while switching workspaces.
- Horizontally scrolling terminal columns, each filling the available terminal viewport by default; explicit resizing and equalizing work.
- Workspace creation includes a name and native starting-folder picker.
- Sidebar rows show the active terminal's directory, including an initial path without shell integration; valid OSC 7 reports update it.
- Minimal sidebar controls, no terminal headers, rounded terminal clipping, and overlay scrollbars.
- AtkynsonMono Nerd Font Mono, size 11, is configured for this user's app.
- Main-menu System/Light/Dark modes; native chrome by default, optional terminal-colour inheritance.
- Searchable Ghostty palette cards with live, persistent selection and configuration-theme reset. Changes do not restart shells.
- Light C icon is the default; dark alternative also exists. Transparent rounded corners, no added padding.
- Native About dialog: icon, app name, version, Credits and Legal. No "Powered by Ghostty" tagline. Upstream credited under Terminal engine.

## Phase 1 — Complete the rename

- Rename the application identity and user-facing branding from Column to Colm.
- Install the executable as `clm`, with matching launcher commands and a Colm installation prefix.
- Update app ID, desktop file, D-Bus activation, systemd user activation, icons/resources, configuration paths, CLI help, and relevant documentation consistently. A suitable app ID is `io.github.al3rez.Colm`.
- Migrate existing Column settings, including appearance choices, without overwriting any existing Colm settings or losing user files. Remove obsolete launch registrations and links as part of the clean cutover; do not leave a misleading alias-only rename.
- Preserve upstream Ghostty renderer/protocol identifiers and attribution where they are still genuinely Ghostty interfaces. Do not perform a blind replacement of every Ghostty string.
- Refresh desktop activation registrations and verify the real GNOME launch path.

Acceptance: `clm` and the GNOME Colm launcher open the renamed application with the user's migrated settings; the separate Ghostty app remains untouched.

## Phase 2 — Build the automation API and CLI

- Define stable workspace, terminal/surface, and window identifiers. Automation must not accidentally target a different terminal because focus or list order changed.
- Provide machine-readable JSON results, meaningful errors and exit statuses, and documented targeting rules.
- Implement workspace and terminal create/list/focus/rename/close operations through actual application state.
- Implement sending text, sending explicit keys, and reading terminal screen/output. Distinguish sending text from executing it.
- Implement notifications, status, progress, and agent hooks that identify the correct workspace/terminal.
- Provide a private local control endpoint and a real `clm` CLI client. Reuse existing internal operations and GTK/main-thread conventions instead of creating a second independent UI model.
- Protect the endpoint with appropriate local permissions and caller authorization. Do not expose an unauthenticated TCP control port.
- Document and exercise commands from both inside and outside app terminals, including target disappearance and malformed requests.

Acceptance milestone: launch Colm, create a workspace and terminal through its CLI, send a command, and read its real output back as JSON. Also exercise notifications/status/progress and ensure existing user terminals are not inadvertently targeted or restarted.

Current baseline: `column --help` exposes Ghostty helper actions and `+new-window`, not a general automation API. `src/apprt/ipc.zig` currently has only the `new_window` action. `+ssh-cache` manages terminfo installation caching, not remote workspaces.

## Phase 3 — Implement managed SSH workspaces

- Honor OpenSSH host aliases, identity selection, ports, agent authentication, ProxyJump/proxy configuration, and host-key verification.
- Create first-class remote workspaces and additional remote terminals, with local/remote directory metadata distinguished correctly.
- Support an initial command that runs once in the initial remote terminal, not again on every reconnect or added terminal.
- Implement uploads with safe argument/path handling and observable success/failure.
- Implement a scoped remote helper for persistent remote terminal sessions and reattachment after a transport loss. Reconnecting to a fresh shell is not equivalent to preserving a session.
- Relay remote notifications, status, progress and supported automation to the appropriate local workspace.
- Treat the remote host as potentially compromised: authenticate the relay, restrict allowed operations and targets, and do not grant arbitrary control over unrelated local terminals or files.
- Make helper installation, version verification, failure, disconnect/reconnect, resize, and explicit close behavior real and visible. Do not disable host-key verification or leak credentials into logs.

Acceptance: use an isolated SSH test target to verify configuration/auth handling, additional remote terminals, command-once behavior, uploads, and remote notifications. Disconnect/reconnect the transport and demonstrate that a remote process/session survives and is reattached. Verify a remote caller cannot control an unrelated local workspace.

## Phase 4 — Add native browser panes and browser automation

- Integrate WebKitGTK browser panes into workspaces while preserving the native GTK layout and terminal behavior.
- Expose browser navigation, page snapshots, click, fill, and JavaScript evaluation through the same logical API/CLI and stable targeting scheme.
- Handle real loading, navigation failures, asynchronous results, and stale page/element references explicitly.
- Isolate browser sessions and cookie/storage state between the appropriate workspaces/profiles.
- Route browser networking in SSH workspaces through the remote connection, including HTTP and WebSocket traffic. Remote `localhost` must mean the remote machine, not the local desktop.
- Keep browser content untrusted; do not let a page directly obtain privileged app/terminal control. Do not import the user's other browsers' cookies or sessions without authorization.

Acceptance: drive a real browser pane through the CLI against a local test web app: navigate, snapshot, fill, click, and evaluate JavaScript. Verify storage isolation. Then use an SSH workspace to prove remote HTTP and WebSocket routing reaches the remote test server rather than a local lookalike.

## Build and verification

Current working build command (adjust the install prefix and executable name during the rename):

```sh
PKG_CONFIG_PATH="$HOME/.local/opt/column-build-deps/usr/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
  zig build -Doptimize=ReleaseFast -Demit-docs=false \
  --prefix "$HOME/.local/opt/column"
```

The workstation has GTK 4.22.4 and libadwaita 1.9.3. gtk4-layer-shell development metadata was extracted under `~/.local/opt/column-build-deps` without root access. Investigate WebKitGTK and remote-helper prerequisites before editing build integration.

After installing or changing local activation files:

```sh
systemctl --user daemon-reload
busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
  org.freedesktop.DBus ReloadConfig
```

A prior grid-launch failure was caused by Column being absent from the running bus's activatable-service registry despite installed service files. Reloading the registry fixed it; launching the desktop entry created a window and shell successfully. Verify the renamed equivalent, not just the binary from a development shell.

Use native runtime evidence for UI work and end-to-end CLI scenarios for API work. Test real SSH and browser paths with owned fixtures, not forwarding mocks. Keep regression tests where they defend meaningful behavior. Run validation after integrating concurrent edits, not mid-flight on shared files. Update existing documentation and remove throwaway scripts/services after verification.

Desktop-testing cautions:

- The user's normal accessibility bus was refusing connections. Do not restart or disable their accessibility service to hide it.
- GTK 4.22.4's AT-SPI cache handler crashed during automated traversal after closing artificially stacked dialogs; ordinary app rendering and individual dialog flows were verified separately. Do not mistake stale accessibility handles for trustworthy state.
- Do not inject keystrokes into an unknown focused window, restart the user's compositor/session bus, or disrupt their real terminal sessions. If using an isolated display, isolate its runtime, activation environment and configuration too.

## Starting action for the new OMP session

1. Create/activate an OMP goal for the full objective above.
2. Inspect the current checkout and instructions; enumerate this plan in phased todos without dropping accepted scope.
3. Implement the rename and the first real automation milestone, then continue through managed SSH and browser automation.
4. Delegate only genuinely independent slices with explicit interfaces and file ownership; retain integration responsibility.
5. Complete the goal only after all four phases and their end-to-end acceptance criteria are verified. If a real external prerequisite blocks progress, record exactly what is missing rather than silently shrinking the goal.

## References

- cmux CLI/API: https://cmux.com/docs/api
- cmux SSH, helper, session persistence and routing: https://cmux.com/docs/ssh
- cmux notifications: https://cmux.com/docs/notifications
- cmux CLI contract: https://github.com/manaflow-ai/cmux/blob/main/docs/cli-contract.md
- cmux remote daemon specification: https://github.com/manaflow-ai/cmux/blob/main/docs/remote-daemon-spec.md
- cmux license: https://github.com/manaflow-ai/cmux/blob/main/LICENSE
- Existing Colm language/command collision: https://www.colm.net/open-source/colm/
- Current application usage and build details: README.md
