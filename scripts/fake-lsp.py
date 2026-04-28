#!/usr/bin/env python3
"""Tiny fake LSP server used by smoke tests. Speaks the bare minimum
of the protocol velk's `lsp_diagnostics` tool needs:

  1. read `initialize` request, reply with empty result
  2. read `initialized` notification (ignore)
  3. read `textDocument/didOpen` notification, immediately push back a
     `textDocument/publishDiagnostics` for the same URI with one
     hardcoded error so the smoke can assert the round-trip worked
  4. read `exit` notification (or EOF) and quit

LSP frames are Content-Length: <n>\\r\\n\\r\\n<body>. Stdlib only.
"""

from __future__ import annotations

import json
import sys


def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.rstrip(b"\r\n")
        if not line:
            break
        if b":" in line:
            k, v = line.split(b":", 1)
            headers[k.strip().decode("ascii").lower()] = v.strip().decode("ascii")
    n = int(headers.get("content-length", "0"))
    if n <= 0:
        return None
    body = sys.stdin.buffer.read(n)
    return json.loads(body)


def write_message(obj):
    body = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def main():
    while True:
        msg = read_message()
        if msg is None:
            return
        method = msg.get("method")
        if method == "initialize":
            write_message({"jsonrpc": "2.0", "id": msg["id"], "result": {"capabilities": {}}})
        elif method == "textDocument/didOpen":
            uri = msg["params"]["textDocument"]["uri"]
            write_message({
                "jsonrpc": "2.0",
                "method": "textDocument/publishDiagnostics",
                "params": {
                    "uri": uri,
                    "diagnostics": [
                        {
                            "range": {
                                "start": {"line": 0, "character": 4},
                                "end": {"line": 0, "character": 9},
                            },
                            "severity": 1,
                            "message": "fake-lsp-marker: synthetic error",
                        }
                    ],
                },
            })
        elif method == "exit":
            return


if __name__ == "__main__":
    main()
