#!/usr/bin/env python3
"""Behavior tests for the Linux Clipman Server service installers."""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent


@unittest.skipUnless(os.name == "posix", "Linux shell installer tests require a POSIX host")
class LinuxInstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.package = self.root / "package"
        self.linux = self.package / "Linux"
        self.fake_bin = self.root / "fake-bin"
        self.linux.mkdir(parents=True)
        self.fake_bin.mkdir()
        shutil.copy2(ROOT / "install-clipman-server.sh", self.linux / "install-clipman-server.sh")
        shutil.copy2(
            ROOT / "install-clipman-server-system-helper.sh",
            self.linux / "install-clipman-server-system-helper.sh",
        )
        self._write_executable(
            self.package / "clipman_server.py",
            """
            #!/usr/bin/env python3
            import json
            import os
            import sys
            from pathlib import Path

            args = sys.argv[1:]
            command_log = os.environ.get("SERVER_COMMAND_LOG")
            if command_log:
                with Path(command_log).open("a", encoding="utf-8") as stream:
                    stream.write("server " + " ".join(args) + "\\n")
            if os.environ.get("SERVER_FAIL_MAINTENANCE") == "1" and (
                "--delete-database" in args or "--prune-databases-days" in args
            ):
                raise SystemExit(7)
            config = Path(args[args.index("--config") + 1])
            if "--version" in args:
                print("2.6.3")
            elif "--write-connection-info" in args:
                config.parent.mkdir(parents=True, exist_ok=True)
                if not config.exists():
                    config.write_text(
                        json.dumps({"Host": "127.0.0.1", "Port": 49152, "Token": "test-token"}),
                        encoding="utf-8",
                    )
            """,
        )
        self._write_executable(
            self.package / "clipman_server_updater.py",
            """
            #!/usr/bin/env python3
            import os
            from pathlib import Path

            log = os.environ.get("UPDATER_ENV_LOG")
            if log:
                Path(log).write_text(os.environ.get("CLIPMAN_SERVER_INIT_SYSTEM", ""), encoding="utf-8")
            """,
        )
        (self.package / "Manual.html").write_text("manual", encoding="utf-8")
        (self.package / "LICENSE.txt").write_text("license", encoding="utf-8")
        self.command_log = self.root / "commands.log"
        self._write_executable(
            self.fake_bin / "xbps-query",
            """
            #!/usr/bin/env sh
            exit 0
            """,
        )
        self._write_executable(
            self.fake_bin / "sv",
            """
            #!/usr/bin/env sh
            printf 'sv %s\n' "$*" >> "$COMMAND_LOG"
            exit 0
            """,
        )
        self._write_executable(
            self.fake_bin / "systemctl",
            """
            #!/usr/bin/env sh
            printf 'systemctl %s\n' "$*" >> "$COMMAND_LOG"
            case "$*" in
              *list-unit-files*) printf 'clipman-server.service enabled\n' ;;
            esac
            exit 0
            """,
        )
        self._write_executable(
            self.fake_bin / "loginctl",
            """
            #!/usr/bin/env sh
            printf 'loginctl %s\n' "$*" >> "$COMMAND_LOG"
            case "$1" in
              show-user)
                if [ -f "$LINGER_MARKER" ]; then
                  printf 'yes\n'
                else
                  printf 'no\n'
                fi
                ;;
              --no-ask-password)
                [ "${LINGER_ENABLE_FAIL:-0}" = "1" ] && exit 1
                [ "$2" = "enable-linger" ] && : > "$LINGER_MARKER"
                ;;
            esac
            exit 0
            """,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_executable(self, path: Path, content: str) -> None:
        path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _base_environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(self.root / "home"),
                "PATH": str(self.fake_bin) + os.pathsep + environment.get("PATH", ""),
                "COMMAND_LOG": str(self.command_log),
                "SERVER_COMMAND_LOG": str(self.command_log),
                "LINGER_MARKER": str(self.root / "linger-enabled"),
                "CLIPMAN_SERVER_APP_DIR": str(self.root / "installed" / "app"),
                "CLIPMAN_SERVER_BIN_DIR": str(self.root / "installed" / "bin"),
                "CLIPMAN_SERVER_CONFIG_DIR": str(self.root / "installed" / "config"),
            }
        )
        return environment

    def _run(self, command: list[str], environment: dict[str, str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            env=environment,
            check=check,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    @staticmethod
    def _mark_supervised(service: Path) -> None:
        (service / "supervise").mkdir(parents=True, exist_ok=True)
        (service / "supervise" / "ok").touch()

    def test_user_runit_install_and_helper_commands(self) -> None:
        environment = self._base_environment()
        service_root = self.root / "home" / ".config" / "service"
        environment.update(
            {
                "CLIPMAN_SERVER_INIT_SYSTEM": "runit",
                "CLIPMAN_SERVER_SERVICE_DIR": str(service_root),
            }
        )
        installer = self.linux / "install-clipman-server.sh"
        self._run(["sh", str(installer)], environment)

        server_service = service_root / "clipman-server"
        update_service = service_root / "clipman-server-update"
        helper = Path(environment["CLIPMAN_SERVER_BIN_DIR"]) / "clipmanserver"
        self.assertTrue((server_service / "run").is_file())
        self.assertTrue((server_service / "down").is_file())
        self.assertTrue((update_service / "run").is_file())
        self.assertTrue((update_service / "down").is_file())
        self.assertIn("CLIPMAN_SERVER_INIT_SYSTEM=\"$INIT_SYSTEM\"", helper.read_text(encoding="utf-8"))

        self._mark_supervised(server_service)
        self._mark_supervised(update_service)
        self._run([str(helper), "start"], environment)
        self.assertFalse((server_service / "down").exists())
        self._run([str(helper), "stop"], environment)
        self.assertTrue((server_service / "down").is_file())
        self._run([str(helper), "enable-auto-updates"], environment)
        self.assertFalse((update_service / "down").exists())
        self._run([str(helper), "disable-auto-updates"], environment)
        self.assertTrue((update_service / "down").is_file())
        self._run([str(helper), "update-status"], environment)
        self._run([str(helper), "delete", "test-database-id"], environment)
        self._run([str(helper), "setup-link", "12", "3"], environment)
        self._run([str(helper), "revoke-setup-link"], environment)

        failed_maintenance_environment = environment.copy()
        failed_maintenance_environment["SERVER_FAIL_MAINTENANCE"] = "1"
        failed_maintenance = self._run(
            [str(helper), "force-delete", "test-database-id"],
            failed_maintenance_environment,
            check=False,
        )
        self.assertEqual(7, failed_maintenance.returncode)

        updater_log = self.root / "updater-init.txt"
        update_environment = environment.copy()
        update_environment["UPDATER_ENV_LOG"] = str(updater_log)
        self._run([str(helper), "update", "--yes"], update_environment)
        self.assertEqual("runit", updater_log.read_text(encoding="utf-8"))
        commands = self.command_log.read_text(encoding="utf-8")
        self.assertIn(f"sv -w 15 start {server_service}", commands)
        self.assertIn(f"sv -w 15 stop {server_service}", commands)
        self.assertIn("server --config", commands)
        self.assertIn("--delete-database test-database-id --confirm", commands)
        self.assertIn("--create-setup-link --setup-minutes 12 --setup-downloads 3", commands)
        self.assertIn("--revoke-setup-link", commands)
        self.assertGreaterEqual(commands.count(f"sv -w 15 start {server_service}"), 3)

    def test_user_systemd_behavior_remains_available(self) -> None:
        environment = self._base_environment()
        service_root = self.root / "home" / ".config" / "systemd" / "user"
        environment.update(
            {
                "CLIPMAN_SERVER_INIT_SYSTEM": "systemd",
                "CLIPMAN_SERVER_SERVICE_DIR": str(service_root),
            }
        )
        self._run(["sh", str(self.linux / "install-clipman-server.sh")], environment)

        service = service_root / "clipman-server.service"
        timer = service_root / "clipman-server-update.timer"
        helper = Path(environment["CLIPMAN_SERVER_BIN_DIR"]) / "clipmanserver"
        self.assertTrue(service.is_file())
        self.assertTrue(timer.is_file())
        self.assertIn('ExecStart="' + environment["CLIPMAN_SERVER_BIN_DIR"], service.read_text(encoding="utf-8"))
        self.assertTrue(Path(environment["LINGER_MARKER"]).is_file())
        self._run([str(helper), "start"], environment)
        status = self._run([str(helper), "status"], environment)
        self.assertIn("Start at boot without login: enabled", status.stdout)
        updater_log = self.root / "systemd-updater-init.txt"
        update_environment = environment.copy()
        update_environment["UPDATER_ENV_LOG"] = str(updater_log)
        self._run([str(helper), "update", "--yes"], update_environment)
        self.assertEqual("systemd", updater_log.read_text(encoding="utf-8"))
        commands = self.command_log.read_text(encoding="utf-8")
        self.assertEqual(1, commands.count("loginctl --no-ask-password enable-linger"))

    def test_user_systemd_install_warns_when_linger_requires_administrator(self) -> None:
        environment = self._base_environment()
        environment.update(
            {
                "CLIPMAN_SERVER_INIT_SYSTEM": "systemd",
                "CLIPMAN_SERVER_SERVICE_DIR": str(self.root / "home" / ".config" / "systemd" / "user"),
                "LINGER_ENABLE_FAIL": "1",
            }
        )

        installed = self._run(["sh", str(self.linux / "install-clipman-server.sh")], environment)
        self.assertIn("systemd user lingering is not enabled", installed.stdout)
        self.assertIn("sudo loginctl enable-linger", installed.stdout)
        self.assertFalse(Path(environment["LINGER_MARKER"]).exists())

        helper = Path(environment["CLIPMAN_SERVER_BIN_DIR"]) / "clipmanserver"
        status = self._run([str(helper), "status"], environment)
        self.assertIn("Start at boot without login: disabled", status.stdout)

    def test_system_runit_helper_preserves_service_and_rejects_conflicting_link(self) -> None:
        self._write_executable(
            self.fake_bin / "id",
            """
            #!/usr/bin/env sh
            if [ "${1:-}" = "-u" ]; then printf '0\n'; else exec /usr/bin/id "$@"; fi
            """,
        )
        app = self.root / "system" / "app"
        config = self.root / "system" / "config" / "settings.json"
        service_root = self.root / "system" / "sv"
        active_root = self.root / "system" / "active"
        service = service_root / "clipman-public"
        helper = self.root / "system" / "sbin" / "clipmanserver"
        launcher = self.root / "system" / "libexec" / "clipman-server-managed"
        manager = self.root / "system" / "manager.conf"
        app.mkdir(parents=True)
        config.parent.mkdir(parents=True)
        service.mkdir(parents=True)
        active_root.mkdir(parents=True)
        self._write_executable(
            app / "clipman_server.py",
            """
            #!/usr/bin/env python3
            import os
            import sys
            from pathlib import Path
            log = os.environ.get("SERVER_COMMAND_LOG")
            if log:
                with Path(log).open("a", encoding="utf-8") as stream:
                    stream.write("server " + " ".join(sys.argv[1:]) + "\\n")
            """,
        )
        (app / "clipman_server_updater.py").write_text("updater", encoding="utf-8")
        config.write_text("{}", encoding="utf-8")
        self._write_executable(service / "run", "#!/usr/bin/env sh\nexit 0\n")
        original_run = (service / "run").read_bytes()
        self._mark_supervised(service)

        environment = self._base_environment()
        environment.update(
            {
                "CLIPMAN_SERVER_INIT_SYSTEM": "runit",
                "CLIPMAN_SERVER_APP_DIR": str(app),
                "CLIPMAN_SERVER_CONFIG_FILE": str(config),
                "CLIPMAN_SERVER_SERVICE": "clipman-public",
                "CLIPMAN_SERVER_SERVICE_FILE": str(service),
                "CLIPMAN_SERVER_HELPER": str(helper),
                "CLIPMAN_SERVER_LAUNCHER": str(launcher),
                "CLIPMAN_SERVER_MANAGER_CONFIG": str(manager),
                "CLIPMAN_SERVER_SYSTEMD_DIR": str(self.root / "system" / "systemd"),
                "CLIPMAN_SERVER_SYSTEMCTL": str(self.fake_bin / "systemctl"),
                "CLIPMAN_SERVER_SV": str(self.fake_bin / "sv"),
                "CLIPMAN_SERVER_RUNIT_SERVICE_DIR": str(service_root),
                "CLIPMAN_SERVER_RUNIT_ACTIVE_DIR": str(active_root),
            }
        )
        installer = self.linux / "install-clipman-server-system-helper.sh"
        self._run(["sh", str(installer)], environment)
        self.assertEqual(original_run, (service / "run").read_bytes())
        self.assertTrue((service_root / "clipman-public-update" / "down").is_file())

        wrong_service = service_root / "wrong"
        wrong_service.mkdir()
        (active_root / "clipman-public").symlink_to(wrong_service)
        failed = self._run([str(helper), "start"], environment, check=False)
        self.assertNotEqual(0, failed.returncode)
        self.assertIn("Refusing to replace an existing runit service link", failed.stdout)

        (active_root / "clipman-public").unlink()
        self._run([str(helper), "start"], environment)
        self.assertTrue((active_root / "clipman-public").samefile(service))
        self._run([str(helper), "delete", "test-database-id"], environment)
        self._run([str(helper), "setup-link", "8", "2"], environment)
        self._run([str(helper), "revoke-setup-link"], environment)
        commands = self.command_log.read_text(encoding="utf-8")
        self.assertIn(f"sv -w 15 stop {service}", commands)
        self.assertIn(f"sv -w 15 start {service}", commands)
        self.assertIn("--delete-database test-database-id --confirm", commands)
        self.assertIn("--create-setup-link --setup-minutes 8 --setup-downloads 2", commands)
        self.assertIn("--revoke-setup-link", commands)


if __name__ == "__main__":
    unittest.main()
