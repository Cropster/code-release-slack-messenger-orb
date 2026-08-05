#!/usr/bin/env python3
"""Minimal stand-in for a Slack incoming webhook, used by tests/run_tests.sh.

Records every request body to --outdir/req_<n>.json and replies with a
configurable status so the caller's error handling can be exercised.

Binds to an ephemeral port and prints "PORT <n>" on stdout once listening.
"""
import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    count_lock = threading.Lock()
    count = 0

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)

        with Handler.count_lock:
            Handler.count += 1
            n = Handler.count

        with open(os.path.join(self.server.outdir, "req_%04d.json" % n), "wb") as fh:
            fh.write(body)

        meta = {
            "content_type": self.headers.get("Content-type"),
            "length": length,
        }
        with open(os.path.join(self.server.outdir, "meta_%04d.json" % n), "w") as fh:
            json.dump(meta, fh)

        status = self.server.status
        if self.server.fail_after is not None and n > self.server.fail_after:
            status = self.server.fail_status

        payload = b"ok" if status == 200 else b"invalid_blocks"
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--status", type=int, default=200)
    ap.add_argument("--fail-after", type=int, default=None,
                    help="serve --status for the first N requests, then --fail-status")
    ap.add_argument("--fail-status", type=int, default=500)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    srv.outdir = args.outdir
    srv.status = args.status
    srv.fail_after = args.fail_after
    srv.fail_status = args.fail_status

    print("PORT %d" % srv.server_address[1], flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
