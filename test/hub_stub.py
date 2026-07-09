#!/usr/bin/env python3
"""Harness stub for :GT publish: captures one POST, replies like the guild.

Usage: hub_stub.py <port> <capture-file>
Writes "AUTH:<Authorization header>" + newline + raw body to the capture file.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(sys.argv[2], "wb") as f:
            f.write(b"AUTH:" + (self.headers.get("Authorization") or "").encode() + b"\n" + body)
        payload = {
            "ok": True,
            "user": "harness",
            "rank": 1,
            "total_users": 3,
            "best_wpm": 72,
            "suspicious": False,
        }
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args: object) -> None:
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
