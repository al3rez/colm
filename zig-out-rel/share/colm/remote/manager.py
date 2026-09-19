#!/usr/bin/env python3
"""Managed OpenSSH transport and scoped relay for Colm's persistent remote PTYs.

Public interface: manager.py '{"method":"prepare","params":{...}}', or one
newline-delimited request on stdin. Every call emits the standard ok/result or
ok/error envelope. Returned command strings launch this file's --attach mode.
No shell command is used to launch ssh/scp locally. Remote command arguments are
POSIX-quoted, and uploads stream directly to a remote Python atomic file writer.
"""
import base64
import fcntl
import hashlib
import hmac
import json
import os
import pathlib
import secrets
import select
import shlex
import signal
import socket
import shutil
import stat
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty

VERSION = 1
MAX_FRAME = 2 * 1024 * 1024
RELAY_METHODS = {
    "notify": "notification.create", "status": "status.set",
    "progress": "progress.set", "log": "log.append", "hook": "agent.hook",
    "notification.create": "notification.create",
    "status.set": "status.set", "status.clear": "status.clear",
    "progress.set": "progress.set", "progress.clear": "progress.clear",
    "log.append": "log.append", "log.clear": "log.clear",
    "agent.hook": "agent.hook",
    "surface.report_git_branch": "surface.report_git_branch",
    "surface.clear_git_branch": "surface.clear_git_branch",
    "surface.report_pr": "surface.report_pr",
    "surface.clear_pr": "surface.clear_pr",
    "surface.report_ports": "surface.report_ports",
    "surface.clear_ports": "surface.clear_ports",
}
RELAY_FIELDS = {
    "notification.create": {"title", "subtitle", "body", "level"},
    "status.set": {"text", "key", "icon", "color"},
    "status.clear": {"key"},
    "progress.set": {"value", "label"},
    "progress.clear": set(),
    "log.append": {"text", "level"},
    "log.clear": set(),
    "agent.hook": {"event", "directory", "key", "icon", "color"},
    "surface.report_git_branch": {"branch", "dirty"},
    "surface.clear_git_branch": set(),
    "surface.report_pr": {"number", "label", "url", "status", "branch"},
    "surface.clear_pr": set(),
    "surface.report_ports": {"ports"},
    "surface.clear_ports": set(),
}


def encoded(value):
    return (json.dumps(value, separators=(",", ":")) + "\n").encode()


def read_frame(stream):
    raw = stream.readline(MAX_FRAME + 1)
    if not raw or len(raw) > MAX_FRAME or not raw.endswith(b"\n"):
        raise ValueError("missing or oversized protocol frame")
    result = json.loads(raw)
    if not isinstance(result, dict):
        raise ValueError("request must be an object")
    return result


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise PermissionError("unsafe runtime directory: " + str(path))
    return path


def workspace_dir(workspace):
    if not isinstance(workspace, str) or not workspace or len(workspace) > 256:
        raise ValueError("workspace_id must be a nonempty string of at most 256 characters")
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        raise RuntimeError("XDG_RUNTIME_DIR is required")
    root = private_dir(pathlib.Path(runtime) / "colm")
    root = private_dir(root / "remote")
    return private_dir(root / hashlib.sha256(workspace.encode()).hexdigest()[:20])


def state_path(workspace):
    return workspace_dir(workspace) / "state.json"


def load(workspace):
    path = state_path(workspace)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise PermissionError("unsafe manager state permissions")
    value = json.loads(path.read_text())
    if value["version"] != VERSION or value["workspace_id"] != workspace:
        raise RuntimeError("manager state version or identity mismatch")
    return value


def save(state):
    path = state_path(state["workspace_id"])
    temporary = path.with_suffix(".tmp")
    with open(temporary, "w", opener=lambda p, flags: os.open(p, flags | os.O_NOFOLLOW, 0o600)) as stream:
        json.dump(state, stream)
    os.replace(temporary, path)


def ssh_environment():
    env = os.environ.copy()
    configured = env.get("SSH_ASKPASS")
    if not configured or pathlib.Path(configured).name == "false":
        for candidate in ("/usr/libexec/gcr4-ssh-askpass", "/usr/libexec/gcr-ssh-askpass",
                          "/usr/lib/ssh/ssh-askpass", "/usr/bin/ssh-askpass"):
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                env["SSH_ASKPASS"] = candidate
                break
    if env.get("SSH_ASKPASS") and (env.get("DISPLAY") or env.get("WAYLAND_DISPLAY")):
        env["SSH_ASKPASS_REQUIRE"] = "prefer"
    return env


def ssh_args(state, master=False):
    args = ["ssh", "-o", "ControlMaster=" + ("yes" if master else "no")]
    if state.get("ssh_config"):
        args += ["-F", state["ssh_config"]]
    if state.get("port"):
        args += ["-p", str(state["port"])]
    if state.get("identity"):
        args += ["-i", state["identity"]]
    # Preserve OpenSSH configuration by default. Explicit CLI overrides win
    # without discarding a configured agent socket inherited from the app.
    if state.get("forward_agent") is True:
        args += ["-A"]
    elif state.get("forward_agent") is False:
        args += ["-a"]
    args += ["-o", "ConnectTimeout=15", "-o", "ControlPath=" + state["control_path"]]
    return args


