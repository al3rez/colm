# Colm

A native Linux terminal workspace app built from Ghostty 1.3.1, using GTK4,
libadwaita, and Ghostty's terminal renderer. It uses a Niri-inspired horizontal
column layout inside a normal application window; it does not replace the desktop.

## Use

Launch **Colm (Ka-Lom)** from the application launcher, or run `clm`.

- The **+ at the top of the sidebar** opens workspace setup. Choose a name and
  starting folder; a native folder picker is available.
- Double-click empty space below the workspace rows to create a workspace
  immediately, using the same inherited defaults as Ctrl+Shift+N.
- Click a workspace name to return to its terminals. Its shells remain running
  while another workspace is selected.
- Workspace rows are compact, cmux-style summaries: the name, the latest
  reported status (`clm status`/`clm agent-hook`), the newest notification
  message, then the git branch (`clm ctl surface.report_git_branch`) and the
  active terminal's directory. The starting directory appears even without
  shell integration; shell directory reports update it as you navigate.
- A numeric badge counts a workspace's unread notifications across all of its
  terminals. Opening the workspace marks them read; the message stays visible
  so context is not lost.
- Click the ○ glyph on a workspace row, or the row's **Task status** menu, to
  mark it Running, Blocked, Error, or Done. Done workspaces dim.
  `clm set-task-status running|blocked|error|done|clear` does the same.
- The sidebar's overview button shows all workspaces. Its menu contains rename
  and close actions. There are no sidebar headings, decorative row icons, or
  bottom controls.
- Terminals fill the available terminal area by default. The **+ above the
  terminal area** adds another full-width column and reveals it horizontally,
  rather than squeezing existing terminals into the window.
- Default column widths follow window resizing. Explicitly resized columns
  retain their chosen width; equalizing resets them to the viewport width.
- Scroll horizontally or use the keyboard to navigate columns. The canvas and
  terminal scrollbars use GTK's auto-hiding overlay mode.
- Terminal columns have no title/tab bars. Their content is clipped to rounded
  corners; the active column has an accent border.
- Close a terminal from the main menu or keyboard. Closing a workspace closes
  its terminals, with confirmation when a running command requires it.

| Shortcut                    | Action                                                |
| --------------------------- | ----------------------------------------------------- |
| Ctrl+Shift+T                | Add a terminal column                                 |
| Ctrl+Shift+N                | Quickly create a workspace in the inherited directory |
| Alt+Left / Alt+Right        | Focus and reveal the adjacent terminal                |
| Ctrl+PageUp / Ctrl+PageDown | Switch workspaces                                     |
| Ctrl+Shift+W                | Close the focused terminal                            |

Local workspace state is retained during the application's lifetime; local shells
are not checkpointed after quitting. Managed SSH terminals survive transport loss
in a remote PTY daemon and reattach to the same processes. Explicit terminal or
workspace close terminates its remote sessions. Browser storage is ephemeral and
isolated by workspace. Real memory, process, and GPU resources still apply.

## Appearance

The main menu has **System**, **Light**, and **Dark** window modes. System is the
default and follows the desktop preference.

Open **Appearance…** to search and browse Ghostty palettes. Cards preview the
actual background, foreground, and ANSI colours; selecting one updates running
terminals without restarting their shells. The reset button restores the theme
defined in your main configuration.

**Match window colours to terminal** optionally tints the window and sidebar
using the terminal palette. It is off by default, keeping native libadwaita
colours independent of the terminal.

Selections are saved in `~/.config/colm/auto/appearance.ghostty`; the main
configuration is not rewritten. These preferences load after the main config;
command-line options retain their normal precedence.

The light icon is the default, with a dark alternative also installed. Both
have transparent rounded corners and no extra padding around the artwork.
About uses the native libadwaita layout, with upstream engine credits and the
MIT license in separate Credits and Legal sections.

## Separate from Ghostty

- Executable: `clm` (not the unrelated `colm` compiler)
- Application ID: `io.github.al3rez.Colm`
- Configuration: `~/.config/colm/config.ghostty`
- Resources: `share/colm` inside the installation prefix
- Installed locally at `~/.local/opt/colm`

