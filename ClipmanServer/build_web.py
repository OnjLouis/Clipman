#!/usr/bin/env python3
"""Build the server's architecture-independent browser assets outside source."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import zlib
import base64


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, help='Empty folder outside the source tree')
    parser.add_argument('--go', default='go', help='Go executable (1.26.8 or newer patched release)')
    parser.add_argument('--server-output', help='Generated self-contained server script outside source')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = Path(args.output).resolve()
    if output == root or root in output.parents or output in root.parents:
        parser.error('Browser output must be outside the source tree.')
    if output.exists() and any(output.iterdir()):
        parser.error('Browser output folder must be empty.')
    version = subprocess.check_output([args.go, 'version'], text=True).strip()
    match = re.search(r'go(\d+)\.(\d+)\.(\d+)', version)
    if not match:
        parser.error('A stable patched Go release is required.')
    number = tuple(map(int, match.groups()))
    if number < (1, 26, 8) or number == (1, 27, 0):
        parser.error('Upgrade Go: the browser release requires fixed security vulnerabilities.')
    output.mkdir(parents=True, exist_ok=True)
    ui = root / 'ClipmanCli' / 'cmd' / 'clipman-web-preview' / 'ui'
    for name in ['index.html', 'app.js', 'pagination.js', 'links.js', 'purify.min.js',
                 'rich.js', 'worker.js', 'style.css', 'DOMPurify-LICENSE.txt']:
        shutil.copy2(ui / name, output / name)
    goroot = subprocess.check_output([args.go, 'env', 'GOROOT'], text=True).strip()
    shutil.copy2(Path(goroot) / 'lib' / 'wasm' / 'wasm_exec.js', output / 'wasm_exec.js')
    shutil.copy2(root / 'ClipmanAndroid' / 'app' / 'src' / 'main' / 'res' / 'drawable-nodpi' / 'clipman_app_icon.png', output / 'icon.png')
    env = dict(os.environ, GOOS='js', GOARCH='wasm', CGO_ENABLED='0')
    subprocess.run([args.go, 'build', '-trimpath', '-o', str(output / 'client.wasm'), './cmd/clipman-web'],
                   cwd=root / 'ClipmanCli', env=env, check=True)
    manifest = {'serverVersion': (root / 'ClipmanServer' / 'version.txt').read_text().strip(),
                'goVersion': version.split()[2],
                'sha256': {file.name: hashlib.sha256(file.read_bytes()).hexdigest()
                           for file in sorted(output.iterdir())}}
    (output / 'browser-assets.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    if args.server_output:
        target = Path(args.server_output).resolve()
        if target == root or root in target.parents or target in root.parents or target.exists():
            parser.error('Server output must be a new file outside the source tree.')
        files = {file.name: base64.b64encode(file.read_bytes()).decode('ascii')
                 for file in sorted(output.iterdir())}
        bundle = base64.b64encode(zlib.compress(json.dumps(files).encode(), level=9)).decode('ascii')
        source = (root / 'ClipmanServerLinux' / 'clipman_server.py').read_text(encoding='utf-8')
        marker = 'WEB_BUNDLE = ""'
        if source.count(marker) != 1:
            parser.error('Server browser bundle marker is missing or ambiguous.')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source.replace(marker, 'WEB_BUNDLE = ' + repr(bundle)), encoding='utf-8')
    print('Built browser assets for Clipman Server ' + manifest['serverVersion'])


if __name__ == '__main__':
    main()
