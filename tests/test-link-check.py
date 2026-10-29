#!/usr/bin/env python3
"""Unit tests for scripts/link-check.py (stdlib only)."""
from __future__ import annotations

import http.server
import json
import os
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts" / "link-check.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "link-check"


def _load_checker():
    import importlib.util

    spec = importlib.util.spec_from_file_location("link_check_mod", CHECKER)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


lc = _load_checker()


class _Handler(http.server.BaseHTTPRequestHandler):
    """Configurable origin server driven by path."""

    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003
        return

    def _respond(self, code, body=b"ok", headers=None):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "text/plain")
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):  # noqa: N802
        self._dispatch(head=True)

    def do_GET(self):  # noqa: N802
        self._dispatch(head=False)

    def _dispatch(self, head: bool):
        path = self.path.split("?", 1)[0]
        if path == "/ok":
            self._respond(200)
        elif path == "/forbid":
            self._respond(403)
        elif path == "/gone":
            self._respond(404)
        elif path == "/head-only-405":
            if head:
                self._respond(405)
            else:
                self._respond(200)
        elif path == "/head-forbid-get-ok":
            if head:
                self._respond(403)
            else:
                self._respond(200)
        elif path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif path == "/rate":
            # First request 429 with Retry-After: 0; subsequent 200.
            count = getattr(self.server, "rate_count", 0)
            self.server.rate_count = count + 1
            if count == 0:
                self._respond(429, headers={"Retry-After": "0"})
            else:
                self._respond(200)
        else:
            self._respond(404)


def start_server():
    httpd = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Handler)
    httpd.rate_count = 0
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    port = httpd.server_address[1]
    return httpd, f"http://127.0.0.1:{port}"


class _Proxy403(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


class _ProxyHandler(socketserver.StreamRequestHandler):
    """Minimal CONNECT proxy that always refuses with HTTP 403."""

    def handle(self):
        line = self.rfile.readline().decode("latin1", errors="replace")
        # Drain headers
        while True:
            h = self.rfile.readline()
            if h in (b"\r\n", b"\n", b""):
                break
        if line.upper().startswith("CONNECT"):
            body = b"Forbidden\n"
            self.wfile.write(
                b"HTTP/1.1 403 Forbidden\r\nContent-Length: %d\r\n\r\n" % len(body)
            )
            self.wfile.write(body)
        else:
            self.wfile.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")


def start_proxy():
    proxy = _Proxy403(("127.0.0.1", 0), _ProxyHandler)
    t = threading.Thread(target=proxy.serve_forever, daemon=True)
    t.start()
    port = proxy.server_address[1]
    return proxy, f"http://127.0.0.1:{port}"


class ExtractionTests(unittest.TestCase):
    def test_golden_urls_from_fixture(self):
        text = (FIXTURES / "sample.md").read_text(encoding="utf-8")
        urls = sorted(set(lc.extract_urls_from_text(text)))
        expected = [
            line.strip()
            for line in (FIXTURES / "expected-urls.txt").read_text().splitlines()
            if line.strip()
        ]
        self.assertEqual(urls, expected)

    def test_code_blocks_skipped(self):
        text = (FIXTURES / "sample.md").read_text(encoding="utf-8")
        urls = set(lc.extract_urls_from_text(text))
        for bad in (
            "https://extract.example/fenced-skip",
            "https://extract.example/inline-code-skip",
            "https://extract.example/indented-skip",
            "https://extract.example/code-skip",
            "https://extract.example/pre-skip",
        ):
            self.assertNotIn(bad, urls)


class CollectTests(unittest.TestCase):
    def test_exclude_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "ok.md").write_text("[a](https://x.example/a)\n", encoding="utf-8")
            vend = root / "vendor"
            vend.mkdir()
            (vend / "skip.md").write_text("[b](https://x.example/b)\n", encoding="utf-8")
            pairs = lc.collect_links(root, {"http", "https"}, [r"vendor"])
            urls = {u for _, u in pairs}
            self.assertEqual(urls, {"https://x.example/a"})


