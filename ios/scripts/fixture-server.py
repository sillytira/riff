#!/usr/bin/env python3
"""Loopback-only media fixtures with the byte ranges AVPlayer uses for seeking."""
import argparse
import functools
import http.server
import os
import re


class MediaHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def send_head(self):
        self.remaining = None
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
                data = source.read(min(self.remaining, 65536))
                if not data:
                    break
                outputfile.write(data)
                self.remaining -= len(data)
        except (BrokenPipeError, ConnectionResetError):
            # AVPlayer intentionally cancels speculative reads when seeking.
            pass


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--directory', default='ios/RiffTests/Fixtures')
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', args.port), functools.partial(MediaHandler, directory=args.directory))
    server.serve_forever()
