import argparse
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import clipman_server_updater as updater


class ClipmanServerUpdaterTests(unittest.TestCase):
    def test_versions_and_release_asset_are_selected_numerically(self):
        release = {
            "tag_name": "v2.10.0",
            "assets": [
                {
                    "name": "ClipmanServer-2.10.0.zip",
                    "browser_download_url": "https://example.test/ClipmanServer-2.10.0.zip",
                }
            ],
        }
        version, asset = updater.find_update(release, "2.9.9")
        self.assertEqual("2.10.0", version)
        self.assertEqual("ClipmanServer-2.10.0.zip", asset["name"])
        self.assertIsNone(updater.find_update(release, "2.10.0"))

    def test_unsafe_zip_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "unsafe.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("../outside.txt", "unsafe")
            with self.assertRaisesRegex(RuntimeError, "unsafe path"):
                updater.safe_extract(archive, root / "output")

    def test_missing_or_wrong_release_digest_is_rejected(self):
        digest = "a" * 64
        with self.assertRaisesRegex(RuntimeError, "did not provide"):
            updater.verify_sha256_digest("", digest)
        with self.assertRaisesRegex(RuntimeError, "failed its SHA-256"):
            updater.verify_sha256_digest("sha256:" + "b" * 64, digest)
        updater.verify_sha256_digest("sha256:" + digest, digest)

    def test_health_url_uses_advertised_https_address(self):
        settings = {
            "Host": "0.0.0.0",
            "AdvertiseHost": "server.example.test",
            "Port": 61234,
            "CertFile": "/tls/server.pem",
            "KeyFile": "/tls/server.key",
        }
        self.assertEqual("https://server.example.test:61234/api/v1/health", updater.health_url(settings))

    def test_failed_health_check_restores_previous_program(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "app"
            bin_dir = root / "bin"
            config = root / "config" / "settings.json"
            service = root / "systemd" / "clipman-server.service"
            app.mkdir(parents=True)
            bin_dir.mkdir(parents=True)
            config.parent.mkdir(parents=True)
            service.parent.mkdir(parents=True)
            (app / "old.txt").write_text("old", encoding="utf-8")
            helper = bin_dir / "clipmanserver"
            launcher = bin_dir / "clipman-server"
            helper.write_text("old helper", encoding="utf-8")
            launcher.write_text("old launcher", encoding="utf-8")
            service.write_text("old service", encoding="utf-8")
            config.write_text(json.dumps({"Host": "127.0.0.1", "Port": 60000}), encoding="utf-8")

            def fake_extract(_archive, destination):
                package = destination / "ClipmanServer"
                (package / "Linux").mkdir(parents=True)
                (package / "manifest.json").write_text(
                    json.dumps({"Name": "Clipman Server", "Version": "2.1.1"}), encoding="utf-8"
                )
                (package / "clipman_server.py").write_text("new", encoding="utf-8")
                (package / "clipman_server_updater.py").write_text("new", encoding="utf-8")
                (package / "Linux" / "install-clipman-server.sh").write_text("installer", encoding="utf-8")

            def fake_run(command, **_kwargs):
                if command[0] == "sh":
                    (app / "new.txt").write_text("new", encoding="utf-8")
                    (app / "old.txt").unlink()
                    helper.write_text("new helper", encoding="utf-8")
                    launcher.write_text("new launcher", encoding="utf-8")
                    service.write_text("new service", encoding="utf-8")
                return mock.Mock(returncode=0)

            args = argparse.Namespace(
                yes=True,
                current_version="2.1.0",
                app_dir=str(app),
                bin_dir=str(bin_dir),
                config=str(config),
                service_file=str(service),
            )
            asset = {"browser_download_url": "https://example.test/server.zip"}
            with mock.patch.object(updater, "download_asset", side_effect=lambda _asset, path: path.write_bytes(b"zip")), \
                 mock.patch.object(updater, "safe_extract", side_effect=fake_extract), \
                 mock.patch.object(updater, "run", side_effect=fake_run), \
                 mock.patch.object(updater, "wait_for_health", side_effect=RuntimeError("not healthy")):
                with self.assertRaisesRegex(RuntimeError, "not healthy"):
                    updater.install_update(args, "2.1.1", asset)

            self.assertEqual("old", (app / "old.txt").read_text(encoding="utf-8"))
            self.assertFalse((app / "new.txt").exists())
            self.assertEqual("old helper", helper.read_text(encoding="utf-8"))
            self.assertEqual("old launcher", launcher.read_text(encoding="utf-8"))
            self.assertEqual("old service", service.read_text(encoding="utf-8"))

    def test_successful_health_check_keeps_updated_program(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "app"
            bin_dir = root / "bin"
            config = root / "config" / "settings.json"
            service = root / "systemd" / "clipman-server.service"
            app.mkdir(parents=True)
            bin_dir.mkdir(parents=True)
            config.parent.mkdir(parents=True)
            service.parent.mkdir(parents=True)
            (app / "program.txt").write_text("old", encoding="utf-8")
            helper = bin_dir / "clipmanserver"
            launcher = bin_dir / "clipman-server"
            helper.write_text("old helper", encoding="utf-8")
            launcher.write_text("old launcher", encoding="utf-8")
            service.write_text("old service", encoding="utf-8")
            config.write_text(json.dumps({"Host": "127.0.0.1", "Port": 60000}), encoding="utf-8")

            def fake_extract(_archive, destination):
                package = destination / "ClipmanServer"
                (package / "Linux").mkdir(parents=True)
                (package / "manifest.json").write_text(
                    json.dumps({"Name": "Clipman Server", "Version": "2.1.1"}), encoding="utf-8"
                )
                (package / "clipman_server.py").write_text("new", encoding="utf-8")
                (package / "clipman_server_updater.py").write_text("new", encoding="utf-8")
                (package / "Linux" / "install-clipman-server.sh").write_text("installer", encoding="utf-8")

            def fake_run(command, **_kwargs):
                if command[0] == "sh":
                    (app / "program.txt").write_text("new", encoding="utf-8")
                    helper.write_text("new helper", encoding="utf-8")
                    launcher.write_text("new launcher", encoding="utf-8")
                    service.write_text("new service", encoding="utf-8")
                return mock.Mock(returncode=0)

            args = argparse.Namespace(
                yes=True,
                current_version="2.1.0",
                app_dir=str(app),
                bin_dir=str(bin_dir),
                config=str(config),
                service_file=str(service),
            )
            with mock.patch.object(updater, "download_asset", side_effect=lambda _asset, path: path.write_bytes(b"zip")), \
                 mock.patch.object(updater, "safe_extract", side_effect=fake_extract), \
                 mock.patch.object(updater, "run", side_effect=fake_run), \
                 mock.patch.object(updater, "wait_for_health"):
                updater.install_update(args, "2.1.1", {"browser_download_url": "https://example.test/server.zip"})

            self.assertEqual("new", (app / "program.txt").read_text(encoding="utf-8"))
            self.assertEqual("new helper", helper.read_text(encoding="utf-8"))
            self.assertEqual("new launcher", launcher.read_text(encoding="utf-8"))
            self.assertEqual("new service", service.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