class CheckBehaviorTests(unittest.TestCase):
    def setUp(self):
        self.httpd, self.base = start_server()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def test_accept_list_403(self):
        status = lc.check_one(f"{self.base}/forbid", 5, 0, {200, 403})
        self.assertIsNone(status)

    def test_404_reported(self):
        status = lc.check_one(f"{self.base}/gone", 5, 0, {200})
        self.assertEqual(status.get("code"), 404)

    def test_head_405_falls_back_to_get(self):
        status = lc.check_one(f"{self.base}/head-only-405", 5, 0, {200})
        self.assertIsNone(status)

    def test_head_403_falls_back_to_get(self):
        # 403 not in accept → HEAD triggers GET fallback → 200 success.
        status = lc.check_one(f"{self.base}/head-forbid-get-ok", 5, 0, {200})
        self.assertIsNone(status)

    def test_redirect_followed(self):
        status = lc.check_one(f"{self.base}/redirect", 5, 0, {200})
        self.assertIsNone(status)

    def test_retry_after_429(self):
        status = lc.check_one(f"{self.base}/rate", 5, 2, {200})
        self.assertIsNone(status)

    def test_private_ip_excluded(self):
        # 10.0.0.1 is RFC1918; with --exclude-all-private it must not be checked.
        # (Do not mix in 127.0.0.1 self.base — loopback is also private.)
        pairs = [("f.md", "http://10.0.0.1/x"), ("f.md", "http://192.168.1.1/y")]
        total, errors, unchecked, error_map = lc.check_all(
            pairs,
            timeout=5,
            max_retries=0,
            max_concurrency=2,
            accept={200},
            exclude_res=[],
            exclude_private=True,
        )
        self.assertEqual(total, 0)
        self.assertEqual(errors, 0)
        self.assertEqual(unchecked, 0)
        self.assertEqual(error_map, {})
        self.assertTrue(lc.is_private_host("10.0.0.1"))
        self.assertTrue(lc.is_private_host("127.0.0.1"))

    def test_exclude_regex(self):
        pairs = [("f.md", f"{self.base}/gone"), ("f.md", f"{self.base}/ok")]
        total, errors, unchecked, error_map = lc.check_all(
            pairs,
            timeout=5,
            max_retries=0,
            max_concurrency=2,
            accept={200},
            exclude_res=[__import__("re").compile(r"/gone")],
            exclude_private=False,
        )
        self.assertEqual(total, 1)
        self.assertEqual(errors, 0)


class EgressRefusalTests(unittest.TestCase):
    def test_proxy_connect_403_is_unchecked(self):
        proxy, proxy_url = start_proxy()
        old = {k: os.environ.get(k) for k in ("http_proxy", "https_proxy", "HTTPS_PROXY", "HTTP_PROXY")}
        try:
            os.environ["https_proxy"] = proxy_url
            os.environ["http_proxy"] = proxy_url
            # Any https URL will trigger CONNECT through the refusing proxy.
            status = lc.check_one("https://unlisted.example.invalid/x", 5, 0, {200})
            self.assertIsNotNone(status)
            self.assertEqual(status.get("text"), "unchecked")
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            proxy.shutdown()
            proxy.server_close()

    def test_origin_403_without_proxy_accepted(self):
        httpd, base = start_server()
        try:
            # Ensure no proxy env.
            for k in list(os.environ):
                if k.lower() in ("http_proxy", "https_proxy", "all_proxy"):
                    os.environ.pop(k, None)
            status = lc.check_one(f"{base}/forbid", 5, 0, {200, 403})
            self.assertIsNone(status)
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_unchecked_not_in_errors_count(self):
        proxy, proxy_url = start_proxy()
        old = {k: os.environ.get(k) for k in ("http_proxy", "https_proxy", "HTTPS_PROXY", "HTTP_PROXY")}
        try:
            os.environ["https_proxy"] = proxy_url
            os.environ["http_proxy"] = proxy_url
            pairs = [("f.md", "https://unlisted.example.invalid/x")]
            total, errors, unchecked, error_map = lc.check_all(
                pairs,
                timeout=5,
                max_retries=0,
                max_concurrency=1,
                accept={200},
                exclude_res=[],
                exclude_private=False,
            )
            self.assertEqual(total, 1)
            self.assertEqual(errors, 0)
            self.assertEqual(unchecked, 1)
            self.assertEqual(error_map["f.md"][0]["status"]["text"], "unchecked")
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
            proxy.shutdown()
            proxy.server_close()


