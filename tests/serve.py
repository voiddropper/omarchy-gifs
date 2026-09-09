#!/usr/bin/env python3
"""Hostile HTTPS responses, for the byte-cap tests.

Serves the response shapes a byte cap has to survive -- specifically the ones a
post-download size check cannot catch, because the damage is done by the time
the transfer ends:

  /ok-small            a real GIF with a truthful Content-Length
  /ok-json             a small JSON body, for the search-response path
  /sized?n=N           exactly N bytes, chunked, NO Content-Length
                       &piece=B&delay=MS to trickle it at a controlled rate
  /declared-oversized  a huge Content-Length, so curl can refuse it up front
  /chunked-oversized   chunked, NO Content-Length, streams until it is cut off
  /never-ending        chunked, NO Content-Length, trickles forever
  /json-oversized      the same, as JSON, for the search-response path
  /redirect-offsite    302 to a host outside the allowlist
  /redirect-onsite     302 to /ok-small
  /report              JSON: how many bytes each path actually managed to send

The /report counters are the point of the exercise. They are how a test tells
"the transfer was aborted at the cap" apart from "the transfer ran to
completion and something deleted the file afterwards" -- the two look identical
if you only check whether the file is there at the end.
"""

import json
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# A 1x1 transparent GIF: small, and a real GIF as far as any decoder is concerned.
TINY_GIF = (
    b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01"
    b"\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"
)

CHUNK = b"\0" * 65536
# Far more than any cap under test, so "it sent everything" and "it was cut off
# at the cap" are orders of magnitude apart and cannot be confused.
FLOOD_TOTAL = 256 * 1024 * 1024

sent_lock = threading.Lock()
sent_bytes = {}
hits = {}


def record(path, n):
    with sent_lock:
        sent_bytes[path] = sent_bytes.get(path, 0) + n


def hit(path):
    with sent_lock:
        hits[path] = hits.get(path, 0) + 1


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # -- helpers ------------------------------------------------------------
    def _chunk_header(self):
        self.send_response(200)
        self.send_header("Content-Type", "image/gif")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def _write_chunk(self, path, data):
        """Write one chunk. Returns False once the client has gone away."""
        try:
            self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False
        record(path, len(data))
        return True

    # -- routes -------------------------------------------------------------
    def do_GET(self):
        parsed = urlparse(self.path)
        route = parsed.path
        hit(route)

        if route == "/report":
            with sent_lock:
                body = json.dumps({"sent": sent_bytes, "hits": hits}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if route == "/ok-json":
            body = b'{"data":[],"meta":{"status":200}}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            record(route, len(body))
            return

        if route == "/ok-small":
            self.send_response(200)
            self.send_header("Content-Type", "image/gif")
            self.send_header("Content-Length", str(len(TINY_GIF)))
            self.end_headers()
            self.wfile.write(TINY_GIF)
            record(route, len(TINY_GIF))
            return

        if route == "/sized":
            q = parse_qs(parsed.query)
            n = int((q.get("n") or ["0"])[0])
            # piece/delay let a test hold a transfer open long enough to see
            # how many bytes reached the disk while it was still running.
            piece_size = max(1, int((q.get("piece") or [str(len(CHUNK))])[0]))
            delay = float((q.get("delay") or ["0"])[0]) / 1000.0
            self._chunk_header()
            left = n
            first = True
            while left > 0:
                size = min(left, piece_size)
                if not first and delay:
                    time.sleep(delay)
                first = False
                if not self._write_chunk(route, b"\0" * size):
                    return
                left -= size
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            return

        if route == "/declared-oversized":
            # A truthful-looking length far over any cap: curl should refuse
            # this before it reads a single byte of body.
            self.send_response(200)
            self.send_header("Content-Type", "image/gif")
            self.send_header("Content-Length", str(FLOOD_TOTAL))
            self.end_headers()
            left = FLOOD_TOTAL
            while left > 0:
                piece = CHUNK[: min(left, len(CHUNK))]
                try:
                    self.wfile.write(piece)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    return
                record(route, len(piece))
                left -= len(piece)
            return

        if route in ("/chunked-oversized", "/json-oversized"):
            # No Content-Length at all, so --max-filesize has nothing to act
            # on. Only a cap applied to the arriving bytes can stop this.
            if route == "/json-oversized":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                if not self._write_chunk(route, b'{"data":['):
                    return
            else:
                self._chunk_header()
            left = FLOOD_TOTAL
            while left > 0:
                piece = CHUNK[: min(left, len(CHUNK))]
                if not self._write_chunk(route, piece):
                    return
                left -= len(piece)
            return

        if route == "/never-ending":
            # Trickles below any cap, forever, and never closes: the thing a
            # byte cap alone cannot end. A request timeout has to.
            self._chunk_header()
            while True:
                if not self._write_chunk(route, b"\0" * 512):
                    return
                time.sleep(0.05)

        if route == "/redirect-offsite":
            self.send_response(302)
            self.send_header("Location", "https://evil.example/x.gif")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if route == "/redirect-onsite":
            self.send_response(302)
            self.send_header("Location", "/ok-small")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


def main():
    cert, key = sys.argv[1], sys.argv[2]
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    # The runner waits for this line to know the port.
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