Ghostty's existing executable and configuration are not replaced. Ghostty's
configuration syntax still applies. Terminal identity and shell integration stay
Ghostty-compatible, including `TERM=xterm-ghostty` and private terminfo resources.

The short command name `clm` also exists in the unrelated MCL package. This
local name collision is accepted: put `~/.local/bin` on `PATH` to select Colm,
and use the other package's absolute executable path when needed. Colm's display
name, application ID, configuration, installation prefix, and `COLM_*`
environment variables are unchanged.

On first configuration access, Colm copies regular files and directories from
`$XDG_CONFIG_HOME/column` (normally `~/.config/column`) to the adjacent `colm`
directory, including appearance preferences, custom themes, and other user files.
Existing Colm entries always win. The original Column directory is retained.
Symlinks and special files are not followed or copied; warnings identify entries
left in the original directory. A `.column-migration-complete` marker prevents
subsequent launches from restoring settings you deliberately deleted.
Migration errors remain visible and are retried on the next configuration access.

## Automation

`clm` without a command launches the app. A direct command such as `clm ssh`
also starts Colm when no instance is running, waits for its private endpoint,
then performs the operation. Direct commands expose the existing control API
without requiring hand-written JSON. The earlier implementation had backend
APIs for these operations but lacked this ergonomic command frontend.
The command vocabulary is cmux-inspired, not a claim of full cmux compatibility:
there are no mosh/tmux, deep-link, or drag-and-drop compatibility guarantees.
Unsupported commands and options fail explicitly.

Each native app instance owns a private Unix control socket under
`$XDG_RUNTIME_DIR/colm/control-PID.sock`. Its directory is mode 0700, the socket
is 0600, and accepted peers must have the application's UID. There is no TCP
control listener. Outside the app, the CLI discovers a single running instance.
With multiple independent instances it returns `AmbiguousInstance`: run
`clm endpoints`, then use `--socket /path/to/control-PID.sock` or set
`COLM_SOCKET` to select the intended instance. Inside terminals, this variable
is supplied automatically. Processes running as your user are trusted; browser
pages and remote hosts are not.

```sh
clm list-windows
clm list-workspaces
clm new-workspace --name "Project" --cwd "/absolute/project"
# Use the workspace_id and terminal_id returned by creation:
clm select-workspace --workspace WORKSPACE_ID
clm new-terminal --workspace WORKSPACE_ID
clm list-terminals --workspace WORKSPACE_ID
clm send --terminal TERMINAL_ID 'printf "%s\n" "hello world"'
clm send-key --terminal TERMINAL_ID enter
clm read-screen --terminal TERMINAL_ID
# Destructive: closes the workspace and its terminals.
clm close-workspace --workspace WORKSPACE_ID --force
```

IDs identify native windows, workspaces, terminals, and browser panes for their
lifetimes. They are never list indexes or focus aliases and are not reused.
`new-workspace` without `--window` creates a new window; `new-window` creates a
window with an initial workspace. Other targeted commands require an ID; they
never fall back to desktop focus. Local shells receive `COLM_SOCKET`,
`COLM_WINDOW_ID`, `COLM_WORKSPACE_ID`, and `COLM_TERMINAL_ID`. With no explicit
target, the CLI uses the shell's workspace/terminal IDs. Any explicit target
disables these ambient defaults: supply all IDs required by that operation
rather than relying on whichever terminal happens to be focused.

Use `--window ID`, `--workspace ID`, and `--terminal ID` for the corresponding
targets or supported list filters; browser commands also use `--browser ID`.
Flags accept `--key=value` as well as `--key value`. `--` ends option parsing
so positional text beginning with a dash remains literal, for example
`clm send --terminal TERMINAL_ID -- '--not-an-option'`. Quote text for your
shell: one quoted argument preserves spaces and prevents local expansion.
`send` pastes UTF-8 text and does **not** append Enter; use `send-key enter`
separately to submit a command. Explicit newlines still follow terminal paste
semantics. `send-key` accepts Ghostty physical key names such as `enter`,
`key_c`, and `arrow_up`; it encodes terminal input, not application shortcuts.

