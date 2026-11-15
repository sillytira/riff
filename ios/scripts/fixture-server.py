#!/usr/bin/env python3
"""Loopback-only media fixtures with the byte ranges AVPlayer uses for seeking."""
import argparse
import functools
import http.server
import os
import re
import ssl
import time


class MediaHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def send_head(self):
        self.remaining = None
        self.slow = self.path.startswith('/slow/')
        if self.slow: self.path = self.path.removeprefix('/slow')
        if self.path == '/redirect-cross-host':
            self.send_response(302)
            self.send_header('Location', 'http://localhost:8765/no-auth/ui-tone.wav')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return None
        if self.path.startswith('/no-auth/'):
            if self.headers.get('Authorization') or self.headers.get('Cookie'):
                self.send_error(403, 'Credentials must not cross origins')
                return None
            self.path = self.path.removeprefix('/no-auth')
        if self.path in ['/hls/untrusted-child.m3u8', '/hls/cross-origin.m3u8']:
            if 'untrusted' in self.path: target = 'https://127.0.0.1:8766/hls/segment0.ts'
            else: target = 'http://localhost:8765/no-auth/hls/segment0.ts'
            data = ('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:0.511,\n' + target + '\n#EXT-X-ENDLIST\n').encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            if self.command != 'HEAD': self.wfile.write(data)
            return None
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return super().send_head()
        file = open(path, 'rb')
        length = os.fstat(file.fileno()).st_size
        header = self.headers.get('Range')
        start, end = 0, length - 1
        if header:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', header.strip())
            valid = match and any(match.groups()) and length > 0
            if valid:
                first, last = match.groups()
                if first:
                    start = int(first)
                    end = min(int(last), length - 1) if last else length - 1
                else:
                    count = int(last)
                    start = max(0, length - count)
                    valid = count > 0
                valid = valid and start < length and start <= end
            if not valid:
                file.close()
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{length}')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return None
        self.send_response(206 if header else 200)
        self.send_header('Content-Type', self.guess_type(path))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(max(0, end - start + 1)))
        if header:
            self.send_header('Content-Range', f'bytes {start}-{end}/{length}')
        self.end_headers()
        file.seek(start)
        self.remaining = max(0, end - start + 1)
        return file

    def copyfile(self, source, outputfile):
        try:
            if self.remaining is None:
                return super().copyfile(source, outputfile)
            while self.remaining > 0:
                data = source.read(min(self.remaining, 16384 if self.slow else 65536))
                if not data:
                    break
                outputfile.write(data)
                self.remaining -= len(data)
                if self.slow: time.sleep(0.03)
        except (BrokenPipeError, ConnectionResetError):
            # AVPlayer intentionally cancels speculative reads when seeking.
            pass


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--directory', default='ios/RiffTests/Fixtures')
    parser.add_argument('--tls-cert')
    parser.add_argument('--tls-key')
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), functools.partial(MediaHandler, directory=args.directory))
    if args.tls_cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
