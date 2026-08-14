#!/usr/bin/env python3
"""Focused protocol tests for the shared Clipman Server implementation."""

from __future__ import annotations

import hashlib
import http.client
import http.server
import json
import io
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier, Event, Thread
from unittest import mock

import clipman_server


class ServerStartupTests(unittest.TestCase):
    def write_test_settings(self, root: Path) -> tuple[Path, dict[str, object]]:
        config = root / "settings.json"
        settings, _ = clipman_server.load_settings(config)
        settings["DatabasePath"] = str(root / "data" / "clipman-history.clipdb")
        settings["LogPath"] = str(root / "logs" / "clipman-server.log")
        clipman_server.save_settings(config, settings)
        return config, settings

    def start_lock_holder(self, root: Path) -> subprocess.Popen[str]:
        script = (
            "from pathlib import Path\n"
            "import sys\n"
            "sys.path.insert(0, sys.argv[1])\n"
            "import clipman_server\n"
            "with clipman_server.DataRootLock(Path(sys.argv[2])):\n"
            "    print('locked', flush=True)\n"
            "    sys.stdin.readline()\n"
        )
        process = subprocess.Popen(
            [sys.executable, "-u", "-c", script, str(Path(__file__).resolve().parent), str(root)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert process.stdout is not None
        ready = process.stdout.readline().strip()
        if ready != "locked":
            _stdout, stderr = process.communicate(timeout=5)
            self.fail(f"Lock holder did not start: {stderr}")
        return process

    def stop_lock_holder(self, process: subprocess.Popen[str]) -> None:
        if process.poll() is not None:
            return
        assert process.stdin is not None
        process.stdin.write("\n")
        process.stdin.flush()
        process.communicate(timeout=5)

    def test_docker_entrypoint_writes_connection_files_then_runs_server(self) -> None:
        entrypoint = (Path(__file__).resolve().parent.parent / "ClipmanServerDocker" / "docker-entrypoint.sh").read_text(encoding="utf-8")
        write_command = 'python3 "$@" --write-connection-info >/dev/null'
        run_command = 'exec python3 "$@"'

        self.assertIn(write_command, entrypoint)
        self.assertIn(run_command, entrypoint)
        self.assertLess(entrypoint.index(write_command), entrypoint.index(run_command))
        self.assertIn("CLIPMAN_ALLOW_INSECURE_REMOTE=true only on a trusted LAN or VPN", entrypoint)
        self.assertIn("a wildcard listener does not identify an address another device can use", entrypoint)

    def test_new_settings_use_persistent_port_range(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / "settings.json"
            settings, created = clipman_server.load_settings(config)
            config_exists = config.is_file()

        self.assertTrue(created)
        self.assertTrue(config_exists)
        self.assertGreaterEqual(settings["Port"], clipman_server.SERVER_PORT_MIN)
        self.assertLessEqual(settings["Port"], clipman_server.SERVER_PORT_MAX)

    def test_sparse_existing_settings_use_in_memory_defaults_without_save(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / "settings.json"
            original = b'{\n  "Host": "127.0.0.1"\n}\n'
            config.write_bytes(original)
            old_ns = 946684800 * 1_000_000_000
            os.utime(config, ns=(old_ns, old_ns))
            config.chmod(0o400)
            before_hash = hashlib.sha256(original).hexdigest()
            before_mtime = config.stat().st_mtime_ns
            try:
                settings, created = clipman_server.load_settings(config)

                self.assertFalse(created)
                self.assertIn("AuthToken", settings)
                self.assertIn("DatabasePath", settings)
                self.assertIn("MaxDatabaseBytes", settings)
                self.assertEqual(original, config.read_bytes())
                self.assertEqual(before_hash, hashlib.sha256(config.read_bytes()).hexdigest())
                self.assertEqual(before_mtime, config.stat().st_mtime_ns)
            finally:
                config.chmod(0o600)

    def test_plain_start_keeps_existing_settings_bytes_and_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config = root / "settings.json"
            data_root = root / "data"
            original = (
                "{\n"
                '  "Host": "127.0.0.1",\n'
                f'  "DatabasePath": {json.dumps(str(data_root / "clipman-history.clipdb"))},\n'
                f'  "LogPath": {json.dumps(str(root / "logs" / "clipman-server.log"))}\n'
                "}\n"
            ).encode("utf-8")
            config.write_bytes(original)
            old_ns = 946684800 * 1_000_000_000
            os.utime(config, ns=(old_ns, old_ns))
            config.chmod(0o400)
            before_hash = hashlib.sha256(original).hexdigest()
            before_mtime = config.stat().st_mtime_ns
            error_output = io.StringIO()
            args = ["clipman_server.py", "--config", str(config)]

            try:
                with mock.patch("sys.argv", args), \
                     mock.patch.object(clipman_server, "ThreadingServer", side_effect=OSError(10013, "Permission denied")), \
                     mock.patch.object(clipman_server, "configure_logging"), \
                     redirect_stderr(error_output):
                    result = clipman_server.main()

                self.assertEqual(clipman_server.BIND_ERROR_EXIT_CODE, result)
                self.assertEqual(original, config.read_bytes())
                self.assertEqual(before_hash, hashlib.sha256(config.read_bytes()).hexdigest())
                self.assertEqual(before_mtime, config.stat().st_mtime_ns)
            finally:
                config.chmod(0o600)
            with clipman_server.DataRootLock(data_root):
                pass

    def test_explicit_command_line_mutation_is_saved(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config, _settings = self.write_test_settings(root)
            before_hash = hashlib.sha256(config.read_bytes()).hexdigest()
            args = [
                "clipman_server.py",
                "--config",
                str(config),
                "--port",
                "34567",
                "--write-connection-info",
            ]

            with mock.patch("sys.argv", args), \
                 mock.patch.object(clipman_server, "configure_logging"), \
                 redirect_stdout(io.StringIO()):
                result = clipman_server.main()

            saved = json.loads(config.read_text(encoding="utf-8"))
            self.assertEqual(0, result)
            self.assertEqual(34567, saved["Port"])
            self.assertNotEqual(before_hash, hashlib.sha256(config.read_bytes()).hexdigest())

    def test_settings_replacement_preserves_existing_owner(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / "settings.json"
            config.write_text("{}", encoding="utf-8")
            expected_owner = (123, 456)
            with mock.patch.object(clipman_server, "file_owner", return_value=expected_owner), \
                    mock.patch.object(clipman_server, "restore_file_owner") as restore:
                clipman_server.save_settings(config, {"Port": 34567})
            restore.assert_called_once_with(config, expected_owner)

    def test_server_start_refuses_locked_root_and_allows_other_roots(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            locked_root = root / "shared-data"
            other_root = root / "other-data"
            holder = self.start_lock_holder(locked_root)
            try:
                config, settings = self.write_test_settings(root / "second-server")
                settings["DatabasePath"] = str(locked_root / "clipman-history.clipdb")
                settings["AuthToken"] = "must-not-appear-in-errors"
                clipman_server.save_settings(config, settings)
                error_output = io.StringIO()
                args = ["clipman_server.py", "--config", str(config)]
                with mock.patch("sys.argv", args), \
                     mock.patch.object(clipman_server, "configure_logging"), \
                     redirect_stderr(error_output):
                    result = clipman_server.main()

                message = error_output.getvalue()
                self.assertEqual(clipman_server.DATA_ROOT_LOCK_EXIT_CODE, result)
                self.assertIn("already using the data root", message)
                self.assertNotIn("must-not-appear-in-errors", message)
                with clipman_server.DataRootLock(other_root):
                    pass
            finally:
                self.stop_lock_holder(holder)

            with clipman_server.DataRootLock(locked_root):
                pass
            self.assertEqual(b"0\n", (locked_root / ".clipman-server.lock").read_bytes())

    def test_killed_lock_holder_does_not_block_restart(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "shared-data"
            holder = self.start_lock_holder(root)
            holder.kill()
            holder.communicate(timeout=5)

            with clipman_server.DataRootLock(root):
                pass

    def test_suggest_port_prints_available_persistent_port(self) -> None:
        output = io.StringIO()
        with mock.patch("sys.argv", ["clipman_server.py", "--suggest-port"]), redirect_stdout(output):
            result = clipman_server.main()

        port = int(output.getvalue().strip())
        self.assertEqual(0, result)
        self.assertGreaterEqual(port, clipman_server.SERVER_PORT_MIN)
        self.assertLessEqual(port, clipman_server.SERVER_PORT_MAX)

    def test_bind_failure_is_concise_and_has_dedicated_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            config = root / "settings.json"
            settings, _created = clipman_server.load_settings(config)
            settings["DatabasePath"] = str(root / "data" / "clipman-history.clipdb")
            settings["LogPath"] = str(root / "logs" / "clipman-server.log")
            clipman_server.save_settings(config, settings)
            error_output = io.StringIO()
            args = ["clipman_server.py", "--config", str(config)]
            with mock.patch("sys.argv", args), \
                 mock.patch.object(clipman_server, "ThreadingServer", side_effect=OSError(10013, "Permission denied")), \
                 mock.patch.object(clipman_server, "configure_logging"), \
                 redirect_stderr(error_output):
                result = clipman_server.main()

        self.assertEqual(clipman_server.BIND_ERROR_EXIT_CODE, result)
        self.assertIn("could not open", error_output.getvalue())
        self.assertIn("Choose another listening port", error_output.getvalue())
        self.assertNotIn("Traceback", error_output.getvalue())

    def test_wildcard_listener_is_not_treated_as_private(self) -> None:
        self.assertFalse(clipman_server.is_local_or_private_host("0.0.0.0"))
        self.assertFalse(clipman_server.is_local_or_private_host("::"))
        self.assertTrue(clipman_server.is_local_or_private_host("100.64.0.10"))


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

    def test_wildcard_listener_is_not_exported_as_a_client_address(self) -> None:
        self.settings["Host"] = "0.0.0.0"
        self.settings["AdvertiseHost"] = ""
        with self.assertRaisesRegex(RuntimeError, "wildcard listening address"):
            clipman_server.write_connection_config(self.config_path, self.settings)


class TemporarySetupLinkTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.config_path = self.root / "settings.json"
        self.settings, _ = clipman_server.load_settings(self.config_path)
        self.settings.update({
            "Host": "127.0.0.1",
            "AdvertiseHost": "127.0.0.1",
            "AuthToken": "permanent-test-token",
            "DatabasePath": str(self.root / "data" / "clipman-history.clipdb"),
            "LogPath": str(self.root / "logs" / "clipman-server.log"),
        })
        self.server = clipman_server.ThreadingServer(("127.0.0.1", 0), clipman_server.Handler)
        self.settings["Port"] = self.server.server_port
        self.server.settings = self.settings
        self.server.config_path = self.config_path
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temp.cleanup()

    def create(self, downloads: int = 2) -> tuple[str, str, dict[str, object]]:
        url, state = clipman_server.create_setup_link(
            self.config_path,
            self.settings,
            minutes=30,
            downloads=downloads,
        )
        code = url.rsplit("/", 1)[1]
        return url, code, state

    def request(self, method: str, path: str, user_agent: str = "") -> tuple[int, bytes, dict[str, str]]:
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        headers = {"User-Agent": user_agent} if user_agent else {}
        connection.request(method, path, headers=headers)
        response = connection.getresponse()
        body = response.read()
        result = response.status, body, {key.lower(): value for key, value in response.getheaders()}
        connection.close()
        return result

    def test_state_contains_only_hash_limit_and_expiry(self) -> None:
        _url, code, _state = self.create()
        state_path = clipman_server.setup_state_path(self.config_path)
        raw = state_path.read_text(encoding="utf-8")
        stored = json.loads(raw)

        self.assertNotIn(code, raw)
        self.assertNotIn(self.settings["AuthToken"], raw)
        self.assertEqual(hashlib.sha256(code.encode("ascii")).hexdigest(), stored["code_sha256"])
        self.assertEqual(2, stored["remaining_downloads"])
        if os.name != "nt":
            self.assertEqual(0, state_path.stat().st_mode & 0o077)

    def test_state_inherits_config_owner_for_system_services(self) -> None:
        expected_owner = (123, 456)
        with mock.patch.object(clipman_server, "file_owner", return_value=expected_owner), \
                mock.patch.object(clipman_server, "restore_file_owner") as restore:
            self.create()
        restore.assert_called_once_with(clipman_server.setup_state_path(self.config_path), expected_owner)

    def test_accessible_page_has_all_platforms_and_secure_headers(self) -> None:
        _url, code, _state = self.create()
        status, body, headers = self.request("GET", f"/setup/{code}", "Mozilla/5.0 (iPhone)")
        page = body.decode("utf-8")

        self.assertEqual(200, status)
        self.assertIn("On this iPhone or iPad", page)
        self.assertIn("Windows, macOS, Linux and Android downloads", page)
        self.assertIn("Clipman for iPhone and iPad", page)
        self.assertIn(f'/setup/{code}/connection.clpconf', page)
        self.assertNotIn(self.settings["AuthToken"], page)
        self.assertEqual("no-store, max-age=0", headers["cache-control"])
        self.assertEqual("no-referrer", headers["referrer-policy"])
        self.assertEqual("nosniff", headers["x-content-type-options"])
        self.assertIn("default-src 'none'", headers["content-security-policy"])

    def test_head_does_not_consume_but_get_download_does(self) -> None:
        _url, code, _state = self.create(downloads=2)
        path = f"/setup/{code}/connection.clpconf"
        status, body, headers = self.request("HEAD", path)
        self.assertEqual(200, status)
        self.assertEqual(b"", body)
        self.assertEqual(2, json.loads(clipman_server.setup_state_path(self.config_path).read_text())["remaining_downloads"])

        status, body, headers = self.request("GET", path)
        document = json.loads(body)
        self.assertEqual(200, status)
        self.assertEqual("application/x-clipman-server-connection", headers["content-type"])
        self.assertIn("clipman-server-connection.clpconf", headers["content-disposition"])
        self.assertEqual("permanent-test-token", document["token"])
        self.assertNotIn("password", json.dumps(document).lower())
        self.assertEqual(1, json.loads(clipman_server.setup_state_path(self.config_path).read_text())["remaining_downloads"])

    def test_final_download_revokes_link(self) -> None:
        _url, code, _state = self.create(downloads=1)
        path = f"/setup/{code}/connection.clpconf"
        self.assertEqual(200, self.request("GET", path)[0])
        self.assertFalse(clipman_server.setup_state_path(self.config_path).exists())
        self.assertEqual(404, self.request("GET", path)[0])
        self.assertEqual(404, self.request("GET", f"/setup/{code}")[0])

    def test_only_one_concurrent_final_download_succeeds(self) -> None:
        _url, code, _state = self.create(downloads=1)
        path = f"/setup/{code}/connection.clpconf"
        barrier = Barrier(2)

        def download(_value: int) -> int:
            barrier.wait(timeout=5)
            return self.request("GET", path)[0]

        with ThreadPoolExecutor(max_workers=2) as executor:
            statuses = sorted(executor.map(download, (1, 2)))
        self.assertEqual([200, 404], statuses)

    def test_invalid_expired_revoked_and_corrupt_links_are_generic_404(self) -> None:
        _url, code, _state = self.create()
        state_path = clipman_server.setup_state_path(self.config_path)
        self.assertEqual(404, self.request("GET", "/setup/not-a-valid-code")[0])
        self.assertEqual(404, self.request("GET", "/setup/" + ("A" * 43))[0])

        stored = json.loads(state_path.read_text())
        stored["expires_unix_ms"] = 1
        state_path.write_text(json.dumps(stored), encoding="utf-8")
        self.assertEqual(404, self.request("GET", f"/setup/{code}")[0])

        self.create()
        state_path.write_text("not json", encoding="utf-8")
        self.assertEqual(404, self.request("GET", f"/setup/{code}")[0])
        clipman_server.revoke_setup_link(self.config_path)
        self.assertEqual(404, self.request("GET", f"/setup/{code}")[0])

    def test_setup_code_is_redacted_from_request_log(self) -> None:
        _url, code, _state = self.create()
        with self.assertLogs(level="INFO") as captured:
            self.request("GET", f"/setup/{code}")
        log_text = "\n".join(captured.output)
        self.assertNotIn(code, log_text)
        self.assertIn("/setup/<temporary-code>", log_text)

    def test_public_http_is_rejected_but_public_https_is_allowed(self) -> None:
        self.settings["AdvertiseHost"] = "public.example"
        with mock.patch.object(clipman_server, "is_local_or_private_setup_host", return_value=False):
            with self.assertRaisesRegex(ValueError, "requires HTTPS"):
                clipman_server.create_setup_link(self.config_path, self.settings)
            url, _state = clipman_server.create_setup_link(
                self.config_path,
                self.settings,
                base_url_override="https://public.example",
            )
        self.assertTrue(url.startswith("https://public.example/setup/"))
        with self.assertRaisesRegex(ValueError, "must not contain a path"):
            clipman_server.setup_base_url(self.settings, "https://public.example/private")
        with self.assertRaisesRegex(ValueError, "cannot contain credentials"):
            clipman_server.setup_base_url(self.settings, "https://user:pass@public.example")


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
        for hostname in ["bad..example", "-bad.example", "bad-.example", "bad_example"]:
            with self.subTest(hostname=hostname), self.assertRaises(ValueError):
                clipman_server.normalized_certificate_names(self.settings, [hostname], [])

    def test_discovered_certificate_addresses_are_normalized_and_bounded(self) -> None:
        values = []
        for candidate in ["192.0.2.8/24", "192.0.2.8", "fe80::1234%en0", "127.0.0.1", "0.0.0.0", "ff02::1", "invalid"]:
            clipman_server._append_certificate_ip(values, candidate)
        self.assertEqual(["192.0.2.8", "fe80::1234"], values)

    def test_interface_address_output_formats_are_parsed(self) -> None:
        outputs = {
            "plain": "192.0.2.8 fe80::1234%7 127.0.0.1\n",
            "ip": "2: eth0 inet 192.0.2.8/24 scope global eth0\n2: eth0 inet6 fe80::1234/64 scope link\n",
            "ifconfig": "\tinet 192.0.2.8 netmask 0xffffff00\n\tinet6 fe80::1234%en0 prefixlen 64\n",
        }
        for style, output in outputs.items():
            with self.subTest(style=style), mock.patch.object(
                clipman_server.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["network-tool"], 0, stdout=output, stderr=""),
            ):
                self.assertEqual(
                    ["192.0.2.8", "fe80::1234"],
                    clipman_server._interface_command_addresses(["network-tool"], style),
                )

    def test_certificate_prompt_accepts_detected_addresses_and_comma_delimited_hosts(self) -> None:
        answers = iter(["yes", "server.example, pi.local, server.example"])
        output = []
        hosts, addresses = clipman_server.prompt_certificate_names(
            ["192.0.2.8", "2001:db8::8"],
            read=lambda _prompt: next(answers),
            write=output.append,
        )
        self.assertEqual(["server.example", "pi.local", "server.example"], hosts)
        self.assertEqual(["192.0.2.8", "2001:db8::8"], addresses)
        self.assertIn("Detected non-loopback IP addresses:", output)

    def test_certificate_prompt_can_skip_detected_addresses(self) -> None:
        answers = iter(["no", ""])
        hosts, addresses = clipman_server.prompt_certificate_names(
            ["192.0.2.8"],
            read=lambda _prompt: next(answers),
            write=lambda _message: None,
        )
        self.assertEqual([], hosts)
        self.assertEqual([], addresses)

    def test_certificate_prompt_repeats_after_an_unrecognized_answer(self) -> None:
        answers = iter(["perhaps", "yes", ""])
        output = []
        hosts, addresses = clipman_server.prompt_certificate_names(
            ["192.0.2.8"],
            read=lambda _prompt: next(answers),
            write=output.append,
        )
        self.assertEqual([], hosts)
        self.assertEqual(["192.0.2.8"], addresses)
        self.assertIn("Please answer yes or no.", output)

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
        authority_details = clipman_server.inspect_private_ca(self.settings)
        self.assertIsNotNone(authority_details)
        self.assertEqual("localhost", authority_details["host"])
        self.assertEqual(result["fingerprint"], authority_details["fingerprint"])
        connection_document = json.loads(
            clipman_server.default_connection_config_path(self.config_path).read_text(encoding="utf-8")
        )
        self.assertEqual(authority.read_text(encoding="ascii"), connection_document["ca_cert_pem"])
        connection_text = clipman_server.default_connection_info_path(self.config_path).read_text(encoding="utf-8")
        self.assertIn("Private CA host: localhost", connection_text)
        self.assertIn("Private CA SHA-256 fingerprint: " + result["fingerprint"], connection_text)
        first_authority = authority.read_bytes()
        clipman_server.create_tls_certificate(self.config_path, self.settings, [], [], False)
        self.assertEqual(first_authority, authority.read_bytes())

    def test_invalid_authority_preserves_existing_connection_file(self) -> None:
        try:
            clipman_server.find_openssl()
        except RuntimeError:
            self.skipTest("OpenSSL is not installed")
        result = clipman_server.create_tls_certificate(self.config_path, self.settings, [], [], False)
        target = clipman_server.default_connection_config_path(self.config_path)
        original = target.read_bytes()
        authority = Path(result["authority"])
        authority.write_bytes(authority.read_bytes() + authority.read_bytes())

        with self.assertLogs(level="WARNING"):
            refreshed = clipman_server.maybe_write_connection_config(
                self.config_path, self.settings, False, False
            )

        self.assertIsNone(refreshed)
        self.assertEqual(original, target.read_bytes())
        with self.assertRaisesRegex(RuntimeError, "exactly one PEM CERTIFICATE"):
            clipman_server.write_connection_config(self.config_path, self.settings)

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
            self.assertTrue(server.downloaded.wait(1))
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
        self.assertIn(('"Version": "' + clipman_server.APP_VERSION + '"').encode("utf-8"), data)
        database = clipman_server.database_path(self.settings, database_id)
        self.assertEqual(b"expect-continue", database.read_bytes())


if __name__ == "__main__":
    unittest.main()
