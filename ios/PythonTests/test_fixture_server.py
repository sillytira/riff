import functools
import http.client
import http.server
import importlib.util
from pathlib import Path
import tempfile
import threading
import unittest

_spec = importlib.util.spec_from_file_location('fixture_server', Path(__file__).parents[1] / 'scripts/fixture-server.py')
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)


class MediaFixtureTests(unittest.TestCase):
    def test_complete_partial_suffix_and_unsatisfiable_media_requests(self):
        with tempfile.TemporaryDirectory() as directory:
            original = bytes(range(256)) * 800
            Path(directory, 'audio.wav').write_bytes(original)
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(_module.MediaHandler, directory=directory))
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                for header, status, expected in [(None, 200, original), ('bytes=0-1', 206, original[:2]), ('bytes=64000-70000', 206, original[64000:70001]), ('bytes=-20', 206, original[-20:]), ('bytes=204800-', 416, b'')]:
                    connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
                    connection.request('GET', '/audio.wav', headers={'Range': header} if header else {})
                    response = connection.getresponse()
                    self.assertEqual(response.status, status)
                    self.assertEqual(response.read(), expected)
                    connection.close()
            finally:
                server.shutdown()
                server.server_close()
                worker.join()
