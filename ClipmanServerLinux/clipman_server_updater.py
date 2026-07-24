#!/usr/bin/env python3
"""Safe updater for standalone Linux Clipman Server installations."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, Optional, Tuple


RELEASE_API = "https://api.github.com/repos/OnjLouis/Clipman/releases/latest"
MAX_DOWNLOAD_BYTES = 250 * 1024 * 1024
MAX_EXTRACTED_BYTES = 600 * 1024 * 1024
MAX_ZIP_ENTRIES = 2_000


def version_tuple(value: str) -> Tuple[int, ...]:
    clean = value.strip().lstrip("vV")
    parts = clean.split(".")
    if len(parts) < 2 or len(parts) > 4 or any(not part.isdigit() for part in parts):
        raise ValueError(f"Invalid stable version: {value}")
    return tuple(int(part) for part in parts)


def read_release(api_url: str = RELEASE_API) -> Dict[str, Any]:
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
    release = json.loads(payload.decode("utf-8"))
    if release.get("draft") or release.get("prerelease"):
        raise RuntimeError("The latest release is not a stable public release.")
    return release


def find_update(release: Dict[str, Any], current_version: str) -> Optional[Tuple[str, Dict[str, Any]]]:
    version = str(release.get("tag_name", "")).strip().lstrip("vV")
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


def run(command: Iterable[str], *, env: Optional[Dict[str, str]] = None, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(list(command), env=env, check=check, text=True)


def health_url(config: Dict[str, Any]) -> str:
    secure = bool(str(config.get("CertFile", "")).strip() and str(config.get("KeyFile", "")).strip())
    host = str(config.get("AdvertiseHost") or config.get("Host") or "127.0.0.1").strip()
    if host in {"0.0.0.0", "::"}:
        host = "127.0.0.1"
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return f"{'https' if secure else 'http'}://{host}:{int(config.get('Port', 0))}/api/v1/health"


def wait_for_health(config_path: Path, seconds: int = 30) -> None:
    config = json.loads(config_path.read_text(encoding="utf-8-sig"))
    url = health_url(config)
    context = None
    if url.startswith("https://"):
        ca_file = str(config.get("CaFile", "")).strip()
        context = ssl.create_default_context(cafile=ca_file or None)
    deadline = time.monotonic() + seconds
    last_error: Optional[Exception] = None
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=3, context=context) as response:
                payload = json.loads(response.read(1024 * 1024).decode("utf-8"))
            if payload.get("Status") == "ok":
                return
        except Exception as error:  # The service may still be starting.
            last_error = error
        time.sleep(1)
    raise RuntimeError(f"The updated server did not become healthy: {last_error or 'unknown health response'}")


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
    helper = bin_dir / "clipmanserver"
    launcher = bin_dir / "clipman-server"
    with tempfile.TemporaryDirectory(prefix="clipman-server-update-") as temporary:
        temp = Path(temporary)
        package_zip = temp / "server.zip"
        extracted = temp / "extracted"
        backup = temp / "backup"
        download_asset(asset, package_zip)
        safe_extract(package_zip, extracted)
        package_root = locate_package_root(extracted, version)

        copy_path(app_dir, backup / "app")
        copy_path(helper, backup / "clipmanserver")
        copy_path(launcher, backup / "clipman-server")
        copy_path(service_file, backup / "clipman-server.service")

        run([str(helper), "stop"], check=False)
        try:
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
        except Exception:
            run([str(helper), "stop"], check=False)
            restore_program_files(app_dir, helper, launcher, service_file, backup)
            run([str(helper), "start"], check=False)
            raise
    print(f"Clipman Server updated to {version} and passed its health check.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check for and safely install Clipman Server updates.")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="Check whether an update is available.")
    mode.add_argument("--install", action="store_true", help="Install an available update.")
    parser.add_argument("--yes", action="store_true", help="Install without a confirmation prompt.")
    parser.add_argument("--current-version", required=True)
    parser.add_argument("--app-dir", required=True)
    parser.add_argument("--bin-dir", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--service-file", required=True)
    parser.add_argument("--release-api-url", default=RELEASE_API, help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        release = read_release(args.release_api_url)
        update = find_update(release, args.current_version)
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
        print(f"Clipman Server update failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
