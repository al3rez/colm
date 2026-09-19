"""Focused trust-boundary regressions; run with python3 -m unittest discover -s src/remote."""
import io
import json
import os
import pathlib
import shlex
import subprocess
import socket
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

import manager
import helper


class RelayBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.state = dict(workspace_id="remote-workspace", terminals=["remote-terminal"],
                          relay_token="remote-secret", capability="local-secret")

    def request(self, method="notify", **params):
        return dict(token="remote-secret", method=method, params=params)

    def test_remote_secret_cannot_authorize_local_privileged_methods(self):
        for method in ("terminal.send", "terminal.close", "workspace.close", "browser.evaluate", "upload"):
            with self.subTest(method=method), self.assertRaises(PermissionError):
                manager.relay_request(self.state, self.request(method))
        with self.assertRaises(PermissionError):
            manager.relay_request(self.state, dict(token="wrong", method="notify", params={}))

    def test_foreign_target_and_parameter_smuggling_are_rejected(self):
        for params in (dict(workspace_id="other"), dict(terminal_id="unrelated-terminal"),
                       dict(capability="local-secret"), dict(endpoint="/tmp/other.sock"),
                       dict(path="/home/user/private")):
            with self.subTest(params=params), self.assertRaises(PermissionError):
                manager.relay_request(self.state, self.request(**params))

    def test_allowed_hook_is_scoped_and_uses_separate_local_capability(self):
        request = self.request("status", text="working", terminal_id="remote-terminal")
        result = manager.relay_request(self.state, request)
        self.assertEqual(result["params"]["workspace_id"], "remote-workspace")
        self.assertEqual(result["params"]["terminal_id"], "remote-terminal")
        self.assertEqual(result["capability"], "local-secret")
        self.assertNotIn("remote-secret", json.dumps(result))

    def test_progress_rejects_nonfinite_boolean_and_out_of_range_values(self):
        for value in (float("nan"), float("inf"), True, -1, 101, "12", 0.5):
            with self.subTest(value=value), self.assertRaises(ValueError):
                manager.relay_request(self.state, self.request("progress", value=value))
        self.assertEqual(manager.relay_request(self.state, self.request("progress", value=None))["params"]["value"], None)

    def test_rich_agent_metadata_is_scoped_by_closed_schemas(self):
        notification = manager.relay_request(
            self.state, self.request("notify", title="Done", subtitle="Agent",
                                     body="Ready", level="warning"))
        self.assertEqual(notification["method"], "notification.create")
        self.assertEqual(notification["params"]["subtitle"], "Agent")

        ports = manager.relay_request(
            self.state, self.request("surface.report_ports", ports=[3000, 8080]))
        self.assertEqual(ports["params"]["workspace_id"], "remote-workspace")
        with self.assertRaises(ValueError):
            manager.relay_request(
                self.state, self.request("surface.report_ports", ports=[0]))
        with self.assertRaises(ValueError):
            manager.relay_request(
                self.state, self.request("surface.report_git_branch",
                                         branch="main", dirty="yes"))

    def test_unterminated_and_oversized_frames_are_rejected(self):
        for raw in (b'{"method":"notify"}', b" " * (manager.MAX_FRAME + 1) + b"\n"):
            with self.assertRaises(ValueError):
                manager.read_frame(io.BytesIO(raw))



class RemoteHookTests(unittest.TestCase):
    def test_rich_notification_flags_reach_scoped_relay(self):
        environment = {
            "COLM_TERMINAL_ID": "terminal",
            "COLM_REMOTE_RELAY": "/relay",
            "COLM_REMOTE_CAPABILITY": "secret",
        }
        with mock.patch.dict(os.environ, environment), \
             mock.patch.object(helper, "rpc", return_value={"ok": True}) as rpc:
            helper.hook([
                "notify", "Done", "--subtitle", "Agent",
                "--body=Ready", "--level", "warning",
            ])
        self.assertEqual(rpc.call_args.args[2], "notify")
        self.assertEqual(rpc.call_args.kwargs["subtitle"], "Agent")
        self.assertEqual(rpc.call_args.kwargs["terminal_id"], "terminal")


