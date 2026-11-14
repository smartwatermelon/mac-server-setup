#!/usr/bin/env python3
"""Stand-in for Home Assistant in tests/caddyfile.bats.

Usage: upstream-stub.py PORT LOG_FILE. Logs each request's path and headers
as a JSON line, then answers 200 "ha-upstream", or 101 to a websocket upgrade.
"""

import base64
import hashlib
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2]
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        record = {"path": self.path}
        for name in (
            "Host",
            "X-Forwarded-For",
            "X-Forwarded-Proto",
            "X-Forwarded-Host",
            "Cookie",
            "Cf-Access-Jwt-Assertion",
            "Upgrade",
        ):
            record[name] = self.headers.get(name)
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(json.dumps(record) + "\n")
        if (self.headers.get("Upgrade") or "").lower() == "websocket":
            key = self.headers.get("Sec-WebSocket-Key") or ""
            accept = base64.b64encode(
                hashlib.sha1((key + WS_GUID).encode()).digest()
            ).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            self.wfile.flush()
            time.sleep(3)
            self.close_connection = True
            return
        body = b"ha-upstream"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