def ssh_run(state, arguments, data=None, timeout=30):
    command = ssh_args(state) + ["-T", "--", state["host"], shlex.join(arguments)]
    try:
        process = subprocess.run(command, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 timeout=timeout, env=ssh_environment())
    except subprocess.TimeoutExpired:
        raise TimeoutError("SSH command timed out") from None
    if process.returncode:
        raise RuntimeError("SSH command failed: " + process.stderr.decode(errors="replace").strip()[-4096:])
    return process.stdout


def local_rpc(state, method, **params):
    if not state.get("endpoint") or not state.get("capability"):
        return
    params["workspace_id"] = state["workspace_id"]
    try:
        with socket.socket(socket.AF_UNIX) as endpoint:
            endpoint.settimeout(3)
            endpoint.connect(state["endpoint"])
            endpoint.sendall(encoded(dict(method=method, params=params,
                                          capability=state["capability"])))
            with endpoint.makefile("rb") as stream:
                response = read_frame(stream)
        if not response.get("ok"):
            raise RuntimeError(response.get("error", {}).get("message",
                                                             "local relay request failed"))
    except (OSError, ValueError, RuntimeError):
        pass


def remote_rpc(state, method, **params):
    raw = ssh_run(state, ["python3", state["helper_path"], "--bridge", state["workspace_id"]],
                  encoded(dict(token=state["daemon_token"], method=method, params=params)))
    response = json.loads(raw)
    if not response.get("ok"):
        raise RuntimeError(response.get("error", {}).get("message", "remote helper request failed"))
    if method == "status" and (response["result"].get("version") != VERSION or response["result"].get("sha256") != state["helper_sha256"]):
        raise RuntimeError("remote daemon version mismatch")
    return response["result"]


def connected(state):
    result = subprocess.run(ssh_args(state) + ["-O", "check", "--", state["host"]],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
                            env=ssh_environment())
    return result.returncode == 0


def stop_transport(state):
    if connected(state):
        result = subprocess.run(ssh_args(state) + ["-O", "exit", "--", state["host"]],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
                                env=ssh_environment())
        if result.returncode:
            raise RuntimeError("could not disconnect SSH master: " + result.stderr.decode(errors="replace"))


INSTALL = r'''
import hashlib,json,os,pathlib,stat,sys
os.umask(0o077)
source=sys.stdin.buffer.read()
expected=sys.argv[1]
if hashlib.sha256(source).hexdigest()!=expected: raise RuntimeError('helper digest mismatch')
root=pathlib.Path.home()/'.local'/'share'/'colm'/'remote'/expected
root.mkdir(parents=True,mode=0o700,exist_ok=True)
info=root.lstat()
if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077: raise RuntimeError('unsafe helper directory')
path=root/'helper.py'
if path.exists():
 if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest()!=expected: raise RuntimeError('installed helper digest mismatch')
else:
 fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o700)
 with os.fdopen(fd,'wb') as out: out.write(source)
binpath=root/'bin'
binpath.mkdir(mode=0o700,exist_ok=True)
import shlex
wrapper='#!/bin/sh\nexec python3 '+shlex.quote(str(path))+' --hook "$@"\n'
cli=binpath/'clm'
if cli.is_symlink(): raise RuntimeError('unsafe helper CLI path')
fd=os.open(cli,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o700)
with os.fdopen(fd,'w') as out: out.write(wrapper)
run=pathlib.Path('/tmp')/('colm-'+str(os.getuid()))/hashlib.sha256(sys.argv[2].encode()).hexdigest()[:24]
run.mkdir(parents=True,mode=0o700,exist_ok=True)
for directory in [run.parent,run]:
 info=directory.lstat()
 if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077: raise RuntimeError('unsafe remote runtime directory')
print(json.dumps({'path':str(path),'relay':str(run/'relay.sock'),'sha256':expected}))
'''


def install_helper(state):
    source = pathlib.Path(__file__).with_name("helper.py").read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    result = json.loads(ssh_run(state, ["python3", "-c", INSTALL, digest, state["workspace_id"]], source))
    if result.get("sha256") != digest:
        raise RuntimeError("helper installation verification failed")
    for key in ("path", "relay"):
        value = result.get(key)
        if not isinstance(value, str) or not value.startswith("/") or any(c in value for c in (":", "\0", "\n", "\r")):
            raise RuntimeError("remote installer returned an unsafe path")
    state["helper_path"] = result["path"]
    state["remote_relay"] = result["relay"]
    result = json.loads(ssh_run(state, ["python3", state["helper_path"], "--version"]))
    if not result.get("ok") or result["result"] != dict(version=VERSION, sha256=digest):
        raise RuntimeError("remote helper version verification failed")
    state["helper_sha256"] = digest


