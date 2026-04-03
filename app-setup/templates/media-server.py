#!/usr/bin/env python3
"""Lightweight HTTP file server for NFS-mounted media.

Serves directory listings and file downloads from the NAS media NFS mount.
Listens on localhost only — Caddy reverse-proxies /media/* to this server.

Runs as the service user (who owns the NFS mount) via a LaunchDaemon,
because the Caddy LaunchDaemon (running as root) gets EPERM from NFS
due to macOS NFS credential handling for launchd-spawned root processes.
"""

import http.server
import os
import sys

BIND_ADDRESS = "127.0.0.1"
PORT = 9880
SERVE_DIR = "/Users/__OPERATOR_USERNAME__/.local/mnt/__NAS_SHARE_NAME__"


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler that serves from SERVE_DIR.

    Self-heals from stale NFS handles: if os.listdir() fails (e.g. after
    the NAS restarts and NFS file handles become invalid), exits so launchd
    restarts the process with fresh handles.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=SERVE_DIR, **kwargs)

    def list_directory(self, path):
        try:
            os.listdir(path)
        except OSError:
            print(
                f"NFS access failed for {path} — exiting for launchd restart",
                file=sys.stderr,
            )
            sys.stderr.flush()
            os._exit(1)
        return super().list_directory(path)

    def log_message(self, format, *args):
        # Caddy already logs access — suppress duplicate stdout logging
        pass


if __name__ == "__main__":
    if not os.path.isdir(SERVE_DIR):
        print(
            f"Error: {SERVE_DIR} is not a directory (mount may be down)",
            file=sys.stderr,
        )
        sys.exit(1)

    server = http.server.HTTPServer((BIND_ADDRESS, PORT), QuietHandler)
    print(
        f"Serving {SERVE_DIR} on http://{BIND_ADDRESS}:{PORT}",
        file=sys.stderr,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
