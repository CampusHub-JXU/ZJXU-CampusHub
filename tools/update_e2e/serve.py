"""Static file server for the update e2e test origin.

`python -m http.server` streams files through small default chunks on Windows and
ignores Range, which made the emulator download (via the 10.0.2.2 NAT) crawl and
forced DownloadManager to restart from zero on any reconnect. This server:
- serves each request on its own thread (ThreadingHTTPServer);
- sends in 1 MiB chunks over a socket with a 4 MiB send buffer and TCP_NODELAY;
- answers single-range `Range: bytes=a-b` requests with 206 + Content-Range.

Usage: python serve.py <port> <bind> <directory>
"""
import http.server
import os
import re
import socket
import sys
from functools import partial

CHUNK = 1024 * 1024
RANGE = re.compile(r"^bytes=(\d*)-(\d*)$")


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * CHUNK)
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def do_GET(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return super().do_GET()
        size = os.path.getsize(path)
        start, end = 0, size - 1
        match = RANGE.match(self.headers.get("Range", "").strip())
        if match and (match.group(1) or match.group(2)):
            if match.group(1):
                start = int(match.group(1))
                if match.group(2):
                    end = min(int(match.group(2)), size - 1)
            else:  # suffix range: last N bytes
                start = max(size - int(match.group(2)), 0)
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(200)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        remaining = end - start + 1
        with open(path, "rb") as f:
            f.seek(start)
            while remaining > 0:
                data = f.read(min(CHUNK, remaining))
                if not data:
                    break
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(data)


def main():
    port, bind, directory = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    server = http.server.ThreadingHTTPServer((bind, port), partial(Handler, directory=directory))
    print(f"serving {directory} on {bind}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
