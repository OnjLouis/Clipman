#!/usr/bin/env python3
"""Safe updater for standalone Linux Clipman Server installations."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Optional, Tuple


RELEASE_API = "https://api.github.com/repos/OnjLouis/Clipman/releases?per_page=100"
SERVER_TAG_PATTERN = re.compile(r"^server-v(?P<version>\d+\.\d+(?:\.\d+){0,2})$", re.IGNORECASE)
MAX_DOWNLOAD_BYTES = 250 * 1024 * 1024
MAX_EXTRACTED_BYTES = 600 * 1024 * 1024
MAX_ZIP_ENTRIES = 2_000
MANAGED_PROGRAM_FILES = (
    "clipman_server.py",
    "clipman_server_updater.py",
    "Manual.html",
    "LICENSE.txt",
)


def version_tuple(value: str) -> Tuple[int, ...]:
    clean = value.strip().lstrip("vV")
    parts = clean.split(".")
    if len(parts) < 2 or len(parts) > 4 or any(not part.isdigit() for part in parts):
        raise ValueError(f"Invalid stable version: {value}")
    return tuple(int(part) for part in parts)


def read_releases(api_url: str = RELEASE_API) -> List[Dict[str, Any]]:
    request = urllib.request.Request(
        api_url,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "Clipman-Server-Linux-Updater"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.geturl().split(":", 1)[0].lower() != "https":
            raise RuntimeError("The update service redirected outside HTTPS.")
        payload = response.read(2 * 1024 * 1024 + 1)
    if len(payload) > 2 * 1024 * 1024:
        raise RuntimeError("The update service response was unexpectedly large.")
    releases = json.loads(payload.decode("utf-8"))
    if not isinstance(releases, list):
        raise RuntimeError("The update service returned an unexpected response.")
    return releases


def find_update(releases: Iterable[Dict[str, Any]], current_version: str) -> Optional[Tuple[str, Dict[str, Any]]]:
    candidates: List[Tuple[str, Dict[str, Any]]] = []
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        match = SERVER_TAG_PATTERN.fullmatch(str(release.get("tag_name", "")).strip())
        if match:
            candidates.append((match.group("version"), release))
    if not candidates:
        return None
    version, release = max(candidates, key=lambda item: version_tuple(item[0]))
    if version_tuple(version) <= version_tuple(current_version):
        return None
    expected = f"ClipmanServer-{version}.zip".lower()
    for asset in release.get("assets", []):
        if str(asset.get("name", "")).lower() == expected:
            url = str(asset.get("browser_download_url", ""))
            if not url.lower().startswith("https://"):
                raise RuntimeError("The server update download did not use HTTPS.")
            return version, asset
    raise RuntimeError(f"Clipman Server {version} is available, but {expected} is missing.")


def download_asset(asset: Dict[str, Any], destination: Path) -> None:
    request = urllib.request.Request(
        str(asset["browser_download_url"]),
        headers={"Accept": "application/octet-stream", "User-Agent": "Clipman-Server-Linux-Updater"},
    )
    digest = hashlib.sha256()
    total = 0
    with urllib.request.urlopen(request, timeout=90) as response, destination.open("wb") as output:
        if response.geturl().split(":", 1)[0].lower() != "https":
            raise RuntimeError("The server update download redirected outside HTTPS.")
        while True:
            block = response.read(64 * 1024)
            if not block:
                break
            total += len(block)
            if total > MAX_DOWNLOAD_BYTES:
                raise RuntimeError("The server update package was unexpectedly large.")
            digest.update(block)
            output.write(block)
    expected_digest = str(asset.get("digest") or "").strip().lower()
    verify_sha256_digest(expected_digest, digest.hexdigest())


def verify_sha256_digest(expected_digest: str, actual_hex: str) -> None:
    actual_digest = "sha256:" + actual_hex.lower()
    if not expected_digest.startswith("sha256:") or len(expected_digest) != 71:
        raise RuntimeError("GitHub did not provide a valid SHA-256 digest for the server update.")
    if expected_digest != actual_digest:
        raise RuntimeError("The downloaded server update failed its SHA-256 check.")


def safe_extract(zip_path: Path, destination: Path) -> None:
    with zipfile.ZipFile(zip_path) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_ZIP_ENTRIES:
            raise RuntimeError("The server update package contains too many files.")
        if sum(entry.file_size for entry in entries) > MAX_EXTRACTED_BYTES:
            raise RuntimeError("The extracted server update would be unexpectedly large.")
        for entry in entries:
            path = PurePosixPath(entry.filename.replace("\\", "/"))
            if path.is_absolute() or ".." in path.parts:
                raise RuntimeError("The server update package contains an unsafe path.")
        archive.extractall(destination)


def locate_package_root(extracted: Path, expected_version: str) -> Path:
    manifests = list(extracted.rglob("manifest.json"))
    if len(manifests) != 1:
        raise RuntimeError("The server update package did not contain one manifest.")
    root = manifests[0].parent
    manifest = json.loads(manifests[0].read_text(encoding="utf-8"))
    if manifest.get("Name") != "Clipman Server" or manifest.get("Version") != expected_version:
        raise RuntimeError("The server update manifest did not match the requested release.")
    required = [root / "clipman_server.py", root / "clipman_server_updater.py", root / "Linux" / "install-clipman-server.sh"]
    if any(not path.is_file() for path in required):
        raise RuntimeError("The server update package is missing Linux program files.")
    return root


def copy_path(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, destination, copy_function=shutil.copy2)
    else:
        shutil.copy2(source, destination)


def remove_path(path: Path) -> None:
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def restore_program_files(app_dir: Path, helper: Path, launcher: Path, service_file: Path, backup: Path) -> None:
    for path in (app_dir, helper, launcher, service_file):
        remove_path(path)
    copy_path(backup / "app", app_dir)
    copy_path(backup / "clipmanserver", helper)
    copy_path(backup / "clipman-server", launcher)
    copy_path(backup / "clipman-server.service", service_file)


def snapshot_managed_program_files(app_dir: Path) -> Dict[Path, Optional[Tuple[bytes, int, int, int]]]:
    snapshots: Dict[Path, Optional[Tuple[bytes, int, int, int]]] = {}
    for name in MANAGED_PROGRAM_FILES:
        path = app_dir / name
        if not path.exists():
            snapshots[path] = None
            continue
        status = path.stat()
        snapshots[path] = (path.read_bytes(), status.st_mode & 0o777, status.st_uid, status.st_gid)
    return snapshots


def write_managed_file(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        status = destination.stat()
        mode, owner, group = status.st_mode & 0o777, status.st_uid, status.st_gid
    else:
        status = destination.parent.stat()
        mode = 0o700 if destination.suffix == ".py" else 0o644
        owner, group = status.st_uid, status.st_gid
    temporary = destination.with_name(destination.name + ".update")
    shutil.copyfile(source, temporary)
    os.chmod(temporary, mode)
    if hasattr(os, "chown"):
        os.chown(temporary, owner, group)
    temporary.replace(destination)


def install_managed_program_files(package_root: Path, app_dir: Path) -> None:
    for name in MANAGED_PROGRAM_FILES:
        source = package_root / name
        if source.is_file():
            write_managed_file(source, app_dir / name)


def restore_managed_program_files(snapshots: Dict[Path, Optional[Tuple[bytes, int, int, int]]]) -> None:
    for path, snapshot in snapshots.items():
        if snapshot is None:
            path.unlink(missing_ok=True)
            continue
        content, mode, owner, group = snapshot
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".rollback")
        temporary.write_bytes(content)
        os.chmod(temporary, mode)
        if hasattr(os, "chown"):
            os.chown(temporary, owner, group)
        temporary.replace(path)


def run(command: Iterable[str], *, env: Optional[Dict[str, str]] = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(list(command), env=env, check=check, text=True)


def health_connection(config: Dict[str, Any]) -> Tuple[str, str, str, int]:
    secure = bool(str(config.get("CertFile", "")).strip() and str(config.get("KeyFile", "")).strip())
    bind_host = str(config.get("Host") or "127.0.0.1").strip().strip("[]")
    if bind_host == "0.0.0.0":
        bind_host = "127.0.0.1"
    elif bind_host == "::":
        bind_host = "::1"
    certificate_host = str(config.get("AdvertiseHost") or bind_host).strip().strip("[]")
    if not bind_host or not certificate_host or any(character in certificate_host for character in "\r\n"):
        raise RuntimeError("The server settings contain an invalid health-check host.")
    return ("https" if secure else "http", bind_host, certificate_host, int(config.get("Port", 0)))


def health_url(config: Dict[str, Any]) -> str:
    scheme, bind_host, _certificate_host, port = health_connection(config)
    display_host = f"[{bind_host}]" if ":" in bind_host else bind_host
    return f"{scheme}://{display_host}:{port}/api/v1/health"


def read_health(config: Dict[str, Any], timeout: int = 3) -> Dict[str, Any]:
    scheme, bind_host, certificate_host, port = health_connection(config)
    if scheme == "http":
        with urllib.request.urlopen(health_url(config), timeout=timeout) as response:
            return json.loads(response.read(1024 * 1024).decode("utf-8"))

    ca_file = str(config.get("CaFile", "")).strip()
    context = ssl.create_default_context(cafile=ca_file or None)
    plain_socket = socket.create_connection((bind_host, port), timeout=timeout)
    try:
        with context.wrap_socket(plain_socket, server_hostname=certificate_host) as tls_socket:
            host_header = f"[{certificate_host}]" if ":" in certificate_host else certificate_host
            request = (
                "GET /api/v1/health HTTP/1.1\r\n"
                f"Host: {host_header}:{port}\r\n"
                "Accept: application/json\r\n"
                "Connection: close\r\n\r\n"
            )
            tls_socket.sendall(request.encode("ascii"))
            response = http.client.HTTPResponse(tls_socket)
            response.begin()
            if response.status != 200:
                raise RuntimeError(f"The health endpoint returned HTTP {response.status}.")
            return json.loads(response.read(1024 * 1024).decode("utf-8"))
    finally:
        plain_socket.close()


def wait_for_health(config_path: Path, seconds: int = 30) -> None:
    config = json.loads(config_path.read_text(encoding="utf-8-sig"))
    url = health_url(config)
    _scheme, _bind_host, certificate_host, _port = health_connection(config)
    deadline = time.monotonic() + seconds
    last_error: Optional[Exception] = None
    while time.monotonic() < deadline:
        try:
            payload = read_health(config)
            if payload.get("Status") == "ok":
                return
        except Exception as error:  # The service may still be starting.
            last_error = error
        time.sleep(1)
    identity = f" using TLS identity {certificate_host}" if url.startswith("https://") else ""
    raise RuntimeError(
        f"The updated server did not become healthy at its local listener {url}{identity}: "
        f"{last_error or 'unknown health response'}"
    )


def service_diagnostics(helper: Path) -> str:
    try:
        completed = subprocess.run(
            [str(helper), "status"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
        )
        output = (completed.stdout or "").strip()
        if not output:
            output = f"The status command exited with code {completed.returncode} without output."
    except (OSError, subprocess.SubprocessError) as error:
        output = f"The server status could not be collected: {error}"
    return output[-6000:]


def normalize_listen_host(value: str) -> str:
    host = str(value or "").strip()
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1].strip()
    if (
        not host
        or any(character.isspace() for character in host)
        or "/" in host
        or "\\" in host
        or "[" in host
        or "]" in host
    ):
        raise ValueError("The listening host must be an IP address or host name without a scheme, port, path, or spaces.")
    return host


def restore_configuration_files(files: Dict[Path, Optional[Tuple[bytes, int]]]) -> None:
    for path, snapshot in files.items():
        if snapshot is None:
            path.unlink(missing_ok=True)
            continue
        content, mode = snapshot
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".restore")
        temporary.write_bytes(content)
        os.chmod(temporary, mode)
        temporary.replace(path)


def change_listen_host(
    args: argparse.Namespace,
    requested_host: str,
    requested_advertised_host: Optional[str] = None,
) -> None:
    host = normalize_listen_host(requested_host)
    config_file = Path(args.config).expanduser().resolve()
    bin_dir = Path(args.bin_dir).expanduser().resolve()
    helper_path = getattr(args, "helper_path", None)
    launcher_path = getattr(args, "launcher_path", None)
    helper = Path(helper_path).expanduser().resolve() if helper_path else bin_dir / "clipmanserver"
    launcher = Path(launcher_path).expanduser().resolve() if launcher_path else bin_dir / "clipman-server"
    settings = json.loads(config_file.read_text(encoding="utf-8-sig"))
    old_host = str(settings.get("Host") or "127.0.0.1").strip()
    old_advertised = str(settings.get("AdvertiseHost") or "").strip()
    advertised = normalize_listen_host(requested_advertised_host) if requested_advertised_host else old_advertised
    if not requested_advertised_host and old_advertised == old_host:
        advertised = host
    if host in {"0.0.0.0", "::"} and advertised.strip("[]") in {"", "0.0.0.0", "::"}:
        raise ValueError(
            "A wildcard listener requires the DNS name or IP address clients use. "
            "Run: clipmanserver host <listening-address> <client-address>"
        )
    if host == old_host and (not requested_advertised_host or advertised == old_advertised):
        print(f"Clipman Server already listens on {host}.")
        return

    managed_files: Dict[Path, Optional[Tuple[bytes, int]]] = {
        config_file: (config_file.read_bytes(), config_file.stat().st_mode & 0o777),
        config_file.parent / "clipman-server-connection.txt": None,
        config_file.parent / "clipman-server-connection.clpconf": None,
    }
    for path in list(managed_files):
        if path != config_file and path.exists():
            managed_files[path] = (path.read_bytes(), path.stat().st_mode & 0o777)

    command = [str(launcher), "--host", host]
    if requested_advertised_host or old_advertised == old_host:
        command.extend(["--advertise-host", advertised])
    command.append("--write-connection-info")

    run([str(helper), "stop"], check=False)
    try:
        run(command)
        run([str(helper), "start"])
        wait_for_health(config_file)
    except Exception as error:
        diagnostics = service_diagnostics(helper)
        run([str(helper), "stop"], check=False)
        restore_configuration_files(managed_files)
        restart_error = ""
        try:
            run([str(helper), "start"])
            wait_for_health(config_file)
        except Exception as restore_error:
            restart_error = f"\nThe previous listener also failed to restart: {restore_error}"
        raise RuntimeError(
            f"The server could not use listening host {host}: {error}\n"
            f"Service status before restoration:\n{diagnostics}{restart_error}"
        ) from error

    settings = json.loads(config_file.read_text(encoding="utf-8-sig"))
    address = settings.get("AdvertiseHost") or settings.get("Host")
    print(f"Clipman Server now listens on {host}. Client connection address: {address}:{settings['Port']}.")


def install_update(args: argparse.Namespace, version: str, asset: Dict[str, Any]) -> None:
    if not args.yes:
        answer = input(f"Update Clipman Server {args.current_version} to {version}? [y/N] ").strip().lower()
        if answer not in {"y", "yes"}:
            print("Update cancelled.")
            return

    app_dir = Path(args.app_dir).expanduser().resolve()
    bin_dir = Path(args.bin_dir).expanduser().resolve()
    config_file = Path(args.config).expanduser().resolve()
    service_file = Path(args.service_file).expanduser().resolve()
    helper_path = getattr(args, "helper_path", None)
    helper = Path(helper_path).expanduser().resolve() if helper_path else bin_dir / "clipmanserver"
    launcher = bin_dir / "clipman-server"
    with tempfile.TemporaryDirectory(prefix="clipman-server-update-") as temporary:
        temp = Path(temporary)
        package_zip = temp / "server.zip"
        extracted = temp / "extracted"
        backup = temp / "backup"
        download_asset(asset, package_zip)
        safe_extract(package_zip, extracted)
        package_root = locate_package_root(extracted, version)

        managed_program_only = bool(getattr(args, "managed_program_only", False))
        managed_snapshots = snapshot_managed_program_files(app_dir) if managed_program_only else None
        if not managed_program_only:
            copy_path(app_dir, backup / "app")
            copy_path(helper, backup / "clipmanserver")
            copy_path(launcher, backup / "clipman-server")
            copy_path(service_file, backup / "clipman-server.service")

        run([str(helper), "stop"], check=False)
        try:
            if managed_program_only:
                install_managed_program_files(package_root, app_dir)
            else:
                environment = os.environ.copy()
                environment.update(
                    {
                        "CLIPMAN_SERVER_APP_DIR": str(app_dir),
                        "CLIPMAN_SERVER_BIN_DIR": str(bin_dir),
                        "CLIPMAN_SERVER_CONFIG_DIR": str(config_file.parent),
                    }
                )
                run(["sh", str(package_root / "Linux" / "install-clipman-server.sh")], env=environment)
            run([str(helper), "start"])
            wait_for_health(config_file)
        except Exception as error:
            diagnostics = service_diagnostics(helper)
            run([str(helper), "stop"], check=False)
            if managed_snapshots is not None:
                restore_managed_program_files(managed_snapshots)
            else:
                restore_program_files(app_dir, helper, launcher, service_file, backup)
            run([str(helper), "start"], check=False)
            raise RuntimeError(f"{error}\nService status before rollback:\n{diagnostics}") from error
    print(f"Clipman Server updated to {version} and passed its health check.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Safely update or reconfigure an installed Clipman Server.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="Check whether an update is available.")
    mode.add_argument("--install", action="store_true", help="Install an available update.")
    mode.add_argument("--set-host", metavar="ADDRESS", help="Change the listening host and verify the restarted server.")
    parser.add_argument("--yes", action="store_true", help="Install without a confirmation prompt.")
    parser.add_argument("--advertise-host", help="Address written to client connection files with --set-host.")
    parser.add_argument("--current-version", required=True)
    parser.add_argument("--app-dir", required=True)
    parser.add_argument("--bin-dir", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--service-file", required=True)
    parser.add_argument("--helper-path", help="Installed management helper used to stop, start, and inspect the server.")
    parser.add_argument("--launcher-path", help="Installed server launcher used for a listening-host change.")
    parser.add_argument(
        "--managed-program-only",
        action="store_true",
        help="Replace only packaged program files, preserving an externally managed service and helper.",
    )
    parser.add_argument("--release-api-url", default=RELEASE_API, help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.set_host is not None:
            change_listen_host(args, args.set_host, args.advertise_host)
            return 0
        releases = read_releases(args.release_api_url)
        update = find_update(releases, args.current_version)
        if update is None:
            print(f"Clipman Server is up to date. Current version: {args.current_version}.")
            return 0
        version, asset = update
        if args.check:
            print(f"Clipman Server {version} is available.")
            return 0
        install_update(args, version, asset)
        return 0
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        operation = "host change" if args.set_host is not None else "update"
        print(f"Clipman Server {operation} failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