| Direct commands                                                                       | Arguments and behavior                                                                                 |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `list-windows`, `new-window`                                                          | List windows or create a window with an initial workspace                                              |
| `focus-window`, `rename-window NAME`, `close-window`                                  | `--window ID`; close requires `--force`                                                                |
| `list-workspaces`, `new-workspace`                                                    | Optional `--window ID`; creation accepts `--name NAME`, `--cwd DIR`, `--command TEXT`                  |
| `select-workspace`, `rename-workspace NAME`, `close-workspace`                        | `--workspace ID`; close requires `--force`                                                             |
| `list-terminals`, `new-terminal`                                                      | `--workspace ID`; creation accepts `--cwd DIR`, `--command TEXT`                                       |
| `focus-terminal`, `rename-terminal NAME`, `close-terminal`                            | `--terminal ID`; close requires `--force`                                                              |
| `send TEXT`, `read-screen`                                                            | `--terminal ID`; read returns active-screen/scrollback text and dimensions, not an output-event stream |
| `send-key KEY`                                                                        | `--terminal ID`, optional `--ctrl`, `--alt`, `--shift`, `--text TEXT`                                  |
| `notify TITLE [BODY]`                                                                 | Workspace or terminal target; alternatively `--title TITLE --body BODY`                                |
| `status [TEXT]`                                                                       | Workspace or terminal target; set text, or omit it to read status                                      |
| `progress PERCENT`, `progress clear`                                                  | Workspace or terminal target; integer 0–100, or clear                                                  |
| `agent-hook EVENT`                                                                    | Workspace or terminal target; report event as status text                                              |
| `ssh HOST`, `ssh-status`, `ssh-disconnect`, `ssh-reconnect`, `ssh-upload SOURCE DEST` | See managed SSH below                                                                                  |
| `browser create/list/close/navigate/status/snapshot/click/fill/evaluate`              | See browser commands below                                                                             |
| `endpoints`                                                                           | List running control endpoints for explicit instance selection                                         |

Window, workspace, and terminal close operations are destructive and require
`--force`; browser close does not. Normal native controls retain their
confirmation behavior. `--json` is accepted, but JSON is already
the default. Each API response is one JSON object:
`{"ok":true,"result":…}` or
`{"ok":false,"error":{"code":"…","message":"…"}}`. Exit codes are 0 for success,
1 for API errors, and 2 for CLI/transport errors. The socket accepts one
newline-delimited request per connection, up to 1 MiB. Malformed input,
missing/disappeared targets, mismatched workspace/terminal targets, and terminals
not yet initialized are errors. Creation can return `ready:false`; retry a
terminal operation after the native surface initializes.
The endpoint admits at most 32 simultaneous clients. Client/connection deadlines
are six minutes; browser operation deadlines are described below.

```sh
# Inside a Colm terminal, these target that terminal even if focus moved:
clm agent-hook working
clm status "Running checks"
clm status
clm progress 50
clm notify "Agent" "Review ready"
clm progress clear
```

### Agent bridges

`clm agent hooks-install omp` writes a native omp hook factory into
`~/.omp/agent/hooks/post/` (honoring `PI_CODING_AGENT_DIR`). Once omp
restarts, every session running inside a Colm terminal reports
automatically: a status line while a turn runs, and sidebar notifications
when omp asks for input or finishes a turn. The factory is a no-op outside
Colm terminals.

`clm agent hooks-install claude` registers `Notification` and `Stop` hooks
in Claude Code's own `~/.claude/settings.json` (honoring
`CLAUDE_CONFIG_DIR`), the same mechanism cmux uses. The bridge script reads
Claude's hook JSON from stdin and records the message against the owning
workspace. Installation merges — existing settings entries are preserved —
and `hooks-uninstall` removes only Colm's entries.

### Low-level escape hatch

The raw API remains intentional for integrations that need JSON:

```sh
clm ctl workspace.list
clm ctl terminal.send-text '{"terminal_id":"TERMINAL_ID","text":"printf hello"}'
clm ctl request '{"method":"terminal.send-key","params":{"terminal_id":"TERMINAL_ID","key":"enter"}}'
```

