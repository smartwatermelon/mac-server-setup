#!/usr/bin/python3
"""Plex webhook listener for the TVmaze scrobbler (docs/components/tvmaze-scrobble.md).

Hands media.scrobble episode payloads to the worker; always answers fast.
"""

# Plex POSTs multipart/form-data with a JSON "payload" field. Parsed with
# the email package (cgi is deprecated). Stdlib only, python 3.9.

# Every request gets an answer at once, so Plex never retries or disables
# the webhook. Test overrides: TVMAZE_SCROBBLE_PORT, _WORKER, _BASH.

# Author: Andrew Rich <andrew.rich@gmail.com>
# Created: 2026-11-05

import argparse
import email.parser
import email.policy
import json
import os
import signal
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

# Plex attaches a poster thumbnail to some events; a few MB is plenty.
MAX_BODY_BYTES = 16 * 1024 * 1024


def log(message):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print("[{}] [tvmaze-listener] {}".format(stamp, message), flush=True)


def extract_payload(content_type, body):
    """Return the parsed "payload" JSON object, or None.

    Accepts multipart/form-data (what Plex sends) and, for manual tests,
    a bare application/json body.
    """
    if content_type.lower().startswith("application/json"):
        raw = body
    elif content_type.lower().startswith("multipart/form-data"):
        header = "Content-Type: {}\r\nMIME-Version: 1.0\r\n\r\n".format(content_type)
        message = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
            header.encode("latin-1") + body
        )
        raw = None
        if message.is_multipart():
            for part in message.iter_parts():
                if part.get_param("name", header="content-disposition") == "payload":
                    raw = part.get_payload(decode=True)
                    break
        if raw is None:
            return None
    else:
        return None
    try:
        data = json.loads(raw.decode("utf-8"))
    except ValueError:  # UnicodeDecodeError is a ValueError
        return None
    return data if isinstance(data, dict) else None


def describe(payload):
    meta = payload.get("Metadata") or {}
    account = payload.get("Account") or {}
    return "{} S{}E{} (account '{}', plex.tv id {})".format(
        meta.get("grandparentTitle", "?"),
        meta.get("parentIndex", "?"),
        meta.get("index", "?"),
        account.get("title", "?"),
        account.get("id", "?"),
    )


class Handler(BaseHTTPRequestHandler):
    server_version = "tvmaze-scrobble-listener"
    worker = ""
    bash = "/bin/bash"

    def log_message(self, format, *args):  # noqa: A002 (stdlib signature)
        pass  # one line per accepted event is logged instead

    def _reply(self, code, text="ok"):
        body = (text + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # Health check for the setup script.
        self._reply(200)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length < 0:
            self._reply(400, "bad length")
            return
        if length > MAX_BODY_BYTES:
            self._reply(413, "too large")
            return
        body = self.rfile.read(length)
        payload = extract_payload(self.headers.get("Content-Type", ""), body)
        if payload is None:
            self._reply(400, "no payload")
            return
        event = payload.get("event")
        meta = payload.get("Metadata") or {}
        if event != "media.scrobble" or meta.get("type") != "episode":
            self._reply(200, "ignored")
            return
        self._reply(200)
        self.run_worker(payload)

    def run_worker(self, payload):
        log("scrobble: {} -> worker".format(describe(payload)))
        try:
            proc = subprocess.Popen(
                [self.bash, self.worker],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
            # The payload is a few KB: the pipe buffer takes it whole.
            proc.stdin.write(json.dumps(payload).encode("utf-8"))
            proc.stdin.close()
        except OSError as exc:
            log("ERROR: could not start worker {}: {}".format(self.worker, exc))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("TVMAZE_SCROBBLE_PORT", "32599"))
    )
    parser.add_argument(
        "--worker",
        default=os.environ.get(
            "TVMAZE_SCROBBLE_WORKER",
            os.path.expanduser("~/.local/bin/tvmaze-scrobble"),
        ),
    )
    args = parser.parse_args(argv)

    # Workers are never waited for: let the kernel reap them, so this
    # long-running process does not collect zombies.
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)

    Handler.worker = args.worker
    Handler.bash = os.environ.get("TVMAZE_SCROBBLE_BASH", "/bin/bash")
    # Loopback only: Plex runs on this host.
    server = HTTPServer(("127.0.0.1", args.port), Handler)
    log("listening on 127.0.0.1:{}, worker {}".format(args.port, args.worker))
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
