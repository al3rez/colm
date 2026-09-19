#!/usr/bin/env python3
"""Colm's versioned, per-workspace persistent PTY service (Python stdlib only)."""
import base64
import errno
import fcntl
import hashlib
import hmac
import json
import os
import pathlib
import pty
import select
import selectors
import shlex
import signal
import socket
import stat
import struct
import subprocess
import sys
import termios
import time

VERSION = 1
MAX_FRAME = 2 * 1024 * 1024
BACKLOG = 1024 * 1024


def encoded(value):
    return (json.dumps(value, separators=(",", ":")) + "\n").encode()


def private_dir(path):
    path = pathlib.Path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise PermissionError("unsafe private directory: " + str(path))
    return path


def runtime(workspace):
    root = private_dir(pathlib.Path("/tmp") / ("colm-" + str(os.getuid())))
    return private_dir(root / hashlib.sha256(workspace.encode()).hexdigest()[:24])


def read_frame(stream):
    raw = stream.readline(MAX_FRAME + 1)
    if not raw or len(raw) > MAX_FRAME or not raw.endswith(b"\n"):
        raise ValueError("missing or oversized protocol frame")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("protocol frame must be an object")
    return value


def rpc(path, token, method, **params):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(15)
        sock.connect(str(path))
        sock.sendall(encoded(dict(token=token, method=method, params=params)))
        with sock.makefile("rb") as stream:
            response = read_frame(stream)
        if not response.get("ok"):
            raise RuntimeError(response.get("error", {}).get("message", "remote request failed"))
        return response["result"]


def resize(fd, rows, cols):
    rows, cols = int(rows), int(cols)
    if not 1 <= rows <= 65535 or not 1 <= cols <= 65535:
        raise ValueError("terminal dimensions must be between 1 and 65535")
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def kill_session(pid):
    # Job-control shells put foreground/background jobs in additional process groups.
    # Kill the entire owned session, not just the shell's first process group.
    members = {pid}
    try:
        for entry in pathlib.Path("/proc").iterdir():
            if entry.name.isdigit():
                try:
                    fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
                    if int(fields[3]) == pid:
                        members.add(int(entry.name))
                except (OSError, ValueError, IndexError):
                    pass
    except OSError:
        pass
    for sig in (signal.SIGHUP, signal.SIGKILL):
        for member in members:
            try:
                os.kill(member, sig)
            except ProcessLookupError:
                pass
        if sig == signal.SIGHUP:
            time.sleep(0.05)


class Terminal:
    def __init__(self, server, terminal_id, cwd, command):
        self.id = terminal_id
        self.cwd = os.path.abspath(os.path.expanduser(cwd or "~"))
        if not os.path.isdir(self.cwd):
            raise ValueError("remote working directory does not exist")
        self.backlog = bytearray()
        self.clients = set()
        self.exit_code = None
        self.sequence = 0
        shell = os.environ.get("SHELL", "/bin/sh")
        start_read, self.start_fd = os.pipe()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                os.close(self.start_fd)
                # fork inherited the daemon's client/listener descriptors.
                # Close them before waiting: otherwise create's bridge cannot
                # observe EOF until this child execs, deadlocking attachment.
                os.closerange(3, start_read)
                os.closerange(start_read + 1, os.sysconf("SC_OPEN_MAX"))
                # The GTK workspace and its capability exist before its attach
                # process connects. This prevents initial hooks racing creation.
                if os.read(start_read, 1) != b"1":
                    os._exit(1)
                os.close(start_read)
                os.chdir(self.cwd)
                os.environ.update(TERM="xterm-256color", COLM_WORKSPACE_ID=server.workspace,
                                  COLM_TERMINAL_ID=terminal_id, COLM_REMOTE_RELAY=server.relay,
                                  COLM_REMOTE_CAPABILITY=server.relay_token,
                                  COLM_REMOTE_CLI=str(pathlib.Path(__file__).resolve().parent / "bin" / "clm"),
                                  PATH=str(pathlib.Path(__file__).resolve().parent / "bin") + ":" + os.environ.get("PATH", "/usr/bin:/bin"))
                if command:
                    os.execv(shell, [shell, "-lc", command + "\nexec " + shlex.quote(shell) + " -l"])
                os.execv(shell, [shell, "-l"])
            except BaseException as exc:
                os.write(2, ("colm: " + str(exc) + "\r\n").encode())
                os._exit(127)
        os.close(start_read)
        os.set_blocking(self.fd, False)
        resize(self.fd, 24, 80)
        self.pending = bytearray()
        server.selector.register(self.fd, selectors.EVENT_READ, self)

    def start(self):
        if self.start_fd is not None:
            os.write(self.start_fd, b"1")
            os.close(self.start_fd)
            self.start_fd = None

    def describe(self):
        if self.sequence:
            try:
                self.cwd = os.readlink("/proc/" + str(self.pid) + "/cwd")
            except OSError:
                pass
        return dict(terminal_id=self.id, pid=self.pid, cwd=self.cwd,
                    running=self.exit_code is None, exit_code=self.exit_code)


