"""Loopback-only HTTPS recorder; every request is appended before responding."""

import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import ssl
import subprocess
import threading


class HttpsRecorder:
    def __init__(self, directory, respond):
        self.ca_file = directory / "localhost.crt"
        key = directory / "localhost.key"
        self.ledger = directory / "requests.jsonl"
        self.ledger.write_text("")
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-days", "1", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost",
            "-keyout", str(key), "-out", str(self.ca_file),
        ], check=True, capture_output=True, timeout=15)
        key.chmod(0o600)
        recorder = self
        self.sequence = 0

        class Handler(BaseHTTPRequestHandler):
            def handle_request(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                recorder.sequence += 1
                record = {
                    "sequence": recorder.sequence,
                    "method": self.command,
                    "path": self.path,
                    "headers": list(self.headers.items()),
                    "body_base64": base64.b64encode(body).decode(),
                }
                with recorder.ledger.open("a") as ledger:
                    ledger.write(json.dumps(record) + "\n")
                status, headers, response = respond(record)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                for name, value in headers.items():
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(response)

            do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_request

            def log_message(self, *_):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.ca_file, key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.origin = f"https://127.0.0.1:{self.server.server_port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def records(self):
        return [json.loads(line) for line in self.ledger.read_text().splitlines()]
