#!/usr/bin/env python3
"""Focused protocol tests for the shared Clipman Server implementation."""

from __future__ import annotations

import http.client
import http.server
import json
import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier, Event, Thread

import clipman_server


class ConnectionConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config_path = self.root / "settings.json"
        self.settings, _ = clipman_server.load_settings(self.config_path)
        self.settings.update({
            "AdvertiseHost": "server.example",
            "Port": 54321,
            "AuthToken": "test-token",
        })

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_connection_config_is_valid_and_complete(self) -> None:
        target = clipman_server.write_connection_config(self.config_path, self.settings)
        document = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual("server-connection", document["clipman"])
        self.assertEqual(1, document["version"])
        self.assertEqual("clipman://server.example:54321", document["address"])
        self.assertEqual("server.example", document["host"])
        self.assertEqual(54321, document["port"])
        self.assertEqual("test-token", document["token"])
        if os.name != "nt":
            self.assertEqual(0, target.stat().st_mode & 0o077)

    def test_legacy_connection_file_triggers_new_config(self) -> None:
        clipman_server.write_connection_info(self.config_path, self.settings)
        target = clipman_server.maybe_write_connection_config(self.config_path, self.settings, False, False)
        self.assertEqual(clipman_server.default_connection_config_path(self.config_path), target)
        self.assertTrue(target.is_file())


class CertificateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config_path = self.root / "settings.json"
        self.settings, _ = clipman_server.load_settings(self.config_path)
        self.settings.update({
            "Host": "127.0.0.1",
            "AdvertiseHost": "localhost",
            "DatabasePath": str(self.root / "clipman-history.clipdb"),
            "LogPath": str(self.root / "logs" / "clipman-server.log"),
        })

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_certificate_names_are_typed_and_reject_config_injection(self) -> None:
        names, addresses = clipman_server.normalized_certificate_names(
            self.settings,
            ["server.example"],
            ["192.0.2.7"],
        )
        self.assertIn("localhost", names)
        self.assertIn("server.example", names)
        self.assertIn("127.0.0.1", addresses)
        self.assertIn("192.0.2.7", addresses)
        with self.assertRaises(ValueError):
            clipman_server.normalized_certificate_names(self.settings, ["bad.example\nkeyUsage=CA:TRUE"], [])

    def test_partial_or_missing_tls_configuration_cannot_downgrade_to_http(self) -> None:
        self.settings["CertFile"] = str(self.root / "missing.crt")
        self.settings["KeyFile"] = ""
        with self.assertRaisesRegex(SystemExit, "both CertFile and KeyFile"):
            clipman_server.create_tls_context(self.settings)
        self.settings["KeyFile"] = str(self.root / "missing.key")
        with self.assertRaisesRegex(SystemExit, "certificate was not found"):
            clipman_server.create_tls_context(self.settings)

    def test_generated_certificate_has_apple_and_android_server_extensions(self) -> None:
        try:
            clipman_server.find_openssl()
        except RuntimeError:
            self.skipTest("OpenSSL is not installed")
        result = clipman_server.create_tls_certificate(
            self.config_path,
            self.settings,
            ["server.example"],
            ["192.0.2.7"],
            False,
        )
        authority = Path(result["authority"])
        certificate = Path(result["certificate"])
        self.assertTrue(authority.is_file())
        self.assertTrue(certificate.is_file())
        self.assertEqual(str(authority.resolve()), self.settings["CaFile"])
        self.assertTrue(str(self.settings["CertFile"]).endswith("clipman-server-fullchain.crt"))
        openssl = clipman_server.find_openssl()
        details = clipman_server.run_openssl(openssl, ["x509", "-in", str(certificate), "-noout", "-text"])
        self.assertIn("CA:FALSE", details)
        self.assertIn("TLS Web Server Authentication", details)
        self.assertIn("DNS:server.example", details)
        self.assertIn("IP Address:192.0.2.7", details)
        self.assertIsInstance(clipman_server.create_tls_context(self.settings), clipman_server.ssl.SSLContext)
        self.settings["_TlsCertificateExpires"] = clipman_server.tls_certificate_expiry(self.settings)
        self.assertTrue(clipman_server.status(self.settings)["TlsCertificateExpires"])
        first_authority = authority.read_bytes()
        clipman_server.create_tls_certificate(self.config_path, self.settings, [], [], False)
        self.assertEqual(first_authority, authority.read_bytes())

    def test_expiry_warning_is_non_blocking_and_uses_active_certificate(self) -> None:
        try:
            clipman_server.find_openssl()
        except RuntimeError:
            self.skipTest("OpenSSL is not installed")
        clipman_server.create_tls_certificate(self.config_path, self.settings, [], [], False)
        with self.assertLogs(level="WARNING") as captured:
            clipman_server.warn_if_tls_certificate_expiring(self.settings, days=500)
        self.assertIn("expires within 500 days", "\n".join(captured.output))

    def test_certificate_share_handler_serves_only_the_public_authority(self) -> None:
        server = http.server.HTTPServer(("127.0.0.1", 0), clipman_server.CertificateShareHandler)
        server.download_path = "/private-test.crt"
        server.certificate_data = b"-----BEGIN CERTIFICATE-----\nPUBLIC\n-----END CERTIFICATE-----\n"
        server.downloaded = Event()
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            connection.request("HEAD", server.download_path)
            response = connection.getresponse()
            response.read()
            self.assertEqual(200, response.status)
            self.assertEqual("no-store", response.getheader("Cache-Control"))
            self.assertFalse(server.downloaded.is_set())
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            connection.request("GET", "/clipman-server-ca.key")
            response = connection.getresponse()
            response.read()
            self.assertEqual(404, response.status)
            self.assertFalse(server.downloaded.is_set())
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            connection.request("GET", server.download_path)
            response = connection.getresponse()
            data = response.read()
            self.assertEqual(200, response.status)
            self.assertEqual("application/x-x509-ca-cert", response.getheader("Content-Type"))
            self.assertIn("clipman-server-ca.crt", response.getheader("Content-Disposition"))
            self.assertEqual("no-store", response.getheader("Cache-Control"))
            self.assertEqual(server.certificate_data, data)
            self.assertTrue(server.downloaded.is_set())
            connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


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

    def test_expect_continue_upload_completes(self) -> None:
        database_id = "abcdef0123456789abcdef0123456789"
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        connection.request(
            "PUT",
            f"/api/v1/database/{database_id}",
            body=b"expect-continue",
            headers={
                "Authorization": "Bearer test-token",
                "Content-Type": "application/octet-stream",
                "Expect": "100-continue",
                "If-None-Match": "*",
            },
        )
        response = connection.getresponse()
        data = response.read()
        connection.close()

        self.assertEqual(200, response.status)
        self.assertTrue(response.getheader("X-Clipman-Revision", ""))
        self.assertIn(b'"Version": "2.1.0"', data)
        database = clipman_server.database_path(self.settings, database_id)
        self.assertEqual(b"expect-continue", database.read_bytes())


if __name__ == "__main__":
    unittest.main()
