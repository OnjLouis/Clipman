#!/usr/bin/env python3
"""Small Clipman history server for Linux, Raspberry Pi, and VPS use."""

from __future__ import annotations

import argparse
import base64
import http.server
import ipaddress
import json
import logging
from logging.handlers import RotatingFileHandler
import os
import re
import secrets
import shutil
import signal
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from threading import Event, Lock, Thread
from typing import Any, Dict, List, Tuple
from urllib.parse import parse_qs, urlparse
from urllib.parse import unquote


APP_VERSION = "2.1.0"
DEFAULT_CONFIG = "clipman-server-settings.json"
DATABASE_LOG_PATTERN = re.compile(r"(/api/v1/database/)[^\s\"?]+")
METADATA_FILE = "clipman-server-metadata.json"
METADATA_TOUCH_INTERVAL_MS = 5 * 60 * 1000


def now_ms() -> int:
    return int(time.time() * 1000)


def random_high_port() -> int:
    return 49152 + secrets.randbelow(65535 - 49152)


def random_token() -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(32)).decode("ascii").rstrip("=")


def make_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def make_private_file(path: Path) -> None:
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def revision(path: Path) -> str:
    if not path.exists():
        return ""
    stat = path.stat()
    token = f"{stat.st_size:x}-{stat.st_mtime_ns:x}".encode("ascii")
    return base64.urlsafe_b64encode(token).decode("ascii").rstrip("=")


def modified_ms(path: Path) -> int:
    return int(path.stat().st_mtime * 1000) if path.exists() else 0


def load_settings(config_path: Path) -> Tuple[Dict[str, Any], bool]:
    created = not config_path.exists()
    if config_path.exists():
        with config_path.open("r", encoding="utf-8-sig") as f:
            settings = json.load(f)
    else:
        settings = {}

    base_dir = config_path.parent
    data_dir = default_data_dir()
    settings.setdefault("Host", "127.0.0.1")
    settings.setdefault("AdvertiseHost", "")
    settings.setdefault("Port", random_high_port())
    settings.setdefault("DatabasePath", str(data_dir / "clipman-history.clipdb"))
    settings.setdefault("AuthToken", random_token())
    settings.setdefault("LogPath", str(default_log_path()))
    settings.setdefault("CertFile", "")
    settings.setdefault("KeyFile", "")
    settings.setdefault("CaFile", "")
    settings.setdefault("AllowInsecureRemote", False)
    settings.setdefault("BackupIntervalMinutes", 60)
    settings.setdefault("BackupRetentionHours", 24)
    settings.setdefault("MaxBackups", 48)
    settings.setdefault("CreateBackupBeforeEveryUpload", True)
    settings.setdefault("DatabasePruneDays", 0)
    settings.setdefault("DatabasePruneIntervalHours", 24)
    settings.setdefault("MaxDatabaseBytes", 64 * 1024 * 1024)
    save_settings(config_path, settings)
    return settings, created


def default_data_dir() -> Path:
    if os.name == "nt":
        root = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
        if root:
            return Path(root).expanduser() / "Clipman Server"
        return Path.home() / "AppData" / "Local" / "Clipman Server"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Clipman Server"
    root = os.environ.get("XDG_DATA_HOME", "")
    if root:
        return Path(root).expanduser() / "clipman-server"
    return Path.home() / ".local" / "share" / "clipman-server"


def default_state_dir() -> Path:
    if os.name == "nt":
        return default_data_dir()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Logs" / "Clipman Server"
    root = os.environ.get("XDG_STATE_HOME", "")
    if root:
        return Path(root).expanduser() / "clipman-server"
    return Path.home() / ".local" / "state" / "clipman-server"


def default_log_path() -> Path:
    return default_state_dir() / "logs" / "clipman-server.log"


def has_tls(settings: Dict[str, Any]) -> bool:
    return bool(str(settings.get("CertFile", "")).strip() and str(settings.get("KeyFile", "")).strip())


def create_tls_context(settings: Dict[str, Any]) -> ssl.SSLContext | None:
    certificate = str(settings.get("CertFile", "")).strip()
    key = str(settings.get("KeyFile", "")).strip()
    if bool(certificate) != bool(key):
        raise SystemExit("Clipman Server HTTPS requires both CertFile and KeyFile. No listener was started.")
    if not certificate:
        return None
    certificate_path = Path(certificate).expanduser()
    key_path = Path(key).expanduser()
    if not certificate_path.is_file():
        raise SystemExit(f"Clipman Server HTTPS certificate was not found: {certificate_path}")
    if not key_path.is_file():
        raise SystemExit(f"Clipman Server HTTPS private key was not found: {key_path}")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    try:
        context.load_cert_chain(str(certificate_path), str(key_path))
    except (OSError, ssl.SSLError) as error:
        raise SystemExit(f"Clipman Server could not load its HTTPS certificate and key: {error}")
    return context


def listen_scheme(settings: Dict[str, Any]) -> str:
    return "https" if has_tls(settings) else "http"


def listen_prefix(settings: Dict[str, Any]) -> str:
    return f"{listen_scheme(settings)}://{settings['Host']}:{settings['Port']}/"


def advertised_host(settings: Dict[str, Any]) -> str:
    value = str(settings.get("AdvertiseHost", "")).strip()
    return value or str(settings["Host"])


def is_local_or_private_host(host: str) -> bool:
    host = (host or "").strip().lower()
    if host in {"localhost", "localhost.localdomain"}:
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    if address.is_loopback or address.is_link_local or address.is_private:
        return True
    if isinstance(address, ipaddress.IPv4Address) and address in ipaddress.ip_network("100.64.0.0/10"):
        return True
    return False


def validate_network_security(settings: Dict[str, Any]) -> None:
    host = str(settings.get("Host", "")).strip()
    if has_tls(settings):
        return
    if is_local_or_private_host(host):
        return
    if bool(settings.get("AllowInsecureRemote", False)):
        logging.warning("Insecure remote HTTP listener allowed by configuration. Use only behind a VPN, firewall, or reverse proxy.")
        return
    raise SystemExit(
        "Refusing to start an insecure remote Clipman Server listener.\n"
        "Use --cert-file and --key-file for direct HTTPS, run behind a TLS reverse proxy, "
        "bind to localhost/private VPN address, or pass --allow-insecure-remote only for deliberate private-network testing."
    )