`clm ctl METHOD JSON` uses the same ambient workspace/terminal defaults when
there is no explicit target. `clm ctl request JSON` sends a raw request without
defaults. Raw methods use API parameter names such as `workspace_id`,
`terminal_id`, `timeout_ms`, and `force:true`; direct commands translate their
flags into those parameters.
Both raw forms also accept the global `--socket PATH` and `--json` flags.

## Managed SSH workspaces

```sh
clm ssh my-openssh-alias
# Or supply initial workspace and shell settings:
clm ssh my-openssh-alias --name "Remote project" --cwd /srv/project \
  --command 'export PROJECT_READY=1'
# Use the workspace_id returned by ssh:
clm new-terminal --workspace REMOTE_WORKSPACE_ID
clm ssh-status --workspace REMOTE_WORKSPACE_ID
clm ssh-upload /local/file /remote/file --workspace REMOTE_WORKSPACE_ID
clm ssh-disconnect --workspace REMOTE_WORKSPACE_ID
clm ssh-reconnect --workspace REMOTE_WORKSPACE_ID
```

`clm ssh HOST` also accepts `--window ID`, `-p PORT` / `--port PORT`,
`-i FILE` / `--identity FILE`, and `-F FILE` / `--ssh-config FILE`.
`ssh-status`, `ssh-disconnect`, and `ssh-reconnect` accept `--workspace ID`
or use the ambient workspace; `ssh-upload SOURCE DEST` requires an explicit
`--workspace ID`. Colm does not accept arbitrary OpenSSH `-o` forwarding.
Put advanced SSH settings in `~/.ssh/config` or the file selected with `-F`.
OpenSSH resolves host aliases, identities, agent authentication,
ProxyJump/proxy configuration, and host-key policy. Colm does not forward your
agent or disable host-key verification. Connections are noninteractive
(`BatchMode=yes`): establish trust and unlock keys with normal OpenSSH first;
unknown keys and authentication failures are reported rather than silently
accepted. This is Colm's managed SSH session model, not mosh or tmux integration.

Python 3 is required on the remote machine. Colm installs its own versioned,
SHA256-verified helper under `~/.local/share/colm/remote`. A private remote daemon
owns real PTYs and shell processes independently of the SSH connection.
Disconnecting leaves them alive; reconnecting reattaches the same sessions,
including retained output and terminal dimensions. The initial command runs
once in the initial terminal, not in additional terminals or during reconnect.
An explicit terminal/workspace close destroys its owned remote sessions.
Remote metadata is labeled `directory_kind:"remote"`; it is never a local
starting directory. Uploads stream bytes through SSH to an atomic remote-file
replacement, with quoted arguments and observable errors.
The initial shell is started on first attachment, after its local workspace and
capability exist, so initial-command hooks cannot race workspace creation.
Added terminals accept their own `cwd`/`command`; native add-terminal controls
also create remote terminals. Remote directory changes update metadata and the
sidebar without changing the local process directory.

One MiB of output per terminal is retained while detached; overflow is reported
rather than silently presented as complete output. Upload destinations are
absolute remote paths (or `~/...`); incomplete uploads never replace an existing
destination. `clm ssh-status` reports transport state, helper version and remote
terminal PIDs. Explicit close waits for remote termination; native controls show
failures rather than claiming a disconnected session was killed.
Quitting normally also waits for these acknowledgments; an abrupt application
termination is not a guaranteed remote close. Local workspaces are not restored
after restarting Colm.

Failed creation rolls back its new remote resources. If transport loss prevents
rollback, the error names the retained workspace ID and private recovery-state
file. Once SSH is reachable, close that otherwise unclaimed session explicitly:

```sh
python3 "$HOME/.local/opt/colm/share/colm/remote/manager.py" \
  '{"method":"close","params":{"workspace_id":"REPORTED_WORKSPACE_ID"}}'
```

The remote shell's helper command is deliberately limited:

```sh
clm notify "Agent" "Review ready"
clm status "working"
clm progress 50
clm progress clear
```