def relay_request(state, request):
    token = request.get("token")
    if not isinstance(token, str) or not hmac.compare_digest(token, state["relay_token"]):
        raise PermissionError("invalid relay capability")
    method = RELAY_METHODS.get(request.get("method"))
    if method is None:
        raise PermissionError("method is not allowed by remote capability")
    params = request.get("params", {})
    if not isinstance(params, dict):
        raise ValueError("params must be an object")
    # Use a field allowlist, not a denylist: no files, arbitrary targets, or
    # capability/endpoint override can travel through the remote trust boundary.
    fields = RELAY_FIELDS[method]
    if set(params) - fields - {"workspace_id", "terminal_id"}:
        raise PermissionError("unsupported remote parameters")
    if "workspace_id" in params and params["workspace_id"] != state["workspace_id"]:
        raise PermissionError("remote workspace target mismatch")
    terminal = params.get("terminal_id")
    if terminal is not None and terminal not in state["terminals"]:
        raise PermissionError("remote terminal target mismatch")
    filtered = {key: params[key] for key in fields if key in params}
    for key, value in filtered.items():
        if key in {"value", "number", "dirty", "ports"}:
            continue
        if not isinstance(value, str):
            raise ValueError("remote text must be a string")
        if len(value.encode()) > 16384:
            raise ValueError("remote text exceeds limit")
    if method == "progress.set":
        value = filtered.get("value")
        if value is not None and (isinstance(value, bool) or not isinstance(value, int)
                                  or not 0 <= value <= 100):
            raise ValueError("progress must be an integer percentage between 0 and 100, or null")
    if "dirty" in filtered and not isinstance(filtered["dirty"], bool):
        raise ValueError("dirty must be a boolean")
    if "number" in filtered and (isinstance(filtered["number"], bool)
                                 or not isinstance(filtered["number"], int)
                                 or filtered["number"] < 1):
        raise ValueError("pull request number must be a positive integer")
    if "ports" in filtered:
        ports = filtered["ports"]
        if not isinstance(ports, list) or len(ports) > 128 or any(
                isinstance(port, bool) or not isinstance(port, int)
                or not 1 <= port <= 65535 for port in ports):
            raise ValueError("ports must contain at most 128 valid TCP ports")
    filtered["workspace_id"] = state["workspace_id"]
    if terminal is not None:
        filtered["terminal_id"] = terminal
    return dict(method=method, params=filtered, capability=state["capability"])


def relay_client(workspace, client):
    with client:
        try:
            client.settimeout(10)
            with client.makefile("rb") as stream:
                request = read_frame(stream)
            state = load(workspace)
            request = relay_request(state, request)
            if not state.get("endpoint") or not state.get("capability"):
                raise RuntimeError("local automation relay is not configured")
            with socket.socket(socket.AF_UNIX) as endpoint:
                endpoint.settimeout(10)
                endpoint.connect(state["endpoint"])
                endpoint.sendall(encoded(request))
                with endpoint.makefile("rb") as stream:
                    result = read_frame(stream)
            client.sendall(encoded(result))
        except Exception as exc:
            try:
                client.sendall(encoded(dict(ok=False, error=dict(code=type(exc).__name__, message=str(exc)))))
            except OSError:
                pass


def relay(workspace):
    state = load(workspace)
    path = state["relay_path"]
    with open(workspace_dir(workspace) / "relay.lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        pathlib.Path(path).unlink(missing_ok=True)
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(path)
            os.chmod(path, 0o600)
            listener.listen(16)
            listener.settimeout(2)
            # Bounded worker count prevents a compromised host spawning threads
            # without limit. Each authenticated request has a 10-second deadline.
            slots = threading.BoundedSemaphore(8)
            while state_path(workspace).exists():
                try:
                    client, _ = listener.accept()
                except socket.timeout:
                    continue
                if not slots.acquire(blocking=False):
                    client.close()
                    continue
                def serve(connection):
                    try:
                        relay_client(workspace, connection)
                    finally:
                        slots.release()
                threading.Thread(target=serve, args=(client,), daemon=True).start()
        pathlib.Path(path).unlink(missing_ok=True)


def ensure_relay(state):
    def probe():
        try:
            with socket.socket(socket.AF_UNIX) as sock:
                sock.connect(state["relay_path"])
            return True
        except (FileNotFoundError, ConnectionRefusedError):
            return False
    if probe():
        return
    root = workspace_dir(state["workspace_id"])
    with open(root / "relay.log", "ab") as log:
        process = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()), "--relay", state["workspace_id"]],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    for _ in range(100):
        if probe():
            return
        if process.poll() is not None:
            raise RuntimeError("scoped relay failed to start")
        time.sleep(0.02)
    raise TimeoutError("scoped relay did not become ready")