class TomlSubsetTests(unittest.TestCase):
    def test_subset_parser(self):
        text = '''
# comment
exclude = ["localhost", "example\\.com"]
exclude_path = ["vendor"]
accept = [200, 403]
ignore_me = true
'''
        with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as fh:
            fh.write(text)
            path = Path(fh.name)
        try:
            cfg = lc.load_lychee_toml(path)
            self.assertIn("exclude", cfg)
            self.assertEqual(cfg["exclude_path"], ["vendor"])
            self.assertEqual(cfg["accept"], [200, 403])
            self.assertNotIn("ignore_me", cfg)
        finally:
            path.unlink(missing_ok=True)


class CliSmokeTests(unittest.TestCase):
    def test_cli_emits_json(self):
        httpd, base = start_server()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "a.md").write_text(f"[ok]({base}/ok)\n[bad]({base}/gone)\n", encoding="utf-8")
                proc = subprocess.run(
                    [
                        sys.executable,
                        str(CHECKER),
                        "--format",
                        "json",
                        "--scheme",
                        "http",
                        "--scheme",
                        "https",
                        "--accept",
                        "200",
                        "--timeout",
                        "5",
                        "--max-retries",
                        "0",
                        "--max-concurrency",
                        "2",
                        str(root),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(proc.returncode, 0, proc.stderr)
                report = json.loads(proc.stdout)
                self.assertEqual(report["total"], 2)
                self.assertEqual(report["errors"], 1)
                self.assertIn("a.md", report["error_map"])
        finally:
            httpd.shutdown()
            httpd.server_close()

    def test_optional_lychee_extraction_compare(self):
        """If lychee is on PATH, compare extracted URL sets via --exclude '.*'."""
        import shutil

        if not shutil.which("lychee"):
            self.skipTest("lychee not on PATH")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sample = (FIXTURES / "sample.md").read_text(encoding="utf-8")
            (root / "sample.md").write_text(sample, encoding="utf-8")
            # Exclude everything so lychee does not hit the network; URLs land in excluded_map.
            proc = subprocess.run(
                [
                    "lychee",
                    "--format",
                    "json",
                    "--scheme",
                    "http",
                    "--scheme",
                    "https",
                    "--exclude",
                    ".*",
                    str(root),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if proc.returncode not in (0, 1, 2):
                self.skipTest(f"lychee failed unexpectedly: {proc.stderr}")
            try:
                report = json.loads(proc.stdout or "{}")
            except json.JSONDecodeError:
                self.skipTest("lychee did not emit JSON")
            lychee_urls = set()
            for entries in (report.get("excluded_map") or {}).values():
                for e in entries:
                    if isinstance(e, dict) and "url" in e:
                        lychee_urls.add(e["url"])
                    elif isinstance(e, str):
                        lychee_urls.add(e)
            ours = set(lc.extract_urls_from_text(sample))
            # We only require our extractor URLs ⊆ lychee's for the shared formats;
            # lychee may also find mailto:/etc. that we skip by scheme later.
            missing = ours - lychee_urls
            self.assertFalse(missing, f"URLs we extract that lychee did not: {missing}")


if __name__ == "__main__":
    unittest.main()