def configure_logging(settings: Dict[str, Any]) -> None:
    log_path = Path(str(settings.get("LogPath", default_log_path()))).expanduser()
    make_private_dir(log_path.parent)
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(logging.INFO)
    formatter = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    file_handler = RotatingFileHandler(log_path, maxBytes=1024 * 1024, backupCount=5, encoding="utf-8")
    file_handler.setFormatter(formatter)
    root.addHandler(file_handler)
    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(formatter)
    root.addHandler(stream_handler)
    make_private_file(log_path)


def save_settings(config_path: Path, settings: Dict[str, Any]) -> None:
    make_private_dir(config_path.parent)
    tmp = config_path.with_suffix(config_path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, sort_keys=True)
    make_private_file(tmp)
    tmp.replace(config_path)
    make_private_file(config_path)


def find_openssl() -> str:
    candidates = [shutil.which("openssl")]
    if os.name == "nt":
        program_files = [os.environ.get("ProgramFiles", ""), os.environ.get("ProgramFiles(x86)", "")]
        for root in program_files:
            if root:
                candidates.extend([
                    str(Path(root) / "Git" / "mingw64" / "bin" / "openssl.exe"),
                    str(Path(root) / "Git" / "usr" / "bin" / "openssl.exe"),
                ])
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return candidate
    raise RuntimeError(
        "OpenSSL was not found. Install OpenSSL (Git for Windows includes it), then try again."
    )