def connect(state):
    ensure_relay(state)
    if connected(state):
        return
    # sshd can retain the filesystem socket after transport loss. The client
    # StreamLocalBindUnlink option cannot configure the remote sshd. Remove only
    # this workspace's owned socket over a separately authenticated connection.
    ssh_run(state, ["python3", "-c", """
import os,stat,sys
path=sys.argv[1]
try: info=os.lstat(path)
except FileNotFoundError: pass
else:
 if not stat.S_ISSOCK(info.st_mode) or info.st_uid!=os.getuid():
  raise RuntimeError('unsafe stale remote relay path')
 os.unlink(path)
""", state["remote_relay"]])
    args = ssh_args(state, master=True) + ["-fNT", "-o", "ControlPersist=yes",
                             "-o", "ExitOnForwardFailure=yes", "-o", "StreamLocalBindUnlink=yes",
                             "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                             "-D", "127.0.0.1:" + str(state["socks_port"]),
                             "-R", state["remote_relay"] + ":" + state["relay_path"], "--", state["host"]]
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
                            env=ssh_environment())
    if result.returncode:
        raise RuntimeError("SSH transport setup failed: " + result.stderr.decode(errors="replace").strip()[-4096:])
    if not connected(state):
        raise RuntimeError("SSH master did not become ready")


def connect_with_retries(state, attempts=3):
    failure = None
    for attempt in range(1, attempts + 1):
        try:
            connect(state)
            local_rpc(state, "status.clear", key="remote")
            if attempt > 1:
                local_rpc(state, "log.append", text="Remote connection restored",
                          level="info")
            return
        except Exception as exc:
            failure = exc
            if attempt < attempts:
                delay = 2 ** (attempt - 1)
                detail = ("Remote connection failed; retry " + str(attempt)
                          + " in " + str(delay) + "s: " + str(exc))
                local_rpc(state, "status.set", key="remote", text=detail,
                          icon="network-offline-symbolic")
                local_rpc(state, "log.append", text=detail, level="warning")
                time.sleep(delay)
    detail = ("Remote connection parked after " + str(attempts)
              + " attempts: " + str(failure))
    local_rpc(state, "status.set", key="remote", text=detail,
              icon="network-offline-symbolic")
    local_rpc(state, "log.append", text=detail, level="error")
    local_rpc(state, "notification.create", title="Remote connection parked",
              body=detail, level="error")
    raise RuntimeError(detail) from failure
def start_daemon(state):
    config = dict(workspace_id=state["workspace_id"], token=state["daemon_token"],
                  relay=state["remote_relay"], relay_token=state["relay_token"])
    response = json.loads(ssh_run(state, ["python3", state["helper_path"], "--start"], encoded(config)))
    if not response.get("ok"):
        raise RuntimeError(response.get("error", {}).get("message", "remote daemon failed"))
    return response["result"]