class SSHConfigurationTests(unittest.TestCase):
    def state(self, forward_agent=None):
        return dict(control_path="/tmp/control", host="example.test",
                    forward_agent=forward_agent)

    def test_agent_forwarding_preserves_config_unless_explicitly_overridden(self):
        inherited = manager.ssh_args(self.state())
        self.assertNotIn("-A", inherited)
        self.assertNotIn("-a", inherited)
        self.assertIn("-A", manager.ssh_args(self.state(True)))
        self.assertIn("-a", manager.ssh_args(self.state(False)))

    def test_reconnect_is_capped_and_reports_parked_state(self):
        with mock.patch.object(manager, "connect", side_effect=RuntimeError("offline")) as connect, \
             mock.patch.object(manager.time, "sleep"), \
             mock.patch.object(manager, "local_rpc") as report:
            with self.assertRaisesRegex(RuntimeError, "parked after 3 attempts"):
                manager.connect_with_retries(self.state())
        self.assertEqual(connect.call_count, 3)
        self.assertIn("notification.create",
                      [call.args[1] for call in report.call_args_list])

    def test_mosh_capability_failure_falls_back_to_managed_ssh(self):
        state = self.state()
        state.update(terminal_transport="mosh", workspace_id="workspace")
        with mock.patch.object(manager.shutil, "which", return_value=None):
            manager.configure_terminal_transport(state)
        self.assertEqual(state["effective_terminal_transport"], "ssh")
        self.assertIn("not installed", state["transport_fallback"])
        self.assertIn("--attach", manager.terminal_command(state, "terminal"))

        state["effective_terminal_transport"] = "mosh"
        self.assertIn("--mosh", manager.terminal_command(state, "terminal"))

        state.update(terminal_profile="tmux", terminal_tmux_session="review")
        command = manager.profile_command(state, "printf ready")
        self.assertEqual(command, "printf ready\nexec tmux new-session -A -s review")

    def test_persisted_session_list_and_explicit_cleanup(self):
        with tempfile.TemporaryDirectory() as runtime, \
             mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}):
            state = dict(version=manager.VERSION, workspace_id="workspace",
                         terminals=["first", "second"])
            manager.save(state)

            def remote_rpc(_state, method, **params):
                if method == "status":
                    return dict(terminals=[
                        dict(terminal_id="first", running=True),
                        dict(terminal_id="second", running=False),
                    ])
                self.assertEqual(method, "close-terminal")
                return dict(closed=True, terminal_id=params["terminal_id"])

            with mock.patch.object(manager, "connected", return_value=True), \
                 mock.patch.object(manager, "connect"), \
                 mock.patch.object(manager, "remote_rpc", side_effect=remote_rpc):
                listed = manager.dispatch(dict(
                    method="session-list", params=dict(workspace_id="workspace")))
                self.assertEqual([item["terminal_id"] for item in listed],
                                 ["first", "second"])
                removed = manager.dispatch(dict(
                    method="session-cleanup",
                    params=dict(workspace_id="workspace", all=True)))
            self.assertEqual(removed["removed"], ["first", "second"])
            self.assertEqual(manager.load("workspace")["terminals"], [])

class UploadBoundaryTests(unittest.TestCase):
    def test_truncated_upload_never_replaces_existing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "existing"
            destination.write_bytes(b"keep me")
            result = subprocess.run([sys.executable, "-c", manager.UPLOAD, str(destination), "384", "100"],
                                    input=b"truncated", capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(destination.read_bytes(), b"keep me")
            self.assertEqual(set(pathlib.Path(directory).iterdir()), {destination})

    def test_remote_shell_metacharacters_are_literal_destination_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "file ' ; $(touch INJECTED)\nend"
            payload = b"binary\x00content\n"
            command = shlex.join([sys.executable, "-c", manager.UPLOAD, str(destination), "384", str(len(payload))])
            result = subprocess.run(["/bin/sh", "-c", command], input=payload, capture_output=True, cwd=directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(destination.read_bytes(), payload)
            self.assertFalse((pathlib.Path(directory) / "INJECTED").exists())

    def test_download_stream_preserves_binary_content(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "remote"
            payload = b"download\x00payload\n"
            source.write_bytes(payload)
            result = subprocess.run(
                [sys.executable, "-c", manager.DOWNLOAD, str(source)],
                capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, payload)


class AttachmentLifecycleTests(unittest.TestCase):
    def test_initial_command_waits_for_attach_and_never_replays(self):
        workspace = "regression-" + uuid.uuid4().hex
        token = uuid.uuid4().hex
        config = dict(workspace_id=workspace, token=token, relay="/unused",
                      relay_token="unused")
        root = helper.runtime(workspace)
        path = root / "daemon.sock"
        with tempfile.TemporaryDirectory() as directory:
            marker = pathlib.Path(directory) / "initial"
            process = subprocess.Popen([sys.executable, helper.__file__, "--serve"],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE,
                                       env={**os.environ, "SHELL": "/bin/sh", "HOME": directory})
            process.stdin.write(helper.encoded(config))
            process.stdin.close()
            process.stdin = None
            try:
                deadline = time.monotonic() + 5
                while not path.exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        self.fail("helper did not become ready")
                    time.sleep(0.01)
                handshake = helper.encoded(dict(token=token, method="create",
                    params=dict(terminal_id="initial", cwd=directory,
                                command="printf once >> " + shlex.quote(str(marker)))))
                # --bridge must see EOF before a later attach starts the shell.
                created = subprocess.run([sys.executable, helper.__file__, "--bridge", workspace],
                                         input=handshake, capture_output=True, timeout=5)
                self.assertEqual(created.returncode, 0, created.stderr)
                original = json.loads(created.stdout)["result"]
                self.assertFalse(marker.exists())
                for _ in range(2):
                    with socket.socket(socket.AF_UNIX) as attached:
                        attached.settimeout(5)
                        attached.connect(str(path))
                        attached.sendall(helper.encoded(dict(token=token, method="attach",
                                                            params=dict(terminal_id="initial"))))
                        with attached.makefile("rb") as stream:
                            response = helper.read_frame(stream)
                            self.assertEqual(response["result"]["pid"], original["pid"])
                            deadline = time.monotonic() + 5
                            while not marker.exists() or marker.read_text() != "once":
                                if time.monotonic() > deadline:
                                    self.fail("initial command did not run after attachment")
                                time.sleep(0.01)
                    self.assertEqual(marker.read_text(), "once")
                    self.assertTrue(helper.rpc(path, token, "status")["terminals"][0]["running"])
            finally:
                try:
                    if path.exists():
                        helper.rpc(path, token, "close")
                    process.communicate(timeout=5)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
                    path.unlink(missing_ok=True)
                    root.rmdir()


if __name__ == "__main__":
    unittest.main()