def run_openssl(openssl: str, arguments: List[str]) -> str:
    completed = subprocess.run(
        [openssl] + arguments,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise RuntimeError(f"OpenSSL failed: {detail or 'unknown error'}")
    return completed.stdout.strip()


def warn_if_tls_certificate_expiring(settings: Dict[str, Any], days: int = 30) -> None:
    certificate = str(settings.get("CertFile", "")).strip()
    if not certificate:
        return
    try:
        openssl = find_openssl()
        completed = subprocess.run(
            [openssl, "x509", "-in", certificate, "-noout", "-checkend", str(days * 24 * 60 * 60)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if completed.returncode == 1:
            logging.warning(
                "The Clipman Server HTTPS certificate expires within %s days. Renew it before clients lose access.",
                days,
            )
        elif completed.returncode != 0:
            detail = (completed.stderr or "").strip()
            logging.warning("Could not check the Clipman Server HTTPS certificate expiry: %s", detail or "unknown error")
    except Exception as error:
        logging.warning("Could not check the Clipman Server HTTPS certificate expiry: %s", error)


def tls_certificate_expiry(settings: Dict[str, Any]) -> str:
    certificate = str(settings.get("CertFile", "")).strip()
    if not certificate:
        return ""
    try:
        return run_openssl(find_openssl(), ["x509", "-in", certificate, "-noout", "-enddate"]).partition("=")[2]
    except Exception:
        return ""


def normalized_certificate_names(settings: Dict[str, Any], extra_hosts: List[str], extra_ips: List[str]) -> Tuple[List[str], List[str]]:
    dns_names: List[str] = []
    ip_addresses: List[str] = []

    def add(value: str, force_ip: bool = False) -> None:
        clean = (value or "").strip().rstrip(".")
        if not clean or clean in {"0.0.0.0", "::"}:
            return
        try:
            address = str(ipaddress.ip_address(clean))
            if address not in ip_addresses:
                ip_addresses.append(address)
            return
        except ValueError:
            if force_ip:
                raise ValueError(f"Invalid certificate IP address: {clean}")
        if len(clean) > 253 or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", clean):
            raise ValueError(f"Invalid certificate DNS name: {clean}")
        lowered = clean.lower()
        if lowered not in dns_names:
            dns_names.append(lowered)

    add(str(settings.get("Host", "")))
    add(str(settings.get("AdvertiseHost", "")))
    add(socket.gethostname())
    add("localhost")
    add("127.0.0.1", True)
    add("::1", True)
    for host in extra_hosts:
        add(host)
    for address in extra_ips:
        add(address, True)
    if not dns_names and not ip_addresses:
        raise ValueError("No usable DNS name or IP address was available for the server certificate.")
    return dns_names, ip_addresses


def create_tls_certificate(
    config_path: Path,
    settings: Dict[str, Any],
    extra_hosts: List[str],
    extra_ips: List[str],
    new_ca: bool,
) -> Dict[str, str]:
    openssl = find_openssl()
    dns_names, ip_addresses = normalized_certificate_names(settings, extra_hosts, extra_ips)
    tls_dir = config_path.parent / "tls"
    make_private_dir(tls_dir)
    ca_key = tls_dir / "clipman-server-ca.key"
    ca_cert = tls_dir / "clipman-server-ca.crt"
    server_key = tls_dir / "clipman-server.key"
    server_cert = tls_dir / "clipman-server.crt"
    fullchain = tls_dir / "clipman-server-fullchain.crt"

    with tempfile.TemporaryDirectory(prefix="clipman-cert-", dir=str(tls_dir)) as staging_text:
        staging = Path(staging_text)
        staged_ca_key = staging / ca_key.name
        staged_ca_cert = staging / ca_cert.name
        staged_server_key = staging / server_key.name
        staged_server_cert = staging / server_cert.name
        staged_fullchain = staging / fullchain.name

        if ca_key.exists() and ca_cert.exists() and not new_ca:
            shutil.copy2(ca_key, staged_ca_key)
            shutil.copy2(ca_cert, staged_ca_cert)
        else:
            ca_config = staging / "ca.cnf"
            ca_config.write_text(
                "[req]\n"
                "prompt = no\n"
                "distinguished_name = subject\n"
                "x509_extensions = ca_extensions\n"
                "[subject]\n"
                "CN = Clipman Server Private CA\n"
                "[ca_extensions]\n"
                "basicConstraints = critical,CA:TRUE,pathlen:0\n"
                "keyUsage = critical,keyCertSign,cRLSign\n"
                "subjectKeyIdentifier = hash\n",
                encoding="ascii",
            )
            run_openssl(openssl, [
                "req", "-x509", "-newkey", "rsa:4096", "-nodes", "-sha256", "-days", "3650",
                "-config", str(ca_config), "-keyout", str(staged_ca_key), "-out", str(staged_ca_cert),
            ])

        san_values = [f"DNS:{name}" for name in dns_names] + [f"IP:{address}" for address in ip_addresses]
        leaf_config = staging / "server.cnf"
        leaf_config.write_text(
            "[server_extensions]\n"
            "basicConstraints = critical,CA:FALSE\n"
            "keyUsage = critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage = serverAuth\n"
            f"subjectAltName = {','.join(san_values)}\n"
            "subjectKeyIdentifier = hash\n"
            "authorityKeyIdentifier = keyid,issuer\n",
            encoding="ascii",
        )
        request = staging / "server.csr"
        run_openssl(openssl, [
            "req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-subj", "/CN=Clipman Server", "-keyout", str(staged_server_key), "-out", str(request),
        ])
        run_openssl(openssl, [
            "x509", "-req", "-in", str(request), "-CA", str(staged_ca_cert), "-CAkey", str(staged_ca_key),
            "-CAcreateserial", "-days", "397", "-sha256", "-extfile", str(leaf_config),
            "-extensions", "server_extensions", "-out", str(staged_server_cert),
        ])
        run_openssl(openssl, ["verify", "-CAfile", str(staged_ca_cert), str(staged_server_cert)])
        details = run_openssl(openssl, ["x509", "-in", str(staged_server_cert), "-noout", "-text"])
        if "TLS Web Server Authentication" not in details or "CA:FALSE" not in details:
            raise RuntimeError("The generated server certificate failed its usage checks.")
        staged_fullchain.write_bytes(staged_server_cert.read_bytes() + staged_ca_cert.read_bytes())

        for path in [staged_ca_key, staged_server_key]:
            make_private_file(path)
        for source, target in [
            (staged_ca_key, ca_key),
            (staged_ca_cert, ca_cert),
            (staged_server_key, server_key),
            (staged_server_cert, server_cert),
            (staged_fullchain, fullchain),
        ]:
            os.replace(str(source), str(target))
        make_private_file(ca_key)
        make_private_file(server_key)

    settings["CaFile"] = str(ca_cert.resolve())
    settings["CertFile"] = str(fullchain.resolve())
    settings["KeyFile"] = str(server_key.resolve())
    save_settings(config_path, settings)
    write_connection_info(config_path, settings)
    write_connection_config(config_path, settings)
    fingerprint = run_openssl(
        openssl,
        ["x509", "-in", str(ca_cert), "-noout", "-fingerprint", "-sha256"],
    ).partition("=")[2]
    expiry = run_openssl(openssl, ["x509", "-in", str(server_cert), "-noout", "-enddate"]).partition("=")[2]
    return {
        "authority": str(ca_cert),
        "certificate": str(server_cert),
        "fingerprint": fingerprint,
        "expires": expiry,
    }


class CertificateShareHandler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self) -> None:
        self._send_certificate(False)

    def do_GET(self) -> None:
        self._send_certificate(True)

    def log_message(self, fmt: str, *args: Any) -> None:
        logging.info("Certificate share %s - %s", self.client_address[0], fmt % args)

    def _send_certificate(self, include_body: bool) -> None:
        if self.path != self.server.download_path:  # type: ignore[attr-defined]
            self.send_error(404)
            return
        data = self.server.certificate_data  # type: ignore[attr-defined]
        self.send_response(200)
        self.send_header("Content-Type", "application/x-x509-ca-cert")
        self.send_header("Content-Disposition", 'attachment; filename="clipman-server-ca.crt"')
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if include_body:
            self.wfile.write(data)
            self.server.downloaded.set()  # type: ignore[attr-defined]
            logging.info("Certificate authority downloaded by %s; sharing will stop.", self.client_address[0])


def share_certificate_authority(settings: Dict[str, Any], bind_override: str, minutes: int) -> int:
    configured = str(settings.get("CaFile", "")).strip()
    if not configured:
        cert_value = str(settings.get("CertFile", "")).strip()
        if cert_value:
            configured = str(Path(cert_value).expanduser().parent / "clipman-server-ca.crt")
    ca_path = Path(configured).expanduser()
    if not ca_path.is_file():
        raise RuntimeError("The certificate authority was not found. Create the HTTPS certificate first.")
    certificate_data = ca_path.read_bytes()
    if b"BEGIN CERTIFICATE" not in certificate_data or b"PRIVATE KEY" in certificate_data:
        raise RuntimeError("The configured authority file is not a public PEM certificate.")

    bind_host = (bind_override or str(settings.get("Host", ""))).strip() or "127.0.0.1"
    advertised = (str(settings.get("AdvertiseHost", "")).strip() or bind_host).strip()
    if advertised in {"0.0.0.0", "::"}:
        raise RuntimeError("Set AdvertiseHost, or pass --share-host with an address the client can reach.")
    server = None
    last_error: Exception | None = None
    for _ in range(20):
        try:
            server = http.server.HTTPServer((bind_host, random_high_port()), CertificateShareHandler)
            break
        except OSError as error:
            last_error = error
    if server is None:
        raise RuntimeError(f"Could not open a temporary certificate sharing port: {last_error}")

    server.download_path = "/clipman-ca-" + secrets.token_urlsafe(18) + ".crt"  # type: ignore[attr-defined]
    server.certificate_data = certificate_data  # type: ignore[attr-defined]
    server.downloaded = Event()  # type: ignore[attr-defined]
    host_for_url = f"[{advertised}]" if ":" in advertised and not advertised.startswith("[") else advertised
    url = f"http://{host_for_url}:{server.server_port}{server.download_path}"  # type: ignore[attr-defined]
    openssl = find_openssl()
    fingerprint = run_openssl(
        openssl,
        ["x509", "-in", str(ca_path), "-noout", "-fingerprint", "-sha256"],
    ).partition("=")[2]
    print(f"Certificate URL: {url}", flush=True)
    print(f"SHA-256 fingerprint: {fingerprint}", flush=True)
    print(f"Sharing stops after the first download or {minutes} minute{'s' if minutes != 1 else ''}.", flush=True)
    logging.info("Certificate authority sharing started on %s for at most %s minutes.", url, minutes)
    deadline = time.monotonic() + minutes * 60
    try:
        while not server.downloaded.is_set():  # type: ignore[attr-defined]
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            server.timeout = min(1.0, remaining)
            server.handle_request()
    finally:
        server.server_close()
    reason = "download completed" if server.downloaded.is_set() else "time limit reached"  # type: ignore[attr-defined]
    logging.info("Certificate authority sharing stopped: %s.", reason)
    print(f"Certificate sharing stopped: {reason}.", flush=True)
    return 0


def default_connection_info_path(config_path: Path) -> Path:
    return config_path.parent / "clipman-server-connection.txt"


def default_connection_config_path(config_path: Path) -> Path:
    return config_path.parent / "clipman-server-connection.clpconf"


def client_server_address(settings: Dict[str, Any]) -> str:
    scheme = "https" if has_tls(settings) else "clipman"
    return f"{scheme}://{advertised_host(settings)}:{settings['Port']}"


def write_connection_info(config_path: Path, settings: Dict[str, Any]) -> Path:
    target = default_connection_info_path(config_path)
    make_private_dir(target.parent)
    lines = [
        "Clipman Server connection details",
        "",
        f"Server address: {client_server_address(settings)}",
        f"Port: {settings['Port']}",
        f"Token: {settings['AuthToken']}",
        "",
        "Keep this file private. After every Clipman client has been configured,",
        "delete this file or move the details to your password manager.",
    ]
    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    make_private_file(tmp)
    tmp.replace(target)
    make_private_file(target)
    return target


def write_connection_config(config_path: Path, settings: Dict[str, Any]) -> Path:
    target = default_connection_config_path(config_path)
    make_private_dir(target.parent)
    document = {
        "clipman": "server-connection",
        "version": 1,
        "address": client_server_address(settings),
        "host": advertised_host(settings),
        "port": int(settings["Port"]),
        "token": str(settings["AuthToken"]),
    }
    tmp = target.with_suffix(target.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(document, f, indent=2, sort_keys=True)
        f.write("\n")
    make_private_file(tmp)
    tmp.replace(target)
    make_private_file(target)
    return target


def maybe_write_connection_info(config_path: Path, settings: Dict[str, Any], settings_created: bool, force: bool) -> Path | None:
    target = default_connection_info_path(config_path)
    if force or settings_created or target.exists():
        return write_connection_info(config_path, settings)
    return None


def maybe_write_connection_config(config_path: Path, settings: Dict[str, Any], settings_created: bool, force: bool) -> Path | None:
    target = default_connection_config_path(config_path)
    legacy = default_connection_info_path(config_path)
    if force or settings_created or target.exists() or legacy.exists():
        return write_connection_config(config_path, settings)
    return None


def status(settings: Dict[str, Any], server: Any | None = None) -> Dict[str, Any]:
    runtime = server.runtime_summary() if server is not None and hasattr(server, "runtime_summary") else {}
    return {
        "Status": "ok",
        "Version": APP_VERSION,
        "Machine": os.uname().nodename if hasattr(os, "uname") else "",
        "DatabaseRevision": "",
        "DatabaseLength": 0,
        "DatabaseModifiedUnixMs": 0,
        "ListenPrefix": listen_prefix(settings),
        "TlsEnabled": has_tls(settings),
        "TlsCertificateExpires": str(settings.get("_TlsCertificateExpires", "")),
        "BackupRetentionHours": int(settings["BackupRetentionHours"]),
        "MaxBackups": int(settings["MaxBackups"]),
        "Runtime": runtime,
    }


def database_path(settings: Dict[str, Any], database_id: str) -> Path:
    return database_root(settings) / database_id / "clipman-history.clipdb"


def database_root(settings: Dict[str, Any]) -> Path:
    return Path(settings["DatabasePath"]).parent / "Databases"


def deleted_database_root(settings: Dict[str, Any]) -> Path:
    return Path(settings["DatabasePath"]).parent / "DeletedDatabases"


def database_metadata_path(db: Path) -> Path:
    return db.parent / METADATA_FILE


def load_database_metadata(db: Path) -> Dict[str, Any]:
    path = database_metadata_path(db)
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8-sig") as f:
            value = json.load(f)
        return value if isinstance(value, dict) else {}
    except Exception:
        logging.warning("Could not read database metadata: %s", path)
        return {}


def save_database_metadata(db: Path, metadata: Dict[str, Any]) -> None:
    make_private_dir(db.parent)
    path = database_metadata_path(db)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2, sort_keys=True)
    make_private_file(tmp)
    tmp.replace(path)
    make_private_file(path)


def touch_database(settings: Dict[str, Any], database_id: str, event: str) -> None:
    db = database_path(settings, database_id)
    metadata = load_database_metadata(db)
    timestamp = now_ms()
    previous_seen = int(metadata.get("LastSeenUnixMs", 0) or 0)
    is_new = not metadata
    should_save = is_new or event == "write" or timestamp - previous_seen >= METADATA_TOUCH_INTERVAL_MS
    metadata.setdefault("DatabaseId", database_id)
    metadata.setdefault("FirstSeenUnixMs", timestamp)
    metadata["LastSeenUnixMs"] = timestamp
    metadata["LastEvent"] = event
    if event == "write":
        metadata["LastWrittenUnixMs"] = timestamp
    if should_save:
        save_database_metadata(db, metadata)


def database_id_from_path(path: str) -> str:
    prefix = "/api/v1/database/"
    if not path.startswith(prefix):
        return ""
    database_id = unquote(path[len(prefix):]).strip()
    if not (32 <= len(database_id) <= 128):
        return ""
    for char in database_id:
        if not (char.isalnum() or char in "-_"):
            return ""
    return database_id


def backup_dir_for_database(db: Path) -> Path:
    return db.parent / "ServerBackups"


def create_backup(settings: Dict[str, Any], db: Path, force: bool) -> Dict[str, Any]:
    if not db.exists():
        return {"Name": "", "Length": 0, "CreatedUnixMs": 0, "Revision": ""}

    out_dir = backup_dir_for_database(db)
    make_private_dir(out_dir)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
    name = f"clipman-history-{stamp}-{time.time_ns() % 1_000_000_000:09d}.clipdb"
    target = out_dir / name
    if not force:
        newest = newest_backup(out_dir)
        interval = int(settings["BackupIntervalMinutes"])
        if newest is not None and interval > 0 and time.time() - newest.stat().st_mtime < interval * 60:
            return backup_info(newest)
    shutil.copy2(db, target)
    make_private_file(target)
    prune_backup_directory(settings, out_dir)
    return backup_info(target)


def newest_backup(out_dir: Path) -> Path | None:
    backups = sorted(out_dir.glob("*.clipdb"), key=lambda p: p.stat().st_mtime, reverse=True)
    return backups[0] if backups else None


def backup_info(path: Path) -> Dict[str, Any]:
    return {
        "Name": path.name,
        "Length": path.stat().st_size if path.exists() else 0,
        "CreatedUnixMs": modified_ms(path),
        "Revision": revision(path),
    }


def prune_backup_directory(
    settings: Dict[str, Any],
    out_dir: Path,
    *,
    cutoff: float | None = None,
    max_backups: int | None = None,
) -> None:
    if cutoff is None:
        retention = int(settings["BackupRetentionHours"])
        cutoff = time.time() - retention * 3600
    if max_backups is None:
        max_backups = int(settings["MaxBackups"])

    backups = sorted(out_dir.glob("*.clipdb"), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in backups:
        if path.stat().st_mtime < cutoff:
            path.unlink(missing_ok=True)
    backups = sorted(out_dir.glob("*.clipdb"), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in backups[max_backups:]:
        path.unlink(missing_ok=True)


def list_database_infos(settings: Dict[str, Any]) -> List[Dict[str, Any]]:
    root = database_root(settings)
    if not root.exists():
        return []
    results: List[Dict[str, Any]] = []
    for bucket in sorted(root.iterdir(), key=lambda p: p.name.lower()):
        if not bucket.is_dir():
            continue
        db = bucket / "clipman-history.clipdb"
        metadata = load_database_metadata(db)
        backups = list((bucket / "ServerBackups").glob("*.clipdb")) if (bucket / "ServerBackups").exists() else []
        modified = modified_ms(db) if db.exists() else 0
        last_seen = int(metadata.get("LastSeenUnixMs", 0) or 0)
        last_written = int(metadata.get("LastWrittenUnixMs", 0) or 0)
        first_seen = int(metadata.get("FirstSeenUnixMs", 0) or 0)
        results.append({
            "DatabaseId": bucket.name,
            "Length": db.stat().st_size if db.exists() else 0,
            "ModifiedUnixMs": modified,
            "FirstSeenUnixMs": first_seen,
            "LastSeenUnixMs": last_seen,
            "LastWrittenUnixMs": last_written,
            "LastActivityUnixMs": max(last_seen, last_written, modified),
            "LastEvent": str(metadata.get("LastEvent", "")),
            "BackupCount": len(backups),
            "Exists": db.exists(),
        })
    return sorted(results, key=lambda item: int(item["LastActivityUnixMs"]), reverse=True)


def format_age(timestamp_ms: int) -> str:
    if timestamp_ms <= 0:
        return "unknown"
    seconds = max(0, int(time.time() - (timestamp_ms / 1000)))
    if seconds < 60:
        return f"{seconds}s ago"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes}m ago"
    hours = minutes // 60
    if hours < 48:
        return f"{hours}h ago"
    days = hours // 24
    return f"{days}d ago"


def print_database_list(settings: Dict[str, Any], as_json: bool) -> None:
    items = list_database_infos(settings)
    if as_json:
        print(json.dumps({"Databases": items}, indent=2, sort_keys=True))
        return
    if not items:
        print("No Clipman Server database buckets found.")
        return
    print("Database buckets:")
    for item in items:
        database_id = str(item["DatabaseId"])
        display_id = database_id[:12] + "..." if len(database_id) > 15 else database_id
        print(
            f"{display_id}  size={item['Length']} bytes  "
            f"last_seen={format_age(int(item['LastSeenUnixMs']))}  "
            f"last_written={format_age(int(item['LastWrittenUnixMs']))}  "
            f"backups={item['BackupCount']}"
        )
    print()
    print("Use --list-databases-json for full IDs and exact timestamps.")


def matching_stale_databases(settings: Dict[str, Any], older_than_days: int) -> List[Dict[str, Any]]:
    cutoff_ms = now_ms() - older_than_days * 24 * 60 * 60 * 1000
    return [item for item in list_database_infos(settings) if int(item["LastActivityUnixMs"]) > 0 and int(item["LastActivityUnixMs"]) < cutoff_ms]


def move_database_bucket_to_deleted(settings: Dict[str, Any], database_id: str) -> Path:
    source = database_root(settings) / database_id
    if not source.exists() or not source.is_dir():
        raise SystemExit(f"Database bucket not found: {database_id}")
    target_root = deleted_database_root(settings)
    make_private_dir(target_root)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
    target = target_root / f"{database_id}-{stamp}"
    counter = 1
    while target.exists():
        counter += 1
        target = target_root / f"{database_id}-{stamp}-{counter}"
    shutil.move(str(source), str(target))
    return target


def database_info_by_id(settings: Dict[str, Any], database_id: str) -> Dict[str, Any] | None:
    for item in list_database_infos(settings):
        if str(item["DatabaseId"]) == database_id:
            return item
    return None


def ensure_database_is_not_recent(settings: Dict[str, Any], database_id: str, force_recent: bool) -> None:
    if force_recent:
        return
    item = database_info_by_id(settings, database_id)
    if item is None:
        return
    last_activity = int(item["LastActivityUnixMs"])
    if last_activity <= 0:
        return
    age_ms = now_ms() - last_activity
    if age_ms < 24 * 60 * 60 * 1000:
        raise SystemExit(
            f"Refusing to move recently active database bucket {database_id}. "
            f"Last activity was {format_age(last_activity)}. "
            "Wait 24 hours or add --force-recent if you are certain this is the right bucket."
        )


def delete_database_bucket(settings: Dict[str, Any], database_id: str, confirm: bool, force_recent: bool) -> int:
    if not confirm:
        raise SystemExit("Refusing to move a database bucket without --confirm. This is intentionally not automatic.")
    ensure_database_is_not_recent(settings, database_id, force_recent)
    target = move_database_bucket_to_deleted(settings, database_id)
    print(f"Moved database bucket to {target}")
    return 0


def prune_database_buckets(settings: Dict[str, Any], older_than_days: int, confirm: bool) -> int:
    if older_than_days <= 0:
        raise SystemExit("--prune-databases-days must be greater than zero.")
    matches = matching_stale_databases(settings, older_than_days)
    if not matches:
        print(f"No database buckets older than {older_than_days} days.")
        return 0
    if not confirm:
        print(f"Database buckets older than {older_than_days} days that would be moved:")
        for item in matches:
            print(f"  {item['DatabaseId']}  size={item['Length']} bytes  last_activity={format_age(int(item['LastActivityUnixMs']))}")
        print()
        print("Nothing was changed. Add --confirm to move these buckets to DeletedDatabases.")
        return 0
    for item in matches:
        target = move_database_bucket_to_deleted(settings, str(item["DatabaseId"]))
        print(f"Moved {item['DatabaseId']} to {target}")
    return 0


def run_configured_database_prune(settings: Dict[str, Any]) -> None:
    older_than_days = int(settings.get("DatabasePruneDays", 0) or 0)
    if older_than_days <= 0:
        return
    matches = matching_stale_databases(settings, older_than_days)
    if not matches:
        logging.info("No database buckets older than %s days.", older_than_days)
        return
    for item in matches:
        database_id = str(item["DatabaseId"])
        target = move_database_bucket_to_deleted(settings, database_id)
        logging.info(
            "Moved stale database bucket %s to %s after %s days without activity.",
            database_id,
            target,
            older_than_days,
        )


def start_database_prune_thread(settings: Dict[str, Any]) -> None:
    older_than_days = int(settings.get("DatabasePruneDays", 0) or 0)
    if older_than_days <= 0:
        return
    interval_hours = max(1, int(settings.get("DatabasePruneIntervalHours", 24) or 24))

    def worker() -> None:
        while True:
            try:
                run_configured_database_prune(settings)
            except Exception:
                logging.exception("Configured database prune pass failed.")
            time.sleep(interval_hours * 60 * 60)

    Thread(target=worker, daemon=True).start()


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def __init__(self, server_address: Tuple[str, int], request_handler_class: Any):
        super().__init__(server_address, request_handler_class)
        self.started_unix_ms = now_ms()
        self._stats_lock = Lock()
        self._database_locks_lock = Lock()
        self._database_locks: Dict[str, Any] = {}
        self._stats: Dict[str, Any] = {
            "Requests": 0,
            "DatabaseUploads": 0,
            "DatabaseDownloads": 0,
            "DatabasePolls": 0,
            "HealthChecks": 0,
            "Conflicts": 0,
            "BytesReceived": 0,
            "BytesSent": 0,
            "Methods": {},
            "StatusCodes": {},
            "Clients": {},
        }

    def database_lock(self, database_id: str) -> Any:
        with self._database_locks_lock:
            lock = self._database_locks.get(database_id)
            if lock is None:
                lock = Lock()
                self._database_locks[database_id] = lock
            return lock

    def record_request(self, client_ip: str, method: str, path: str, status_code: int, bytes_received: int = 0, bytes_sent: int = 0) -> None:
        with self._stats_lock:
            self._stats["Requests"] += 1
            methods = self._stats["Methods"]
            methods[method] = int(methods.get(method, 0)) + 1
            if path == "/api/v1/health":
                self._stats["HealthChecks"] += 1
            elif path.startswith("/api/v1/database/"):
                if method == "PUT":
                    self._stats["DatabaseUploads"] += 1
                elif method == "GET":
                    self._stats["DatabaseDownloads"] += 1
                elif method == "HEAD":
                    self._stats["DatabasePolls"] += 1
            if status_code in (409, 412):
                self._stats["Conflicts"] += 1
            self._stats["BytesReceived"] += max(0, bytes_received)
            self._stats["BytesSent"] += max(0, bytes_sent)
            status_codes = self._stats["StatusCodes"]
            key = str(status_code)
            status_codes[key] = int(status_codes.get(key, 0)) + 1
            clients = self._stats["Clients"]
            clients[client_ip] = int(clients.get(client_ip, 0)) + 1

    def runtime_summary(self) -> Dict[str, Any]:
        with self._stats_lock:
            uptime_ms = now_ms() - int(self.started_unix_ms)
            clients = dict(self._stats["Clients"])
            return {
                "StartedUnixMs": int(self.started_unix_ms),
                "UptimeSeconds": int(uptime_ms / 1000),
                "Requests": int(self._stats["Requests"]),
                "DatabaseUploads": int(self._stats["DatabaseUploads"]),
                "DatabaseDownloads": int(self._stats["DatabaseDownloads"]),
                "DatabasePolls": int(self._stats["DatabasePolls"]),
                "HealthChecks": int(self._stats["HealthChecks"]),
                "Conflicts": int(self._stats["Conflicts"]),
                "BytesReceived": int(self._stats["BytesReceived"]),
                "BytesSent": int(self._stats["BytesSent"]),
                "UniqueClients": len(clients),
                "Methods": dict(self._stats["Methods"]),
                "StatusCodes": dict(self._stats["StatusCodes"]),
            }

    def log_runtime_summary(self, reason: str) -> None:
        summary = self.runtime_summary()
        logging.info(
            "Clipman Server runtime summary (%s): uptime=%ss requests=%s database_uploads=%s database_downloads=%s database_polls=%s conflicts=%s "
            "unique_clients=%s bytes_received=%s bytes_sent=%s status_codes=%s",
            reason,
            summary["UptimeSeconds"],
            summary["Requests"],
            summary["DatabaseUploads"],
            summary["DatabaseDownloads"],
            summary["DatabasePolls"],
            summary["Conflicts"],
            summary["UniqueClients"],
            summary["BytesReceived"],
            summary["BytesSent"],
            summary["StatusCodes"],
        )


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "ClipmanServerLinux/" + APP_VERSION
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        self.route()

    def do_HEAD(self) -> None:
        self.route()

    def do_POST(self) -> None:
        self.route()

    def do_PUT(self) -> None:
        self.route()

    def log_message(self, fmt: str, *args: Any) -> None:
        message = fmt % args
        if '"HEAD /api/v1/database/' in message and ' 200 ' in message:
            return
        message = DATABASE_LOG_PATTERN.sub(r"\1<database-id>", message)
        logging.info("%s - %s", self.address_string(), message)

    @property
    def settings(self) -> Dict[str, Any]:
        return self.server.settings  # type: ignore[attr-defined]

    def route(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if self.command == "GET" and path == "/api/v1/health":
            self.write_json(status(self.settings, self.server))
            return

        if not self.authorized():
            self.send_text(401, "Unauthorized")
            return

        database_id = database_id_from_path(path)
        if database_id and self.command == "HEAD":
            self.head_database(database_id)
        elif database_id and self.command == "GET":
            self.download_database(database_id)
        elif database_id and self.command == "PUT":
            self.upload_database(database_id)
        elif path == "/api/v1/backup" and self.command == "POST":
            self.send_text(404, "Use a database-scoped backup endpoint")
        elif path == "/api/v1/backups" and self.command == "GET":
            self.write_json({"Backups": self.list_backups()})
        elif path == "/api/v1/restore" and self.command == "POST":
            self.restore_backup(parse_qs(parsed.query).get("name", [""])[0])
        else:
            self.send_text(404, "Not found")

    def authorized(self) -> bool:
        token = str(self.settings.get("AuthToken", "")).strip()
        return bool(token) and self.headers.get("Authorization", "").strip() == "Bearer " + token

    def head_database(self, database_id: str) -> None:
        with self.server.database_lock(database_id):  # type: ignore[attr-defined]
            db = database_path(self.settings, database_id)
            if not db.exists():
                self.send_response(404)
                self.end_headers()
                self.record(404)
                return
            touch_database(self.settings, database_id, "head")
            rev = revision(db)
            length = db.stat().st_size
        self.send_response(200)
        self.send_header("ETag", f'"{rev}"')
        self.send_header("X-Clipman-Revision", rev)
        self.send_header("Content-Length", str(length))
        self.end_headers()
        self.record(200)

    def download_database(self, database_id: str) -> None:
        with self.server.database_lock(database_id):  # type: ignore[attr-defined]
            db = database_path(self.settings, database_id)
            if not db.exists():
                self.send_text(404, "Database not found")
                return
            touch_database(self.settings, database_id, "download")
            rev = revision(db)
            data = db.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("ETag", f'"{rev}"')
        self.send_header("X-Clipman-Revision", rev)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.record(200, bytes_sent=len(data))

    def upload_database(self, database_id: str) -> None:
        raw_length = self.headers.get("Content-Length", "").strip()
        try:
            length = int(raw_length)
        except ValueError:
            self.send_text(400, "A valid Content-Length header is required")
            return
        max_database_bytes = max(1, int(self.settings.get("MaxDatabaseBytes", 64 * 1024 * 1024)))
        if length < 0:
            self.send_text(400, "Content-Length cannot be negative")
            return
        if length > max_database_bytes:
            self.send_text(413, f"Database exceeds the configured {max_database_bytes} byte limit")
            return

        data = self.rfile.read(length)
        if len(data) != length:
            self.send_text(400, "Request body ended before Content-Length bytes were received")
            return

        expected = self.headers.get("If-Match", "").strip().strip('"')
        create_only = self.headers.get("If-None-Match", "").strip()
        if create_only and create_only != "*":
            self.send_text(400, "If-None-Match must be * when creating a database")
            return
        if expected and create_only:
            self.send_text(400, "If-Match and If-None-Match cannot be used together")
            return
        with self.server.database_lock(database_id):  # type: ignore[attr-defined]
            db = database_path(self.settings, database_id)
            current = revision(db)
            if create_only == "*" and db.exists():
                payload = b"Database already exists"
                self.send_response(412)
                self.send_header("X-Clipman-Revision", current)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                self.record(412, bytes_received=len(data), bytes_sent=len(payload))
                return
            if expected and expected != current:
                payload = b"Database revision changed"
                self.send_response(409)
                self.send_header("X-Clipman-Revision", current)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                self.record(409, bytes_received=len(data), bytes_sent=len(payload))
                return

            if db.exists() and db.read_bytes() == data:
                touch_database(self.settings, database_id, "head")
                new_revision = current
            else:
                if self.settings.get("CreateBackupBeforeEveryUpload", True):
                    create_backup(self.settings, db, False)
                make_private_dir(db.parent)
                tmp = db.with_suffix(db.suffix + ".upload.tmp")
                tmp.write_bytes(data)
                make_private_file(tmp)
                tmp.replace(db)
                make_private_file(db)
                touch_database(self.settings, database_id, "write")
                new_revision = revision(db)

        payload = json.dumps(status(self.settings, self.server), indent=2, sort_keys=True).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("X-Clipman-Revision", new_revision)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.record(200, bytes_received=len(data), bytes_sent=len(payload))

    def list_backups(self) -> List[Dict[str, Any]]:
        out_dir = Path(self.settings["DatabasePath"]).parent / "Databases"
        if not out_dir.exists():
            return []
        return [backup_info(p) for p in sorted(out_dir.glob("*/ServerBackups/*.clipdb"), key=lambda p: p.stat().st_mtime, reverse=True)]

    def restore_backup(self, name: str) -> None:
        self.send_text(404, "Use a database-scoped restore endpoint")

    def write_json(self, value: Dict[str, Any]) -> None:
        data = json.dumps(value, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        self.record(200, bytes_sent=0 if self.command == "HEAD" else len(data))

    def send_text(self, status_code: int, text: str) -> None:
        data = text.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        self.record(status_code, bytes_sent=0 if self.command == "HEAD" else len(data))

    def record(self, status_code: int, bytes_received: int = 0, bytes_sent: int = 0) -> None:
        if hasattr(self.server, "record_request"):
            parsed = urlparse(self.path)
            self.server.record_request(self.client_address[0], self.command, parsed.path.rstrip("/") or "/", status_code, bytes_received, bytes_sent)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a Clipman history server.")
    parser.add_argument("--version", action="store_true", help="Print the Clipman Server version and exit.")
    parser.add_argument("--config", default=str(Path.cwd() / "Settings" / DEFAULT_CONFIG), help="Path to server settings JSON.")
    parser.add_argument("--host", help="Override listen host for this run and save it.")
    parser.add_argument("--advertise-host", help="Override the host written to connection details for this run and save it.")
    parser.add_argument("--port", type=int, help="Override listen port for this run and save it.")
    parser.add_argument("--database", help="Override database path and save it.")
    parser.add_argument("--log", help="Override log path and save it.")
    parser.add_argument("--cert-file", help="TLS certificate PEM file for direct HTTPS and save it.")
    parser.add_argument("--key-file", help="TLS private key PEM file for direct HTTPS and save it.")
    parser.add_argument("--create-tls-certificate", action="store_true", help="Create or renew a private-CA HTTPS certificate, update settings, and exit.")
    parser.add_argument("--cert-host", action="append", default=[], help="Add a DNS name to a generated HTTPS certificate. May be repeated.")
    parser.add_argument("--cert-ip", action="append", default=[], help="Add an IP address to a generated HTTPS certificate. May be repeated.")
    parser.add_argument("--new-ca", action="store_true", help="Replace the private certificate authority when generating HTTPS. Existing clients must trust the new authority.")
    parser.add_argument("--share-ca", action="store_true", help="Temporarily share only the public certificate authority over HTTP and exit after one download or the time limit.")
    parser.add_argument("--share-minutes", type=int, default=10, help="Minutes to share the public authority with --share-ca (1 to 60; default 10).")
    parser.add_argument("--share-host", help="Override the listen host used by --share-ca.")
    parser.add_argument("--allow-insecure-remote", action="store_true", help="Allow non-local HTTP listeners without TLS. Use only behind a VPN, firewall, or reverse proxy.")
    parser.add_argument("--show-token", action="store_true", help="Print the bearer token and exit.")
    parser.add_argument("--write-connection-info", action="store_true", help="Write importable and plain text server connection files beside the settings file.")
    parser.add_argument("--list-databases", action="store_true", help="List database buckets known to this server and exit.")
    parser.add_argument("--list-databases-json", action="store_true", help="List database buckets as JSON and exit.")
    parser.add_argument("--delete-database", help="Move one database bucket to DeletedDatabases. Requires --confirm and refuses buckets touched in the last 24 hours unless --force-recent is also passed.")
    parser.add_argument("--prune-databases-days", type=int, help="List database buckets whose last activity is older than this many days. Add --confirm to move them to DeletedDatabases.")
    parser.add_argument("--confirm", action="store_true", help="Confirm a database maintenance action that moves buckets to DeletedDatabases.")
    parser.add_argument("--force-recent", action="store_true", help="Allow --delete-database to move a bucket touched in the last 24 hours. Use only after checking --list-databases-json.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.version:
        print(APP_VERSION)
        return 0
    config_path = Path(args.config).expanduser().resolve()
    settings, settings_created = load_settings(config_path)
    if args.host:
        settings["Host"] = args.host
    if args.advertise_host:
        settings["AdvertiseHost"] = args.advertise_host
    if args.port:
        settings["Port"] = args.port
    if args.database:
        settings["DatabasePath"] = str(Path(args.database).expanduser().resolve())
    if args.log:
        settings["LogPath"] = str(Path(args.log).expanduser().resolve())
    if args.cert_file:
        settings["CertFile"] = str(Path(args.cert_file).expanduser().resolve())
    if args.key_file:
        settings["KeyFile"] = str(Path(args.key_file).expanduser().resolve())
    if args.allow_insecure_remote:
        settings["AllowInsecureRemote"] = True
    save_settings(config_path, settings)
    connection_info = maybe_write_connection_info(config_path, settings, settings_created, args.write_connection_info)
    connection_config = maybe_write_connection_config(config_path, settings, settings_created, args.write_connection_info)
    configure_logging(settings)

    if args.create_tls_certificate:
        try:
            result = create_tls_certificate(config_path, settings, args.cert_host, args.cert_ip, args.new_ca)
        except (OSError, RuntimeError, ValueError) as error:
            print(f"Could not create the HTTPS certificate: {error}", file=sys.stderr)
            return 1
        print(f"Certificate authority: {result['authority']}")
        print(f"Server certificate: {result['certificate']}")
        print(f"Server certificate expires: {result['expires']}")
        print(f"Authority SHA-256 fingerprint: {result['fingerprint']}")
        print("Install and trust the authority on each client, then restart Clipman Server.")
        return 0
    if args.share_ca:
        if args.share_minutes < 1 or args.share_minutes > 60:
            raise SystemExit("--share-minutes must be between 1 and 60.")
        try:
            return share_certificate_authority(settings, args.share_host or "", args.share_minutes)
        except (OSError, RuntimeError, ValueError) as error:
            print(f"Could not share the certificate authority: {error}", file=sys.stderr)
            return 1
    if args.show_token:
        print(settings["AuthToken"])
        return 0
    if args.write_connection_info:
        print(connection_config or default_connection_config_path(config_path))
        return 0
    if args.list_databases or args.list_databases_json:
        print_database_list(settings, args.list_databases_json)
        return 0
    if args.delete_database:
        return delete_database_bucket(settings, args.delete_database, args.confirm, args.force_recent)
    if args.prune_databases_days is not None:
        return prune_database_buckets(settings, args.prune_databases_days, args.confirm)

    tls_context = create_tls_context(settings)
    validate_network_security(settings)
    warn_if_tls_certificate_expiring(settings)
    settings["_TlsCertificateExpires"] = tls_certificate_expiry(settings)
    host = str(settings["Host"])
    port = int(settings["Port"])
    server = ThreadingServer((host, port), Handler)
    server.settings = settings  # type: ignore[attr-defined]
    if tls_context is not None:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    stop_reason = "shutdown"

    def request_shutdown(signum: int, _frame: Any) -> None:
        nonlocal stop_reason
        name = signal.Signals(signum).name if signum in {sig.value for sig in signal.Signals} else str(signum)
        stop_reason = name
        logging.info("Clipman Server received %s.", name)
        Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)
    logging.info("Clipman Server %s listening on %s", APP_VERSION, listen_prefix(settings))
    logging.info("Settings: %s", config_path)
    logging.info("Data root: %s", Path(settings["DatabasePath"]).parent / "Databases")
    start_database_prune_thread(settings)
    print(f"Clipman Server {APP_VERSION} listening on {listen_prefix(settings)}")
    print("Use --show-token to print the bearer token for client setup.")
    if connection_info:
        print(f"Connection details written to {connection_info}")
    if connection_config:
        print(f"Importable connection file written to {connection_config}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()
        print("Clipman Server stopping.")
        stop_reason = "keyboard interrupt"
        logging.info("Clipman Server stopped by keyboard interrupt.")
    finally:
        server.log_runtime_summary(stop_reason)
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
