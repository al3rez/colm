"""Native regression: COLM_TEST_SOCKET=/path/to/socket python3 src/apprt/gtk/test_ids.py.

Defends the documented handle contract: "kind:N" identifiers are stable for an
object's lifetime and are never list indexes. Before the ordinal fix, a
workspace reorder or close remapped every alias, so targeted commands
(including destructive ones) silently acted on neighbouring workspaces.

Uses an explicitly selected running Colm instance; creates and closes only its
own workspaces. COLM_BINARY may select an unregistered build.
"""
import json
import os
import subprocess
import unittest


@unittest.skipUnless(os.environ.get("COLM_TEST_SOCKET"), "select an explicit test app endpoint")
class StableHandleTests(unittest.TestCase):
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

    def workspace(self, name, window_id=None):
        params = dict(name=name) if window_id is None else dict(name=name, window_id=window_id)
        created = self.call("workspace.create", **params)
        self.workspaces.append(created["workspace"]["workspace_id"])
        return created["workspace"], created["terminal"]

    def name_of(self, workspace_id):
        return self.call("workspace.current", workspace_id=workspace_id)["name"]

    def test_aliases_survive_reorder_and_close(self):
        first, _ = self.workspace("Handles first")
        window_id = first["window_id"]
        second, second_terminal = self.workspace("Handles second", window_id)
        third, _ = self.workspace("Handles third", window_id)

        self.call("workspace.reorder", workspace_id=third["workspace_id"], index=0)
        self.assertEqual(self.name_of(first["workspace_id"]), "Handles first")
        self.assertEqual(self.name_of(second["workspace_id"]), "Handles second")
        self.assertEqual(self.name_of(third["workspace_id"]), "Handles third")

        self.workspaces.remove(first["workspace_id"])
        self.call("workspace.close", workspace_id=first["workspace_id"], force=True)
        self.assertEqual(self.name_of(second["workspace_id"]), "Handles second")
        self.call("workspace.current", workspace_id=first["workspace_id"], error=True)

        # Terminal handles route metadata to their own workspace after reorder.
        record = self.call("notification.create", terminal_id=second_terminal["terminal_id"],
                           title="Handles regression")
        self.assertEqual(record["workspace_id"], second["workspace_id"])
        unread = self.call("notification.list", workspace_id=third["workspace_id"], unread=True)
        self.assertEqual(unread, [])
        self.call("notification.dismiss", notification_id=record["notification_id"])


if __name__ == "__main__":
    unittest.main()
