#!/usr/bin/env python3
"""Opt-in HTTPS test host for synthetic history from TestBrowserFixture."""

import argparse
import base64
import hashlib
import hmac
import json
import importlib.util
from pathlib import Path
import ssl
import subprocess
import time
from threading import Thread

import clipman_server as server


def main():
    global server
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, help='Disposable empty test directory')
    parser.add_argument('--assets', required=True)
    parser.add_argument('--program', help='Packaged server script to exercise embedded assets')
    parser.add_argument('--seed', required=True, help='Synthetic CLIPDB2 fixture, never personal history')
    args = parser.parse_args()
    if args.program:
        spec = importlib.util.spec_from_file_location('packaged_clipman_server', args.program)
        server = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(server)
    root = Path(args.root).resolve()
    if root.exists() and any(root.iterdir()):
        parser.error('Fixture root must be empty.')
    root.mkdir(parents=True, exist_ok=True)
    server.WEB_ASSET_ROOT = Path(args.assets).resolve()
    settings, _ = server.load_settings(root / 'settings.json')
    settings.update(Host='127.0.0.1', Port=41821, AuthToken='browser-test-token',
                    DatabasePath=str(root / 'history.clipdb'), LogPath=str(root / 'server.log'),
                    WebClientEnabled=True)
    server.create_tls_certificate(root / 'settings.json', settings, [], ['127.0.0.1'], False)
    server.validate_web_client(settings)
    key = hashlib.sha256(b'browser-test-token').digest()
    mac = hmac.new(key, b'Clipman.ServerDatabaseId.v1\nbrowser-test-password', hashlib.sha256).digest()
    bucket = base64.urlsafe_b64encode(mac).decode().rstrip('=')
    database = server.database_path(settings, bucket)
    database.parent.mkdir(parents=True, exist_ok=True)
    seed = Path(args.seed).read_bytes()
    if not seed.startswith(b'CLIPDB2'):
        parser.error('Synthetic encrypted fixture required.')
    database.write_bytes(seed)
    host = server.ThreadingServer(('127.0.0.1', 41821), server.Handler)
    host.settings, host.config_path = settings, root / 'settings.json'
    host.socket = server.create_tls_context(settings).wrap_socket(host.socket, server_side=True)
    thread = Thread(target=host.serve_forever)
    thread.start()
    try:
        # Check the real TLS chain and hostname without changing OS trust.
        context = ssl.create_default_context(cafile=settings['CaFile'])
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        with context.wrap_socket(__import__('socket').socket(), server_hostname='127.0.0.1') as connection:
            connection.settimeout(5)
            connection.connect(host.server_address)
        openssl = server.find_openssl()
        public = subprocess.check_output([openssl, 'x509', '-in', settings['CertFile'], '-pubkey', '-noout'])
        der = subprocess.run([openssl, 'pkey', '-pubin', '-outform', 'DER'], input=public,
                             stdout=subprocess.PIPE, check=True).stdout
        pin = base64.b64encode(hashlib.sha256(der).digest()).decode()
        metadata = {'url':'https://127.0.0.1:41821/web/', 'pin':pin, 'bucket':bucket}
        (root / 'fixture.json').write_text(json.dumps(metadata), encoding='utf-8')
        print('Synthetic HTTPS browser fixture ready.', flush=True)
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline and not (root / 'stop').exists():
            time.sleep(0.1)
    finally:
        host.shutdown()
        host.server_close()
        thread.join(timeout=5)


if __name__ == '__main__':
    main()