If shell startup resets `PATH`, use `"$COLM_REMOTE_CLI" status "working"` (and
the same absolute helper for `notify`, `progress`, or `request JSON`).
This remote `clm` is a restricted helper, not the desktop CLI: it does not expose
the full direct-command or `ctl` interface described above.

Its authenticated reverse-SSH Unix relay accepts only notifications, status,
and progress for that workspace's terminals. The remote secret is distinct
from the local control capability. Remote callers cannot create/focus terminals,
read local output, upload local files, or target another workspace. Helper
installation/version failures and disconnection are visible; they never
silently substitute a new shell for an existing session.

## Native browser panes

```sh
clm browser create --workspace WORKSPACE_ID
clm browser list --workspace WORKSPACE_ID
# Use the browser_id returned by create:
clm browser navigate 'http://localhost:3000/' \
  --workspace WORKSPACE_ID --browser BROWSER_ID --timeout-ms 30000
clm browser status --workspace WORKSPACE_ID --browser BROWSER_ID
clm browser snapshot --workspace WORKSPACE_ID --browser BROWSER_ID
# Replace generation 2 and refs e1/e2 with values from your latest snapshot:
clm browser fill e1 "hello" \
  --workspace WORKSPACE_ID --browser BROWSER_ID --generation 2
clm browser click e2 \
  --workspace WORKSPACE_ID --browser BROWSER_ID --generation 2
clm browser evaluate 'document.title' --workspace WORKSPACE_ID --browser BROWSER_ID
clm browser close --workspace WORKSPACE_ID --browser BROWSER_ID
```

Use the actual `generation` and element `ref` returned by the latest snapshot.
Navigation or replacement/detachment of elements makes old references stale;
take a fresh snapshot. Snapshots return visible text and interactive elements,
including accessible names. `browser create` and `browser list` take a workspace
target; the other commands also take `--browser ID`. `browser navigate URI`,
`browser fill REF VALUE`, `browser click REF`, and `browser evaluate SCRIPT`
take positional arguments as shown above. Click and fill require the snapshot's
`--generation INT`. Navigation waits for loading; evaluation awaits promises.
`--timeout-ms INT` defaults to 30000 and accepts 1–120000 for browser operations
that wait for completion. Loading, network failures,
timeouts, closed panes, stale generations, and JavaScript exceptions return
explicit errors.
A new snapshot replaces previous element references even without navigation.
Evaluation runs in a retained isolated world: it accesses the DOM, not
page-defined JavaScript globals. Results must be JSON-serializable. Click uses
DOM activation, not a trusted physical input gesture. Snapshots cover the main
document and open shadow roots, not cross-origin iframe internals, and cap text
at 262144 characters and interactive elements at 5000.

Browser panes are native WebKitGTK widgets beside the workspace's live terminal
area, with address, back, reload, and close controls. They use ephemeral
cookie/storage sessions shared only within the same workspace; different
workspaces are isolated and no external browser profile is imported. Automation
runs in a named script world with no privileged page-to-application bridge.
Native permission requests, popup windows, and WebRTC are disabled.
Closing the last pane releases that workspace's ephemeral browser session.
Authenticate inside the intended workspace's browser panes; your normal
browser's saved login is not available, and another workspace does not inherit
it. Closing the last pane also discards that workspace's browser login state.

In SSH workspaces, HTTP(S) and WebSocket traffic uses the managed OpenSSH SOCKS
connection, including destination DNS and localhost. Remote `localhost` means
the remote host, not the desktop. Loss of the proxy produces a network error,
not a direct-local fallback. Top-level navigation permits only HTTP(S) and
`about:blank`.

## Build