class Client:
    def __init__(self, sock):
        self.sock = sock
        self.incoming = bytearray()
        self.outgoing = bytearray()
        self.terminal = None
        self.authenticated = False
        self.close_after_write = False


class Server:
    def __init__(self, config):
        self.workspace = config["workspace_id"]
        self.token = config["token"]
        self.relay = config["relay"]
        self.relay_token = config["relay_token"]
        self.digest = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
        self.root = runtime(self.workspace)
        self.path = self.root / "daemon.sock"
        self.selector = selectors.DefaultSelector()
        self.terminals = {}
        self.closing = False
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(self.path))
        os.chmod(self.path, 0o600)
        self.listener.listen(32)
        self.listener.setblocking(False)
        self.selector.register(self.listener, selectors.EVENT_READ, None)

    def drop(self, client):
        if client.terminal:
            client.terminal.clients.discard(client)
        try:
            self.selector.unregister(client.sock)
        except (KeyError, ValueError):
            pass
        client.sock.close()

    def send(self, client, value):
        client.outgoing.extend(encoded(value))
        if len(client.outgoing) > MAX_FRAME * 2:
            self.drop(client)
            return
        self.selector.modify(client.sock, selectors.EVENT_READ | selectors.EVENT_WRITE, client)

    def result(self, client, result):
        self.send(client, dict(ok=True, result=result))

    def finish_terminal(self, terminal, wait=False):
        if terminal.start_fd is not None:
            os.close(terminal.start_fd)
            terminal.start_fd = None
        if terminal.fd >= 0:
            self.selector.unregister(terminal.fd)
            os.close(terminal.fd)
            terminal.fd = -1
        pid, status = os.waitpid(terminal.pid, 0 if wait else os.WNOHANG)
        if not pid:
            return
        terminal.exit_code = os.waitstatus_to_exitcode(status)
        for client in list(terminal.clients):
            self.send(client, dict(event="exit", exit_code=terminal.exit_code))
            client.close_after_write = True

    def request(self, client, value):
        if client.authenticated:
            terminal = client.terminal
            if not terminal:
                raise ValueError("connection already used")
            if value.get("event") == "input":
                if terminal.exit_code is not None or terminal.fd < 0:
                    raise ValueError("terminal input has closed")
                data = base64.b64decode(value["data"], validate=True)
                if len(terminal.pending) + len(data) > MAX_FRAME:
                    raise ValueError("terminal input queue exceeded")
                terminal.pending.extend(data)
                self.selector.modify(terminal.fd, selectors.EVENT_READ | selectors.EVENT_WRITE, terminal)
            elif value.get("event") == "resize":
                if terminal.exit_code is None and terminal.fd >= 0:
                    resize(terminal.fd, value["rows"], value["cols"])
            elif value.get("event") == "detach":
                self.drop(client)
            else:
                raise ValueError("unsupported attachment event")
            return
        if not isinstance(value.get("token"), str) or not hmac.compare_digest(value["token"], self.token):
            raise PermissionError("invalid daemon capability")
        client.authenticated = True
        params = value.get("params", {})
        method = value.get("method")
        if method == "status":
            self.result(client, dict(version=VERSION, sha256=self.digest, workspace_id=self.workspace,
                                     terminals=[t.describe() for t in self.terminals.values()]))
        elif method == "create":
            terminal_id = params["terminal_id"]
            if not isinstance(terminal_id, str) or not terminal_id or len(terminal_id) > 256:
                raise ValueError("invalid terminal ID")
            terminal = self.terminals.get(terminal_id)
            if terminal is None:
                terminal = Terminal(self, terminal_id, params.get("cwd"), params.get("command"))
                self.terminals[terminal_id] = terminal
            self.result(client, terminal.describe())
        elif method == "attach":
            terminal = self.terminals[params["terminal_id"]]
            client.terminal = terminal
            terminal.clients.add(client)
            self.result(client, terminal.describe())
            self.send(client, dict(event="directory", cwd=terminal.cwd))
            offset = params.get("offset")
            if offset is None:
                offset = terminal.sequence - len(terminal.backlog)
            if not isinstance(offset, int) or offset < 0 or offset > terminal.sequence:
                raise ValueError("invalid terminal output offset")
            terminal.start()
            start = max(offset, terminal.sequence - len(terminal.backlog))
            retained = terminal.backlog[start - (terminal.sequence - len(terminal.backlog)):]
            if retained:
                self.send(client, dict(event="output", offset=start, data=base64.b64encode(retained).decode()))
            if terminal.exit_code is not None:
                self.send(client, dict(event="exit", exit_code=terminal.exit_code))
                client.close_after_write = True
        elif method == "close-terminal":
            terminal = self.terminals.pop(params["terminal_id"])
            if terminal.exit_code is None:
                kill_session(terminal.pid)
                self.finish_terminal(terminal, wait=True)
            self.result(client, dict(closed=True))
        elif method == "close":
            for terminal in self.terminals.values():
                if terminal.exit_code is None:
                    kill_session(terminal.pid)
                    self.finish_terminal(terminal, wait=True)
            self.result(client, dict(closed=True))
            self.closing = True
        else:
            raise ValueError("unsupported daemon method")
        if method != "attach":
            client.close_after_write = True

    def run(self):
        try:
            while True:
                for key, events in self.selector.select(0.5):
                    item = key.data
                    if item is None:
                        sock, _ = self.listener.accept()
                        sock.setblocking(False)
                        self.selector.register(sock, selectors.EVENT_READ, Client(sock))
                    elif isinstance(item, Terminal):
                        if item.exit_code is not None:
                            continue
                        if events & selectors.EVENT_WRITE:
                            try:
                                count = os.write(item.fd, item.pending)
                                del item.pending[:count]
                                if not item.pending:
                                    self.selector.modify(item.fd, selectors.EVENT_READ, item)
                            except BlockingIOError:
                                pass
                            except OSError:
                                self.finish_terminal(item)
                                continue
                        if events & selectors.EVENT_READ:
                            try:
                                data = os.read(item.fd, 65536)
                            except BlockingIOError:
                                continue
                            except OSError as exc:
                                if exc.errno != errno.EIO:
                                    raise
                                data = b""
                            if not data:
                                self.finish_terminal(item)
                                continue
                            item.backlog.extend(data)
                            if len(item.backlog) > BACKLOG:
                                del item.backlog[:-BACKLOG]
                            packet = dict(event="output", offset=item.sequence, data=base64.b64encode(data).decode())
                            item.sequence += len(data)
                            for client in list(item.clients):
                                self.send(client, packet)
                    else:
                        try:
                            if events & selectors.EVENT_READ:
                                data = item.sock.recv(65536)
                                if not data:
                                    self.drop(item)
                                    continue
                                item.incoming.extend(data)
                                if len(item.incoming) > MAX_FRAME:
                                    raise ValueError("oversized protocol frame")
                                while b"\n" in item.incoming:
                                    line, _, remaining = item.incoming.partition(b"\n")
                                    item.incoming = bytearray(remaining)
                                    self.request(item, json.loads(line))
                                    if item.sock.fileno() < 0:
                                        break
                            if events & selectors.EVENT_WRITE and item.sock.fileno() >= 0:
                                count = item.sock.send(item.outgoing)
                                del item.outgoing[:count]
                                if not item.outgoing:
                                    if item.close_after_write:
                                        self.drop(item)
                                    else:
                                        self.selector.modify(item.sock, selectors.EVENT_READ, item)
                        except (BrokenPipeError, ConnectionResetError):
                            self.drop(item)
                        except Exception as exc:
                            if item.sock.fileno() >= 0:
                                self.send(item, dict(ok=False, error=dict(code=type(exc).__name__, message=str(exc))))
                                item.close_after_write = True
                for terminal in self.terminals.values():
                    if terminal.fd < 0 and terminal.exit_code is None:
                        self.finish_terminal(terminal)
                    previous_cwd = terminal.cwd
                    terminal.describe()
                    if terminal.cwd != previous_cwd:
                        for client in list(terminal.clients):
                            self.send(client, dict(event="directory", cwd=terminal.cwd))
                if self.closing and not any(isinstance(k.data, Client) and k.data.outgoing for k in self.selector.get_map().values()):
                    break
        finally:
            self.listener.close()
            self.path.unlink(missing_ok=True)


