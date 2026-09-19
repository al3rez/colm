"""Native regression: COLM_TEST_SOCKET=/path/to/socket python3 src/apprt/gtk/test_browser.py.

Uses an explicitly selected running Colm instance; creates and closes only its own
workspaces. COLM_BINARY may select an unregistered build.
"""
import http.server
import json
import os
import subprocess
import threading
import unittest


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'''<!doctype html><title>Colm regression</title>
<label>Name<input id="name"></label><button onclick="document.querySelector('#result').textContent=document.querySelector('#name').value">Apply</button><output id="result"></output>'''
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


@unittest.skipUnless(os.environ.get("COLM_TEST_SOCKET"), "select an explicit test app endpoint")
class NativeBrowserTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.uri = "http://127.0.0.1:" + str(cls.server.server_port) + "/"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.thread.join()
        cls.server.server_close()

    def setUp(self):
        self.workspaces = []

    def tearDown(self):
        for workspace in self.workspaces:
            self.call("workspace.close", workspace_id=workspace, force=True)

    def call(self, method, error=False, **params):
        env = {**os.environ, "COLM_SOCKET": os.environ["COLM_TEST_SOCKET"]}
        result = subprocess.run([os.environ.get("COLM_BINARY", "clm"),
                                 "ctl", "request", json.dumps(dict(method=method, params=params))],
                                env=env, capture_output=True, text=True, timeout=10)
        response = json.loads(result.stdout)
        self.assertEqual(response["ok"], not error, response)
        self.assertEqual(result.returncode, 1 if error else 0, response)
        return response["error"] if error else response["result"]

    def pane(self):
        workspace = self.call("workspace.create", name="Browser regression")["workspace"]["workspace_id"]
        self.workspaces.append(workspace)
        browser = self.call("browser.create", workspace_id=workspace)["browser_id"]
        target = dict(workspace_id=workspace, browser_id=browser)
        self.call("browser.navigate", **target, uri=self.uri)
        return target

    def test_snapshot_references_survive_async_calls_but_not_new_snapshots(self):
        target = self.pane()
        snapshot = self.call("browser.snapshot", **target)
        field = next(e["ref"] for e in snapshot["elements"] if e["tag"] == "input")
        button = next(e["ref"] for e in snapshot["elements"] if e["tag"] == "button")
        self.call("browser.fill", **target, generation=snapshot["generation"], ref=field, value="retained world")
        self.call("browser.click", **target, generation=snapshot["generation"], ref=button)
        result = self.call("browser.evaluate", **target, script="document.querySelector('#result').textContent")
        self.assertEqual(result["value"], "retained world")
        self.call("browser.snapshot", **target)
        failure = self.call("browser.fill", error=True, **target, generation=snapshot["generation"], ref=field, value="stale")
        self.assertIn("stale_reference", failure["message"])
        self.call("browser.evaluate", error=True, **target, script="new Promise(() => {})", timeout_ms=25)
        self.assertEqual(self.call("browser.evaluate", **target, script="document.querySelector('#result').textContent")["value"], "retained world")
        self.call("browser.navigate", **target, uri="about:blank")
        self.call("browser.click", error=True, **target, generation=snapshot["generation"], ref=button)

    def test_workspace_storage_isolation(self):
        first = self.pane()
        self.call("browser.evaluate", **first, script="document.cookie='private=secret';localStorage.setItem('private','secret');true")
        second = self.pane()
        result = self.call("browser.evaluate", **second, script="({cookie:document.cookie,value:localStorage.getItem('private')})")
        self.assertEqual(result["value"], dict(cookie="", value=None))


if __name__ == "__main__":
    unittest.main()