Requires Zig **0.15.2**, GTK4 development libraries (including the GTK 4.10 file
chooser API), libadwaita **1.5 or newer**, gtk4-layer-shell development metadata,
WebKitGTK **6.0** / JavaScriptCoreGTK **6.0**, Python **3**, OpenSSH, Blueprint
compiler, and the other native dependencies described in
[Ghostty's development guide](HACKING.md).

```sh
zig build -Doptimize=ReleaseFast -Demit-docs=false \
  --prefix "$HOME/.local/opt/colm"
"$HOME/.local/opt/colm/bin/clm"
```

On this workstation, the missing gtk4-layer-shell development package was
extracted locally without root access. To rebuild using that package:

```sh
PKG_CONFIG_PATH="$HOME/.local/opt/column-build-deps/usr/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
  zig build -Doptimize=ReleaseFast -Demit-docs=false \
  --prefix "$HOME/.local/opt/colm"
```

After the build installs into that prefix, register it for the current user:

```sh
python3 dist/linux/install-colm.py --prefix "$HOME/.local/opt/colm"
```

The installer links the launcher, icons, D-Bus/systemd activation files, and
`~/.local/bin/clm`. It refuses unrelated destination files, including an existing
regular `clm` executable or a symlink to another package; the accepted MCL name
collision does not authorize overwriting that package. It removes the old
`~/.local/bin/colm-terminal` link only when it points to this prefix's old Colm
binary, and old Column registrations only when they reference the old Column
prefix. It retains the old binary and settings so existing windows and shells
can continue running.
Neither installation nor activation refresh stops any service or user terminal.
Use `--dry-run` to inspect the cutover first. The checkout and
`~/.local/opt/column-build-deps` paths are deliberately unchanged.

The installer also refreshes the running session's service registry. To repeat
that refresh manually:

```sh
systemctl --user daemon-reload
busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
  org.freedesktop.DBus ReloadConfig
```

This does not restart the session bus or require logging out. Verify the launcher
path with `gio launch ~/.local/share/applications/io.github.al3rez.Colm.desktop`.
Check that your shell resolves the intended executable, then query the running
app without stopping existing terminals:

```sh
command -v clm
readlink -f "$HOME/.local/bin/clm"
clm endpoints
clm list-workspaces --socket /path/to/control-PID.sock
```

The executable should resolve to `~/.local/opt/colm/bin/clm`; use an actual
socket path from `endpoints` for the final command. If your shell cached an older
`clm` command, refresh its command cache or start a new shell.

## Verification

Focused remote trust-boundary, upload, and first-attachment regressions:

```sh
python3 -m unittest discover -s src/remote -v
```

The browser regression uses a real native WebKit pane, not a DOM mock. Select an
explicit running test instance; it creates and closes only its own workspaces:

```sh
clm endpoints
COLM_TEST_SOCKET=/path/to/test-instance.sock \
  python3 src/apprt/gtk/test_browser.py -v
```

`src/apprt/gtk/test_ids.py` runs the same way and defends the handle contract:
`workspace:N`/`surface:N` identifiers stay bound to their objects through
reorders and closes, and terminal-targeted notifications land on the owning
workspace.

Set `COLM_BINARY` if testing an executable outside `PATH`. The regression checks
snapshot references across async calls, invalidation, timeout recovery, and
cross-workspace cookie/storage isolation. End-to-end SSH verification requires
an owned SSH target; compare remote HTTP and WebSocket responses against a local
lookalike, preserve a shell variable/background process through disconnect and
reconnect, and explicitly close the test workspace afterward.

Sidebar rows match cmux's published metrics (8px row padding, 4px slot
spacing, 2px row gap, 12.5px semibold titles, 10–10.5px details) and prefer
the Inter font — the closest open equivalent of macOS SF Pro — falling back
to the GNOME UI font. For interactive checks without touching the live
desktop, run a disposable instance inside a headless nested compositor
(`WLR_BACKENDS=headless sway`/`cage` with an isolated `XDG_CONFIG_HOME`);
`wtype` delivers real keyboard input there and `grim` captures the output.
Headless seats advertise no pointer capability, so pointer gestures must be
verified on a real session.

## Upstream and visual references

Terminal engine and native application foundations: [Ghostty](https://github.com/ghostty-org/ghostty).
The upstream MIT license and attribution are retained in [LICENSE](LICENSE).

Layout reference: [Cube Computer column mode](https://x.com/yiliush/status/2094998877623754946).
Sidebar reference: [cmux screenshots](https://github.com/manaflow-ai/cmux#features).
Palette and About presentation reference: [Ptyxis](https://gitlab.gnome.org/chergert/ptyxis).
Colm retains its own implementation; cmux is a behavioral reference, not copied code.
