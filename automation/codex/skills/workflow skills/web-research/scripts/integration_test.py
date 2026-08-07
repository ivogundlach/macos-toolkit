#!/usr/bin/env python3
"""Controlled localhost integration tests for pinned fetch connections."""

from __future__ import annotations

import importlib.util
import json
import ssl
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("fetch_url.py")
SPEC = importlib.util.spec_from_file_location("fetch_url", MODULE_PATH)
fetch_url = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(fetch_url)


class QuietHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


def start_server(handler, tls_context: ssl.SSLContext | None = None):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    if tls_context is not None:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


class FetchIntegrationTests(unittest.TestCase):
    def test_redirect_loop_exhausts_finite_cap_without_completion(self):
        class LoopHandler(QuietHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header(
                    "Location", f"http://loop.test:{self.server.server_port}/loop"
                )
                self.end_headers()

        server, thread = start_server(LoopHandler)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                with mock.patch.object(fetch_url, "resolve_public", return_value="127.0.0.1") as resolve:
                    with self.assertRaises(fetch_url.FetchError):
                        fetch_url.fetch(
                            f"http://loop.test:{server.server_port}/loop",
                            Path(temporary),
                            "text/html",
                            100_000,
                            3.0,
                            2,
                        )
                self.assertEqual(resolve.call_count, 3)
                self.assertFalse((Path(temporary) / "complete.json").exists())
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_real_redirect_socket_repins_and_rebind_is_rejected(self):
        class RedirectHandler(QuietHandler):
            def do_GET(self):
                if self.path == "/start":
                    self.send_response(302)
                    self.send_header(
                        "Location", f"http://second.test:{self.server.server_port}/final"
                    )
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(b"<html><body><h1>Final evidence</h1></body></html>")

        server, thread = start_server(RedirectHandler)
        try:
            with tempfile.TemporaryDirectory() as temporary:
                calls = []

                def pinned(host, port, resolver):
                    calls.append(host)
                    return "127.0.0.1"

                with mock.patch.object(fetch_url, "resolve_public", side_effect=pinned):
                    metadata = fetch_url.fetch(
                        f"http://first.test:{server.server_port}/start",
                        Path(temporary),
                        "text/html",
                        100_000,
                        3.0,
                        3,
                    )
                self.assertEqual(calls, ["first.test", "second.test"])
                self.assertEqual(metadata["status"], 200)
                self.assertEqual(len(metadata["redirect_chain"]), 2)
                self.assertTrue((Path(temporary) / "complete.json").is_file())
                self.assertIn("Final evidence", (Path(temporary) / "text.txt").read_text())

            with tempfile.TemporaryDirectory() as temporary:
                calls = []

                def rebound(host, port, resolver):
                    calls.append(host)
                    if len(calls) == 1:
                        return "127.0.0.1"
                    raise fetch_url.FetchError("DNS returned a non-public address")

                with mock.patch.object(fetch_url, "resolve_public", side_effect=rebound):
                    with self.assertRaises(fetch_url.FetchError):
                        fetch_url.fetch(
                            f"http://first.test:{server.server_port}/start",
                            Path(temporary),
                            "text/html",
                            100_000,
                            3.0,
                            3,
                        )
                self.assertEqual(calls, ["first.test", "second.test"])
                self.assertFalse((Path(temporary) / "complete.json").exists())
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_real_tls_socket_uses_original_hostname_for_validation(self):
        class TLSHandler(QuietHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"tls ok")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "openssl.cnf"
            cert = root / "cert.pem"
            key = root / "key.pem"
            config.write_text(
                "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=v3\n"
                "[dn]\nCN=example.test\n"
                "[v3]\nsubjectAltName=DNS:example.test\nbasicConstraints=CA:TRUE\n"
                "keyUsage=digitalSignature,keyEncipherment,keyCertSign\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "/usr/bin/openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-days",
                    "1",
                    "-config",
                    str(config),
                    "-keyout",
                    str(key),
                    "-out",
                    str(cert),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(cert, key)
            server, thread = start_server(TLSHandler, server_context)
            try:
                client_context = ssl.create_default_context(cafile=str(cert))
                connection = fetch_url.PinnedHTTPSConnection(
                    "example.test",
                    server.server_port,
                    "127.0.0.1",
                    3.0,
                    context=client_context,
                )
                connection.request("GET", "/")
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), b"tls ok")
                connection.close()

                wrong = fetch_url.PinnedHTTPSConnection(
                    "wrong.test",
                    server.server_port,
                    "127.0.0.1",
                    3.0,
                    context=client_context,
                )
                with self.assertRaises(ssl.SSLCertVerificationError):
                    wrong.request("GET", "/")
                wrong.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
