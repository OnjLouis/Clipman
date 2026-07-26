#!/usr/bin/env python3
import dataclasses
import hashlib
import json
import pathlib
import platform
import re
import shutil
import tarfile
import tempfile
import urllib.parse
import urllib.request


RELEASES_URL = "https://api.github.com/repos/OnjLouis/Clipman/releases?per_page=30"
MAX_DOWNLOAD_BYTES = 128 * 1024 * 1024


class UpdateError(Exception):
    pass


def trusted_download_url(value):
    parsed = urllib.parse.urlparse(str(value or ""))
    hostname = (parsed.hostname or "").casefold()
    return parsed.scheme == "https" and (
        hostname in ("github.com", "api.github.com") or
        hostname.endswith(".githubusercontent.com")
    )


@dataclasses.dataclass(frozen=True)
class UpdateCandidate:
    version: str
    release_url: str
    download_url: str
    asset_name: str
    digest: str
    size: int


def normalized_version(value):
    return str(value or "").strip().lstrip("vV")


def version_parts(value):
    return tuple(int(part) for part in re.findall(r"\d+", normalized_version(value)))


def normalized_architecture(value=None):
    machine = str(value or platform.machine()).strip().lower()
    return {
        "amd64": "x86_64", "x64": "x86_64",
        "arm64": "aarch64", "armv8": "aarch64",
    }.get(machine, machine)


def fetch_releases(timeout=20):
    request = urllib.request.Request(
        RELEASES_URL,
        headers={"Accept": "application/vnd.github+json", "User-Agent": "Clipman Linux updater"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read(4 * 1024 * 1024)
    except OSError as error:
        raise UpdateError(f"GitHub could not be reached: {error}") from error
    try:
        releases = json.loads(payload.decode("utf-8"))
    except (UnicodeError, ValueError) as error:
        raise UpdateError("GitHub returned an invalid release list.") from error
    if not isinstance(releases, list):
        raise UpdateError("GitHub returned an unexpected release list.")
    return releases


def find_update(current_version, releases=None, architecture=None):
    releases = fetch_releases() if releases is None else releases
    architecture = normalized_architecture(architecture)
    current = version_parts(current_version)
    candidates = []
    for release in releases:
        if not isinstance(release, dict) or release.get("draft") or release.get("prerelease"):
            continue
        version = normalized_version(release.get("tag_name"))
        parts = version_parts(version)
        if not parts or parts <= current:
            continue
        for asset in release.get("assets") or []:
            if not isinstance(asset, dict):
                continue
            name = str(asset.get("name") or "")
            lower = name.casefold()
            if not lower.startswith("clipman-linux-gui-") or not lower.endswith(f"-linux-{architecture}.tar.gz"):
                continue
            digest = str(asset.get("digest") or "").casefold()
            size = int(asset.get("size") or 0)
            download_url = str(asset.get("browser_download_url") or "")
            release_url = str(release.get("html_url") or "")
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
                continue
            if not 0 < size <= MAX_DOWNLOAD_BYTES:
                continue
            if not trusted_download_url(download_url):
                continue
            candidates.append(UpdateCandidate(version, release_url, download_url, name, digest, size))
    return max(candidates, key=lambda item: version_parts(item.version), default=None)


def _safe_members(archive):
    members = archive.getmembers()
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk():
            raise UpdateError("The update archive contains an unsafe path or link.")
        if not (member.isdir() or member.isreg()) or member.mode & 0o7000:
            raise UpdateError("The update archive contains an unsupported file type or permission.")
    return members


def stage_update(candidate, opener=None):
    temporary = pathlib.Path(tempfile.mkdtemp(prefix="clipman-linux-update-"))
    archive_path = temporary / candidate.asset_name
    extract_path = temporary / "extract"
    extract_path.mkdir()
    opener = opener or urllib.request.urlopen
    request = urllib.request.Request(candidate.download_url, headers={"User-Agent": "Clipman Linux updater"})
    digest = hashlib.sha256()
    received = 0
    try:
        with opener(request, timeout=120) as response, archive_path.open("wb") as output:
            final_url = response.geturl() if hasattr(response, "geturl") else candidate.download_url
            if not trusted_download_url(final_url):
                raise UpdateError("GitHub redirected the update download to an untrusted address.")
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                received += len(block)
                if received > MAX_DOWNLOAD_BYTES or received > candidate.size:
                    raise UpdateError("The update download is larger than GitHub reported.")
                digest.update(block)
                output.write(block)
        if received != candidate.size:
            raise UpdateError("The update download size does not match GitHub's release data.")
        if digest.hexdigest() != candidate.digest.split(":", 1)[1]:
            raise UpdateError("The update download failed its SHA-256 verification.")
        try:
            with tarfile.open(archive_path, "r:gz") as archive:
                archive.extractall(extract_path, members=_safe_members(archive))
        except (tarfile.TarError, OSError) as error:
            raise UpdateError(f"The update archive could not be extracted: {error}") from error
        roots = [path.parent for path in extract_path.rglob("VERSION") if (path.parent / "install.sh").is_file()]
        if len(roots) != 1:
            raise UpdateError("The update archive does not contain one recognizable Clipman package.")
        package = roots[0]
        packaged_version = normalized_version((package / "VERSION").read_text(encoding="utf-8"))
        if packaged_version != normalized_version(candidate.version):
            raise UpdateError("The packaged version does not match the GitHub release.")
        required = [
            "clipman.py", "clipman-hotkeys.py", "clipman-updater.py", "update_service.py",
            "install.sh", "libexec/clipman-gui-backend", "Manual.html", "LICENSE.txt",
            "BUILD_STAMP",
        ]
        if any(not (package / name).is_file() for name in required):
            raise UpdateError("The update package is incomplete.")
        (package / "install.sh").chmod(0o755)
        return package, temporary
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