def configure_terminal_transport(state):
    requested = state.get("terminal_transport", "ssh")
    state["effective_terminal_transport"] = requested
    state["transport_fallback"] = None
    if state.get("terminal_profile", "shell") == "tmux":
        try:
            ssh_run(state, ["/bin/sh", "-lc", "command -v tmux >/dev/null"])
        except Exception as exc:
            raise RuntimeError("Remote tmux capability probe failed: " + str(exc)) from exc
    if requested != "mosh":
        return
    client = shutil.which("mosh")
    if client is None:
        state["effective_terminal_transport"] = "ssh"
        state["transport_fallback"] = "Mosh client is not installed; using SSH"
        return
    probe = subprocess.run([client, "--help"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=5)
    if b"experimental-remote-ip" not in probe.stdout:
        state["effective_terminal_transport"] = "ssh"
        state["transport_fallback"] = "Mosh 1.4+ with --experimental-remote-ip is required; using SSH"
        return
    try:
        ssh_run(state, ["/bin/sh", "-lc", "command -v mosh-server >/dev/null"])
    except Exception as exc:
        state["effective_terminal_transport"] = "ssh"
        state["transport_fallback"] = "Remote mosh-server probe failed; using SSH: " + str(exc)


def profile_command(state, command=None):
    if state.get("terminal_profile", "shell") != "tmux":
        return command
    attach = "exec tmux new-session -A -s " + shlex.quote(
        state.get("terminal_tmux_session") or "main")
    return command + "\n" + attach if command else attach


def terminal_command(state, terminal_id):
    mode = state.get("effective_terminal_transport", state.get("terminal_transport", "ssh"))
    argument = "--mosh" if mode == "mosh" else "--attach"
    return shlex.join([sys.executable, str(pathlib.Path(__file__).resolve()),
                       argument, state["workspace_id"], terminal_id])


def public(state, terminal_id=None):
    result = dict(workspace_id=state["workspace_id"], host=state["host"],
                  proxy_uri="socks://127.0.0.1:" + str(state["socks_port"]),
                  remote_cwd=state.get("cwd"), helper_version=VERSION,
                  terminal_transport=state.get("terminal_transport", "ssh"),
                  effective_terminal_transport=state.get(
                      "effective_terminal_transport", state.get("terminal_transport", "ssh")),
                  terminal_profile=state.get("terminal_profile", "shell"),
                  terminal_tmux_session=state.get("terminal_tmux_session"),
                  transport_fallback=state.get("transport_fallback"))
    if terminal_id is not None:
        result["terminal_id"] = terminal_id
        result["command"] = terminal_command(state, terminal_id)
    return result


UPLOAD = r'''
import json,os,pathlib,shutil,sys,tempfile
path=pathlib.Path(sys.argv[1]).expanduser()
if not path.is_absolute(): raise ValueError('upload destination must be an absolute remote path')
fd,temporary=tempfile.mkstemp(prefix='.colm-upload-',dir=str(path.parent))
try:
 with os.fdopen(fd,'wb') as out:
  shutil.copyfileobj(sys.stdin.buffer,out)
  out.flush(); os.fsync(out.fileno())
 if os.stat(temporary).st_size!=int(sys.argv[3]): raise RuntimeError('upload transport ended before the expected byte count')
 os.chmod(temporary,int(sys.argv[2]))
 os.replace(temporary,path)
 print(json.dumps({'destination':str(path),'bytes':path.stat().st_size}))
finally:
 if os.path.exists(temporary): os.unlink(temporary)
'''


def upload(state, params):
    source = pathlib.Path(params["source"]).expanduser()
    destination = params["destination"]
    if not isinstance(destination, str) or "\0" in destination:
        raise ValueError("invalid upload destination")
    with source.open("rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("upload source must be a regular file")
        args = ssh_args(state) + ["-T", "--", state["host"],
                                  shlex.join(["python3", "-c", UPLOAD, destination, str(stat.S_IMODE(info.st_mode) & 0o777), str(info.st_size)])]
        process = subprocess.run(args, stdin=stream, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 timeout=300, env=ssh_environment())
    if process.returncode:
        raise RuntimeError("upload failed: " + process.stderr.decode(errors="replace")[-4096:])
    return json.loads(process.stdout)

DOWNLOAD = r'''
import os,pathlib,shutil,stat,sys
path=pathlib.Path(sys.argv[1]).expanduser()
with path.open('rb') as source:
 info=os.fstat(source.fileno())
 if not stat.S_ISREG(info.st_mode): raise ValueError('download source must be a regular file')
 shutil.copyfileobj(source,sys.stdout.buffer)
'''


def download(state, params):
    source = params["source"]
    if not isinstance(source, str) or "\0" in source:
        raise ValueError("invalid download source")
    destination = pathlib.Path(params["destination"]).expanduser()
    if not destination.is_absolute():
        raise ValueError("download destination must be an absolute local path")
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".colm-download-", dir=str(destination.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            args = ssh_args(state) + ["-T", "--", state["host"],
                                      shlex.join(["python3", "-c", DOWNLOAD, source])]
            process = subprocess.run(args, stdout=stream, stderr=subprocess.PIPE,
                                     timeout=300, env=ssh_environment())
            stream.flush()
            os.fsync(stream.fileno())
        if process.returncode:
            raise RuntimeError("download failed: "
                               + process.stderr.decode(errors="replace")[-4096:])
        os.replace(temporary, destination)
        return dict(source=source, destination=str(destination),
                    bytes=destination.stat().st_size)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)



def dispatch(request):
    method = request["method"]
    params = request.get("params", {})
    workspace = params["workspace_id"]
    root = workspace_dir(workspace)
    with open(root / "manager.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if method == "prepare":
            new_workspace = not state_path(workspace).exists()
            if state_path(workspace).exists():
                state = load(workspace)
                if state["host"] != params["host"]:
                    raise ValueError("workspace already belongs to a different remote host")
                if params.get("endpoint") is not None:
                    state["endpoint"] = params["endpoint"]
                if params.get("capability") is not None:
                    state["capability"] = params["capability"]
            else:
                host = params["host"]
                if not isinstance(host, str) or not host or host.startswith("-") or any(c.isspace() or c == "\0" for c in host):
                    raise ValueError("invalid SSH host or alias")
                port = params.get("port")
                if port is not None and (isinstance(port, bool) or not 1 <= int(port) <= 65535):
                    raise ValueError("SSH port must be between 1 and 65535")
                with socket.socket() as probe:
                    probe.bind(("127.0.0.1", 0))
                    socks_port = probe.getsockname()[1]
                forward_agent = None
                if params.get("forward_agent"):
                    forward_agent = True
                elif params.get("no_forward_agent"):
                    forward_agent = False
                transport = params.get("transport", "ssh")
                profile = params.get("profile", "shell")
                session = params.get("session")
                if transport not in ("ssh", "mosh") or profile not in ("shell", "tmux"):
                    raise ValueError("invalid terminal transport or profile")
                if profile == "tmux":
                    session = session or "main"
                    if not isinstance(session, str) or not session or len(session) > 128 or any(c in session for c in ".:"):
                        raise ValueError("invalid tmux session name")
                elif session is not None:
                    raise ValueError("tmux session requires the tmux terminal profile")
                state = dict(version=VERSION, workspace_id=workspace, host=host, port=port,
                             identity=params.get("identity"), ssh_config=params.get("ssh_config"),
                             forward_agent=forward_agent, cwd=params.get("cwd"), command=params.get("command"),
                             terminal_transport=transport, terminal_profile=profile,
                             terminal_tmux_session=session, mosh_initial_started=False,
                             control_path=str(root / "ssh"), relay_path=str(root / "relay.sock"),
                             socks_port=socks_port, daemon_token=secrets.token_hex(32), relay_token=secrets.token_hex(32),
                             endpoint=params.get("endpoint"), capability=params.get("capability"), terminals=[],
                             initial_terminal_id=params.get("terminal_id") or "terminal-" + secrets.token_hex(12),
                             initial_created=False, manual_disconnect=False)
                install_helper(state)
            terminal_id = params.get("terminal_id") or state["initial_terminal_id"]
            if state["initial_created"] and terminal_id == state["initial_terminal_id"] and terminal_id not in state["terminals"]:
                raise ValueError("initial terminal was explicitly closed; create an additional terminal instead")
            # Register the terminal before its first attachment can emit hooks.
            if terminal_id not in state["terminals"]:
                state["terminals"].append(terminal_id)
            save(state)
            daemon_attempted = False
            try:
                connect_with_retries(state)
                configure_terminal_transport(state)
                daemon_attempted = True
                start_daemon(state)
                initial_command = state.get("command") if terminal_id == state["initial_terminal_id"] and not state["initial_created"] else None
                if state.get("effective_terminal_transport", "ssh") == "mosh":
                    terminal = dict(terminal_id=terminal_id, pid=None,
                                    cwd=state.get("cwd") or "~", running=True, exit_code=None)
                else:
                    terminal = remote_rpc(
                        state, "create", terminal_id=terminal_id, cwd=state.get("cwd"),
                        command=profile_command(state, initial_command))
                if terminal_id == state["initial_terminal_id"]:
                    state["initial_created"] = True
                save(state)
                result = public(state, terminal_id)
                result["terminal"] = terminal
                return result
            except Exception as failure:
                if new_workspace:
                    try:
                        if daemon_attempted:
                            remote_rpc(state, "close")
                        stop_transport(state)
                        state_path(workspace).unlink(missing_ok=True)
                    except Exception as cleanup:
                        raise RuntimeError(str(failure) + "; cleanup failed for workspace " + workspace
                                           + ": " + str(cleanup) + "; retained recovery state: "
                                           + str(state_path(workspace))) from failure
                raise
        if method == "close" and not state_path(workspace).exists():
            return dict(workspace_id=workspace, closed=True)
        state = load(workspace)
        if method == "disconnect":
            state["manual_disconnect"] = True
            save(state)
            stop_transport(state)
            return dict(workspace_id=workspace, connected=False, sessions_preserved=True)
        if method == "reconnect":
            state["manual_disconnect"] = False
            save(state)
            connect_with_retries(state)
            status = remote_rpc(state, "status")
            result = public(state)
            result.update(connected=True, terminals=status["terminals"])
            return result
        if method == "status":
            result = public(state)
            result["connected"] = connected(state)
            if state.get("effective_terminal_transport", "ssh") == "mosh":
                result["terminals"] = [
                    dict(terminal_id=t, running=None) for t in state["terminals"]]
            else:
                result["terminals"] = remote_rpc(state, "status")["terminals"] if result["connected"] else [
                    dict(terminal_id=t, running=None) for t in state["terminals"]]
            return result
        if method == "session-list":
            if state.get("effective_terminal_transport", "ssh") == "mosh":
                return [dict(terminal_id=t, running=None) for t in state["terminals"]]
            status = remote_rpc(state, "status") if connected(state) else None
            known = {item["terminal_id"]: item for item in status["terminals"]} if status else {}
            return [known.get(terminal_id, dict(terminal_id=terminal_id, running=None))
                    for terminal_id in state["terminals"]]
        if method == "session-attach":
            terminal_id = params["terminal_id"]
            if terminal_id not in state["terminals"]:
                raise ValueError("remote terminal session does not exist")
            connect(state)
            if state.get("effective_terminal_transport", "ssh") == "mosh":
                terminal = dict(terminal_id=terminal_id, running=None,
                                cwd=state.get("cwd") or "~")
            else:
                status = remote_rpc(state, "status")
                terminal = next((item for item in status["terminals"]
                                 if item["terminal_id"] == terminal_id), None)
                if terminal is None:
                    raise ValueError("remote terminal session is no longer available")
            result = public(state, terminal_id)
            result["terminal"] = terminal
            return result
        if method == "session-cleanup":
            connect(state)
            selected = list(state["terminals"]) if params.get("all") else [params["terminal_id"]]
            removed = []
            for terminal_id in selected:
                if terminal_id not in state["terminals"]:
                    raise ValueError("remote terminal session does not exist: " + terminal_id)
                if state.get("effective_terminal_transport", "ssh") != "mosh":
                    remote_rpc(state, "close-terminal", terminal_id=terminal_id)
                state["terminals"].remove(terminal_id)
                removed.append(terminal_id)
            save(state)
            return dict(workspace_id=workspace, removed=removed)
        if method == "terminal":
            connect(state)
            terminal_id = params["terminal_id"]
            if terminal_id not in state["terminals"]:
                state["terminals"].append(terminal_id)
            save(state)
            if state.get("effective_terminal_transport", "ssh") == "mosh":
                terminal = dict(terminal_id=terminal_id, running=None,
                                cwd=params.get("cwd", state.get("cwd")) or "~")
            else:
                terminal = remote_rpc(state, "create", terminal_id=terminal_id,
                                      cwd=params.get("cwd", state.get("cwd")),
                                      command=profile_command(state, params.get("command")))
            result = public(state, terminal_id)
            result["terminal"] = terminal
            return result
        if method == "upload":
            connect(state)
            return upload(state, params)
        if method == "download":
            connect(state)
            return download(state, params)
        if method == "close-terminal":
            terminal_id = params["terminal_id"]
            if state.get("effective_terminal_transport", "ssh") == "mosh":
                result = dict(closed=True, terminal_id=terminal_id)
            else:
                connect(state)
                result = remote_rpc(state, "close-terminal", terminal_id=terminal_id)
            state["terminals"].remove(terminal_id)
            save(state)
            return result
        if method == "close":
            connect(state)
            remote_rpc(state, "close")
            stop_transport(state)
            state_path(workspace).unlink()
            return dict(workspace_id=workspace, closed=True)
        raise ValueError("unsupported manager method")


def mosh_attach(workspace, terminal_id):
    root = workspace_dir(workspace)
    with open(root / "manager.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load(workspace)
        if terminal_id not in state["terminals"]:
            return 0
        if state.get("effective_terminal_transport") != "mosh":
            return attachment_loop(workspace, terminal_id)
        initial_command = None
        if terminal_id == state["initial_terminal_id"] and not state.get("mosh_initial_started"):
            initial_command = state.get("command")
            state["mosh_initial_started"] = True
            save(state)
    client = shutil.which("mosh")
    if client is None:
        raise RuntimeError("Mosh client disappeared; reconnect the workspace to use SSH fallback")
    helper_bin = str(pathlib.Path(state["helper_path"]).parent / "bin" / "clm")
    cwd = state.get("cwd") or "~"
    script = [
        'cd -- "$HOME"' if cwd == "~" else "cd -- " + shlex.quote(cwd),
        "export COLM_WORKSPACE_ID=" + shlex.quote(workspace),
        "export COLM_TERMINAL_ID=" + shlex.quote(terminal_id),
        "export COLM_REMOTE_RELAY=" + shlex.quote(state["remote_relay"]),
        "export COLM_REMOTE_CAPABILITY=" + shlex.quote(state["relay_token"]),
        "export COLM_REMOTE_CLI=" + shlex.quote(helper_bin),
        "export PATH=" + shlex.quote(str(pathlib.Path(helper_bin).parent)) + ":$PATH",
    ]
    if initial_command:
        script.append(initial_command)
    if state.get("terminal_profile") == "tmux":
        script.append("exec tmux new-session -A -s "
                      + shlex.quote(state.get("terminal_tmux_session") or "main"))
    else:
        script.append('exec "${SHELL:-/bin/sh}" -l')
    ssh_option = "--ssh=" + shlex.join(ssh_args(state))
    args = [client, "--experimental-remote-ip=remote", ssh_option, "--",
            state["host"], "/bin/sh", "-lc", "\n".join(script)]
    return subprocess.call(args, env=ssh_environment())


def attach_once(state, terminal_id, position):
    workspace = state["workspace_id"]
    # A multiplexed attach must not open its own fallback SSH connection after
    # an explicit disconnect; only reconnect is allowed to restore transport.
    args = ssh_args(state) + ["-o", "ProxyCommand=false", "-T", "--", state["host"], shlex.join(["python3", state["helper_path"], "--bridge", workspace])]
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               env=ssh_environment())
    incoming = bytearray()
    previous = termios.tcgetattr(sys.stdin) if os.isatty(sys.stdin.fileno()) else None
    need_resize = threading.Event()
    need_resize.set()
    old_handler = signal.signal(signal.SIGWINCH, lambda *_: need_resize.set())
    def send(value):
        process.stdin.write(encoded(value))
        process.stdin.flush()
    try:
        send(dict(token=state["daemon_token"], method="attach", params=dict(terminal_id=terminal_id, offset=position[0])))
        if previous is not None:
            tty.setraw(sys.stdin)
        while True:
            if need_resize.is_set():
                need_resize.clear()
                if os.isatty(sys.stdin.fileno()):
                    dimensions = os.get_terminal_size(sys.stdin.fileno())
                    send(dict(event="resize", rows=dimensions.lines, cols=dimensions.columns))
            ready, _, _ = select.select([sys.stdin.buffer, process.stdout], [], [], 0.2)
            if sys.stdin.buffer in ready:
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    send(dict(event="detach"))
                    return 0
                send(dict(event="input", data=base64.b64encode(data).decode()))
            if process.stdout in ready:
                data = os.read(process.stdout.fileno(), 65536)
                if not data:
                    return None
                incoming.extend(data)
                if len(incoming) > MAX_FRAME:
                    raise ValueError("oversized attachment frame")
                while b"\n" in incoming:
                    raw, _, remaining = incoming.partition(b"\n")
                    incoming = bytearray(remaining)
                    packet = json.loads(raw)
                    if packet.get("event") == "output":
                        data = base64.b64decode(packet["data"], validate=True)
                        offset = packet["offset"]
                        if position[0] is not None and offset > position[0]:
                            print("\r\nColm: output exceeded the retained reconnect buffer.\r", file=sys.stderr)
                        position[0] = offset + len(data)
                        sys.stdout.buffer.write(data)
                        sys.stdout.buffer.flush()
                    elif packet.get("event") == "directory":
                        # Only the local attach client knows this capability.
                        # Directory metadata never changes the local process cwd.
                        try:
                            with socket.socket(socket.AF_UNIX) as endpoint:
                                endpoint.settimeout(2)
                                endpoint.connect(state["endpoint"])
                                endpoint.sendall(encoded(dict(method="status.set", capability=state["capability"],
                                    params=dict(workspace_id=workspace, terminal_id=terminal_id, directory=packet["cwd"]))))
                                endpoint.recv(MAX_FRAME)
                        except (OSError, KeyError):
                            pass
                    elif packet.get("event") == "exit":
                        return max(0, min(255, packet.get("exit_code", 0)))
                    elif packet.get("ok") is False:
                        raise RuntimeError(packet["error"]["message"])
    except (BrokenPipeError, ConnectionResetError):
        return None
    finally:
        signal.signal(signal.SIGWINCH, old_handler)
        if previous is not None:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, previous)
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def attachment_loop(workspace, terminal_id):
    position = [None]
    waiting = False
    while True:
        try:
            state = load(workspace)
        except FileNotFoundError:
            return 0
        if terminal_id not in state["terminals"]:
            return 0
        if not connected(state):
            if state.get("manual_disconnect"):
                if not waiting:
                    print("\r\nColm: disconnected; remote session preserved. Waiting for workspace reconnect.\r", file=sys.stderr)
                    waiting = True
            else:
                if not waiting:
                    print("\r\nColm: connection lost; attempting automatic reconnect.\r", file=sys.stderr)
                    waiting = True
                try:
                    dispatch(dict(method="reconnect", params=dict(workspace_id=workspace)))
                    state = load(workspace)
                except Exception as exc:
                    print("\r\nColm: " + str(exc) + "\r", file=sys.stderr)
                    return 1
            if not connected(state):
                ready, _, _ = select.select([sys.stdin.buffer], [], [], 0.5)
                if ready:
                    try:
                        if not os.read(sys.stdin.fileno(), 65536):
                            return 0
                    except OSError:
                        return 0
                continue
        if waiting:
            print("\r\nColm: reconnecting to the preserved remote terminal.\r", file=sys.stderr)
        result = attach_once(state, terminal_id, position)
        if result is not None:
            return result
        waiting = False
        time.sleep(0.5)


def attach(workspace, terminal_id):
    previous = termios.tcgetattr(sys.stdin) if os.isatty(sys.stdin.fileno()) else None
    try:
        if previous is not None:
            tty.setraw(sys.stdin)
        return attachment_loop(workspace, terminal_id)
    finally:
        if previous is not None:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, previous)


def main():
    os.umask(0o077)
    if len(sys.argv) > 1 and sys.argv[1] in ("--attach", "--mosh"):
        try:
            if sys.argv[1] == "--mosh":
                return mosh_attach(sys.argv[2], sys.argv[3])
            return attach(sys.argv[2], sys.argv[3])
        except Exception as exc:
            print("Colm: " + str(exc), file=sys.stderr)
            return 1
    if len(sys.argv) > 1 and sys.argv[1] == "--relay":
        relay(sys.argv[2])
        return 0
    try:
        request = json.loads(sys.argv[1]) if len(sys.argv) > 1 else read_frame(sys.stdin.buffer)
        result = dispatch(request)
        print(json.dumps(dict(ok=True, result=result)))
        return 0
    except Exception as exc:
        print(json.dumps(dict(ok=False, error=dict(code=type(exc).__name__, message=str(exc)))))
        return 1


if __name__ == "__main__":
    sys.exit(main())