def start(config):
    root = runtime(config["workspace_id"])
    with open(root / "start.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = root / "daemon.sock"
        try:
            result = rpc(path, config["token"], "status")
            if result["version"] != VERSION or result.get("sha256") != hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest():
                raise RuntimeError("remote daemon version mismatch; close the old workspace explicitly before upgrading")
            return result
        except (FileNotFoundError, ConnectionRefusedError):
            path.unlink(missing_ok=True)
        log = open(root / "daemon.log", "ab", buffering=0)
        process = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()), "--serve"],
                                   stdin=subprocess.PIPE, stdout=log, stderr=log, start_new_session=True)
        process.stdin.write(encoded(config))
        process.stdin.close()
        log.close()
        for _ in range(100):
            try:
                return rpc(path, config["token"], "status")
            except (FileNotFoundError, ConnectionRefusedError):
                if process.poll() is not None:
                    raise RuntimeError("remote daemon failed to start; inspect " + str(root / "daemon.log"))
                time.sleep(0.05)
        raise TimeoutError("remote daemon did not become ready")


def bridge(workspace):
    # Read the handshake without buffering following input/resize packets.
    stdin = os.fdopen(sys.stdin.fileno(), "rb", buffering=0, closefd=False)
    request = read_frame(stdin)
    attached = request.get("method") == "attach"
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(str(runtime(workspace) / "daemon.sock"))
        sock.sendall(encoded(request))
        input_open = True
        while True:
            ready, _, _ = select.select([sock, stdin] if input_open else [sock], [], [])
            if sock in ready:
                data = sock.recv(65536)
                if not data:
                    return
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            if stdin in ready:
                data = os.read(stdin.fileno(), 65536)
                if not data:
                    if attached:
                        return
                    input_open = False
                else:
                    sock.sendall(data)


