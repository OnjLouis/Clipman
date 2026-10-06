"""Synthetic browser-hosting boundary tests; no real server data is opened."""

import http.client
import base64
import hashlib
import json
import zlib
import tempfile
import unittest
from pathlib import Path
from threading import Thread
from unittest import mock

import clipman_server as server


class WebHostingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.assets = root / 'web'
        self.assets.mkdir()
        for name in server.WEB_ASSETS:
            (self.assets / name).write_bytes(b'synthetic public asset')
        self.patch = mock.patch.object(server, 'WEB_ASSET_ROOT', self.assets, create=True)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.settings, _ = server.load_settings(root / 'settings.json')
        self.settings.update(DatabasePath=str(root / 'history.clipdb'), AuthToken='never-in-page',
                             AdvertiseUrl='https://clip.example.com', WebClientEnabled=True,
                             WebProxyAddresses=['127.0.0.1'])
        self.host = server.ThreadingServer(('127.0.0.1', 0), server.Handler)
        self.host.settings = self.settings
        self.host.config_path = root / 'settings.json'
        self.thread = Thread(target=self.host.serve_forever)
        self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        self.host.shutdown()
        self.host.server_close()
        self.thread.join(timeout=5)

    def request(self, path='/web/preview.json', method='GET', body=None, **headers):
        connection = http.client.HTTPConnection(*self.host.server_address, timeout=5)
        headers.setdefault('Host', 'clip.example.com')
        headers.setdefault('X-Forwarded-Proto', 'https')
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read()
        connection.close()
        return result

    def test_https_proxy_metadata_contains_no_credentials(self):
        code, headers, body = self.request()
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body), {'server':'https://clip.example.com', 'direct':True})
        self.assertNotIn(b'never-in-page', body)
        self.assertEqual(headers['Cache-Control'], 'no-store')
        self.assertIn("frame-ancestors 'none'", headers['Content-Security-Policy'])

    def test_default_off_and_disable(self):
        self.assertFalse(server.load_settings(self.host.config_path)[0]['WebClientEnabled'])
        self.settings['WebClientEnabled'] = False
        self.assertEqual(self.request()[0], 404)

    def test_transport_origin_and_host_boundaries(self):
        for headers in [
            {'X-Forwarded-Proto':'http'}, {'X-Forwarded-Proto':''},
            {'Host':'evil.example'}, {'Origin':'https://evil.example'},
            {'Origin':'null'}, {'Sec-Fetch-Site':'cross-site'},
        ]:
            with self.subTest(headers=headers):
                self.assertEqual(self.request(**headers)[0], 403)
        self.settings['WebProxyAddresses'] = []
        self.assertEqual(self.request()[0], 403)

    def test_file_allowlist_no_queries_or_writes(self):
        for path in ['/web/../settings.json', '/web/%2e%2e/settings.json', '/web/settings.json',
                     '/web/client.wasm?token=private', '/web/DOMPurify-LICENSE.txt']:
            with self.subTest(path=path):
                self.assertEqual(self.request(path)[0], 404)
        self.assertEqual(self.request('/web/app.js', method='PUT')[0], 405)
        code, headers, body = self.request('/web/client.wasm', method='HEAD')
        self.assertEqual(code, 200)
        self.assertEqual(body, b'')
        self.assertEqual(headers['Content-Type'], 'application/wasm')

    def test_plain_http_and_missing_assets_cannot_enable(self):
        self.settings['AdvertiseUrl'] = ''
        with self.assertRaises(ValueError):
            server.validate_web_client(self.settings)
        self.settings['AdvertiseUrl'] = 'https://clip.example.com'
        (self.assets / 'client.wasm').unlink()
        with self.assertRaises(ValueError):
            server.validate_web_client(self.settings)

    def test_browser_api_disable_and_plaintext_upload_are_rejected(self):
        path = '/api/v1/database/' + 'a' * 43
        headers = {'X-Clipman-Web':'1', 'Authorization':'Bearer never-in-page'}
        self.assertEqual(self.request(path, method='HEAD', **headers)[0], 404)
        self.assertEqual(self.request(path, method='HEAD', Host='evil.example', **headers)[0], 403)
        headers.update({'Origin':'https://clip.example.com', 'If-None-Match':'*'})
        self.assertEqual(self.request(path, method='PUT', body=b'plaintext', **headers)[0], 400)
        self.assertFalse(server.database_path(self.settings, 'a' * 43).exists())
        self.settings['WebClientEnabled'] = False
        self.assertEqual(self.request(path, method='HEAD', **headers)[0], 403)

    def test_static_transfer_concurrency_is_bounded(self):
        for _ in range(4):
            self.host.web_transfer_slots.acquire()
        try:
            self.assertEqual(self.request('/web/client.wasm')[0], 503)
        finally:
            for _ in range(4):
                self.host.web_transfer_slots.release()
        self.assertEqual(self.request('/web/client.wasm')[0], 200)

    def test_embedded_assets_survive_old_program_only_updates(self):
        assets = {name: b'embedded ' + name.encode() for name in server.WEB_ASSETS}
        manifest = {'serverVersion': server.APP_VERSION,
                    'sha256': {name: hashlib.sha256(data).hexdigest() for name, data in assets.items()}}
        contents = {name: base64.b64encode(data).decode() for name, data in assets.items()}
        contents['browser-assets.json'] = base64.b64encode(json.dumps(manifest).encode()).decode()
        bundle = base64.b64encode(zlib.compress(json.dumps(contents).encode())).decode()
        with mock.patch.object(server, 'WEB_BUNDLE', bundle, create=True):
            self.assertEqual(server.validate_web_client(self.settings), 'https://clip.example.com')
            code, _, body = self.request('/web/app.js')
            self.assertEqual(code, 200)
            self.assertEqual(body, assets['app.js'])
            contents['app.js'] = base64.b64encode(b'tampered').decode()
            bad = base64.b64encode(zlib.compress(json.dumps(contents).encode())).decode()
            with mock.patch.object(server, 'WEB_BUNDLE', bad):
                with self.assertRaises(ValueError):
                    server.validate_web_client(self.settings)


if __name__ == '__main__':
    unittest.main()
