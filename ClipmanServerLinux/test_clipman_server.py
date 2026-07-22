#!/usr/bin/env python3
"""Focused protocol tests for the shared Clipman Server implementation."""

from __future__ import annotations

import http.client
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier, Thread

import clipman_server


class ConditionalCreateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.settings, _ = clipman_server.load_settings(root / "settings.json")
        self.settings["AuthToken"] = "test-token"
        self.settings["DatabasePath"] = str(root / "clipman-history.clipdb")
        self.settings["MaxDatabaseBytes"] = 1024 * 1024
        self.server = clipman_server.ThreadingServer(("127.0.0.1", 0), clipman_server.Handler)
        self.settings["Host"] = "127.0.0.1"
        self.settings["Port"] = self.server.server_port
        self.server.settings = self.settings
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temp.cleanup()

    def request(self, body: bytes) -> tuple[int, bytes, str]:
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        connection.request(
            "PUT",
            "/api/v1/database/0123456789abcdef0123456789abcdef",
            body=body,
            headers={
                "Authorization": "Bearer test-token",
                "Content-Type": "application/octet-stream",
                "If-None-Match": "*",
            },
        )
        response = connection.getresponse()
        data = response.read()
        revision = response.getheader("X-Clipman-Revision", "")
        status = response.status
        connection.close()
        return status, data, revision

    def test_only_one_first_writer_can_create_bucket(self) -> None:
        barrier = Barrier(2)

        def create(body: bytes) -> tuple[int, bytes, str]:
            barrier.wait(timeout=5)
            return self.request(body)

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(create, (b"first", b"second")))

        self.assertEqual([200, 412], sorted(item[0] for item in results))
        winner = next(item for item in results if item[0] == 200)
        loser = next(item for item in results if item[0] == 412)
        self.assertTrue(winner[2])
        self.assertEqual(b"Database already exists", loser[1])
        self.assertEqual(winner[2], loser[2])
        database = clipman_server.database_path(self.settings, "0123456789abcdef0123456789abcdef")
        self.assertIn(database.read_bytes(), (b"first", b"second"))
        self.assertEqual(1, self.server.runtime_summary()["Conflicts"])


if __name__ == "__main__":
    unittest.main()