def hook_arguments(arguments, fields):
    positional = []
    options = {}
    index = 0
    while index < len(arguments):
        item = arguments[index]
        if not item.startswith("--"):
            positional.append(item)
            index += 1
            continue
        name, separator, inline = item[2:].partition("=")
        if name not in fields:
            raise ValueError("unsupported remote option: --" + name)
        if separator:
            options[name.replace("-", "_")] = inline
            index += 1
            continue
        index += 1
        if index >= len(arguments):
            raise ValueError("missing value for remote option: --" + name)
        options[name.replace("-", "_")] = arguments[index]
        index += 1
    return positional, options


def hook(arguments):
    if not arguments:
        raise ValueError("usage: clm notify TITLE [BODY] | status TEXT | progress PERCENT|clear | log TEXT [LEVEL] | hook EVENT | request JSON")
    method = arguments[0]
    if method == "request":
        request = json.loads(arguments[1])
        method, params = request["method"], request.get("params", {})
    elif method == "notify":
        positional, params = hook_arguments(
            arguments[1:], {"title", "subtitle", "body", "level"})
        if positional:
            params.setdefault("title", positional.pop(0))
        if positional:
            params.setdefault("body", positional.pop(0))
        if positional or "title" not in params:
            raise ValueError("notify requires a title and optional body")
    elif method == "status":
        positional, params = hook_arguments(
            arguments[1:], {"text", "key", "icon", "color"})
        if positional:
            params.setdefault("text", positional.pop(0))
        if positional or "text" not in params:
            raise ValueError("status requires text")
    elif method == "progress":
        positional, params = hook_arguments(arguments[1:], {"label"})
        if len(positional) != 1:
            raise ValueError("progress requires one percentage or clear")
        params["value"] = None if positional[0] == "clear" else int(positional[0])
    elif method == "log":
        positional, params = hook_arguments(arguments[1:], {"text", "level"})
        if positional:
            params.setdefault("text", positional.pop(0))
        if positional:
            params.setdefault("level", positional.pop(0))
        if positional or "text" not in params:
            raise ValueError("log requires text and optional level")
    elif method == "hook":
        positional, params = hook_arguments(
            arguments[1:], {"event", "key", "icon", "color", "directory"})
        if positional:
            params.setdefault("event", positional.pop(0))
        if positional or "event" not in params:
            raise ValueError("hook requires an event")
    else:
        raise ValueError("remote helper supports notify, status, progress, log, hook, and request only")
    params["terminal_id"] = os.environ["COLM_TERMINAL_ID"]
    result = rpc(os.environ["COLM_REMOTE_RELAY"], os.environ["COLM_REMOTE_CAPABILITY"], method, **params)
    return result


def main():
    os.umask(0o077)
    mode = sys.argv[1]
    if mode == "--version":
        return {"version": VERSION, "sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()}
    if mode == "--start":
        return start(read_frame(sys.stdin.buffer))
    if mode == "--serve":
        Server(read_frame(sys.stdin.buffer)).run()
        return None
    if mode == "--bridge":
        bridge(sys.argv[2])
        return None
    if mode == "--hook":
        return hook(sys.argv[2:])
    raise ValueError("unknown helper mode")


if __name__ == "__main__":
    try:
        result = main()
        if result is not None:
            print(json.dumps({"ok": True, "result": result}))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": {"code": type(exc).__name__, "message": str(exc)}}))
        sys.exit(1)
