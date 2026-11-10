#!/usr/bin/env python3
"""Unit tests for scripts/link-check.py (stdlib only)."""
from __future__ import annotations

import email.utils
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
    # Register before exec_module: Python 3.14 requires sys.modules to hold
    # the module while it executes (same issue that broke doc-drift's tests).
    sys.modules[spec.name] = mod
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
        elif path == "/head-forbid-get-gone":
            if head:
                self._respond(403)
            else:
                self._respond(404)
        elif path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif path == "/redirect-private":
            self.send_response(302)
            self.send_header("Location", "http://10.0.0.1/secret")
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
        elif path == "/rate-always":
            self._respond(429, headers={"Retry-After": "0"})
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
            "https://extract.example/pre-bare-skip",
            "https://extract.example/list-item-code-skip",
        ):
            self.assertNotIn(bad, urls)

    def test_parenthesized_urls_kept(self):
        # A ')' in the URL used to truncate it (Wikipedia-style false 404s).
        text = (
            "[wiki](https://extract.example/wiki/Foo_(bar))\n"
            "bare https://extract.example/bare_(paren) here\n"
            "period https://extract.example/period_(paren).\n"
        )
        urls = set(lc.extract_urls_from_text(text))
        self.assertIn("https://extract.example/wiki/Foo_(bar)", urls)
        self.assertIn("https://extract.example/bare_(paren)", urls)
        self.assertIn("https://extract.example/period_(paren)", urls)

    def test_prose_closing_paren_trimmed(self):
        text = "see <https://extract.example/autolink-paren)>) and more\n"
        urls = set(lc.extract_urls_from_text(text))
        self.assertIn("https://extract.example/autolink-paren", urls)

    def test_prose_parenthesized_url_extracted(self):
        # The bare-URL lookbehind used to drop any URL immediately after "(",
        # so prose like "(see https://x/y)" or "(https://x/y)" was never checked.
        text = "See (https://extract.example/paren) and (also https://extract.example/paren2 here).\n"
        urls = set(lc.extract_urls_from_text(text))
        self.assertIn("https://extract.example/paren", urls)
        self.assertIn("https://extract.example/paren2", urls)

    def test_links_in_nested_lists_extracted(self):
        # 4-space-indented lines inside list items used to be blanked as code.
        text = (
            "- outer item\n"
            "  - nested item: [nested](https://extract.example/nested-list)\n"
            "    four-space prose inside the nested item: https://extract.example/list-item-prose\n"
            "- loose item\n"
            "\n"
            "  continuation after a blank: https://extract.example/loose-list-continuation\n"
        )
        urls = set(lc.extract_urls_from_text(text))
        self.assertIn("https://extract.example/nested-list", urls)
        self.assertIn("https://extract.example/list-item-prose", urls)
        self.assertIn("https://extract.example/loose-list-continuation", urls)

    def test_indented_paragraph_continuation_extracted(self):
        text = (
            "Paragraph line\n"
            "    lazy continuation with https://extract.example/paragraph-continuation\n"
        )
        urls = set(lc.extract_urls_from_text(text))
        self.assertIn("https://extract.example/paragraph-continuation", urls)

    def test_indented_code_still_skipped(self):
        text = (
            "top level\n"
            "\n"
            "    https://extract.example/top-level-code-skip\n"
            "- item\n"
            "\n"
            "        https://extract.example/deep-item-code-skip\n"
        )
        urls = set(lc.extract_urls_from_text(text))
        self.assertNotIn("https://extract.example/top-level-code-skip", urls)
        self.assertNotIn("https://extract.example/deep-item-code-skip", urls)

    def test_unused_reference_definition_skipped(self):
        text = "[ref]: https://extract.example/reference\n"
        self.assertNotIn("https://extract.example/reference", lc.extract_urls_from_text(text))

    def test_used_reference_definition_kept(self):
        text = "See [docs][ref].\n\n[ref]: https://extract.example/reference\n"
        self.assertIn("https://extract.example/reference", lc.extract_urls_from_text(text))

    def test_shortcut_reference_link_extracted(self):
        # "[docs]" alone (no [ref] pair) is a valid CommonMark shortcut
        # reference; its definition used to be dropped as unused.
        text = "See [docs].\n\n[docs]: https://extract.example/shortcut\n"
        self.assertIn("https://extract.example/shortcut", lc.extract_urls_from_text(text))

    def test_html_indented_link_extracted(self):
        # In HTML a four-space indent is formatting, not a code block.
        text = '<p>intro</p>\n\n    <a href="https://extract.example/html-indent">x</a>\n'
        urls_html = set(lc.extract_urls_from_text(text, is_html=True))
        self.assertIn("https://extract.example/html-indent", urls_html)
        # The markdown path still treats the same indent as a code block.
        urls_md = set(lc.extract_urls_from_text(text))
        self.assertNotIn("https://extract.example/html-indent", urls_md)

    def test_html_pre_bare_url_skipped(self):
        # <pre>/<code> exclusion must apply to every extraction pass
        # (bare URLs used to be collected before the parser's skip).
        text = "<pre>https://extract.example/pre-bare-skip</pre>\n"
        self.assertNotIn("https://extract.example/pre-bare-skip", lc.extract_urls_from_text(text))
        self.assertNotIn(
            "https://extract.example/pre-bare-skip",
            lc.extract_urls_from_text(text, is_html=True),
        )

    def test_collect_html_indented_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "page.html").write_text(
                '<p>intro</p>\n\n    <a href="https://extract.example/html-collect">x</a>\n',
                encoding="utf-8",
            )
            pairs = lc.collect_links(root, {"http", "https"}, [])
            self.assertIn("https://extract.example/html-collect", {u for _, u in pairs})


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

    def test_malformed_url_survives_collection(self):
        # urlsplit raises ValueError on "http://[::1" (unclosed IPv6 bracket);
        # one such string in any scanned file must not kill the run.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a.md").write_text(
                "see http://[::1 for docs\n[x](https://ok.example/y)\n",
                encoding="utf-8",
            )
            (root / "b.html").write_text(
                '<a href="ftp://[::1">ftp</a>\n', encoding="utf-8"
            )
            pairs = lc.collect_links(root, {"http", "https"}, [])
            urls = {u for _, u in pairs}
            # A malformed URL claiming to be a web link is a real doc bug:
            # keep it so the checker reports it instead of crashing.
            self.assertIn("http://[::1", urls)
            self.assertIn("https://ok.example/y", urls)
            # A malformed non-web scheme is dropped, not crashed on.
            self.assertNotIn("ftp://[::1", urls)


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

    def test_head_403_falls_back_even_when_accepted(self):
        # 403 in accept must not short-circuit the GET fallback: the HEAD
        # denial says nothing about the real answer.
        status = lc.check_one(f"{self.base}/head-forbid-get-ok", 5, 0, {200, 403})
        self.assertIsNone(status)

    def test_head_403_get_404_reported(self):
        # The accuracy improvement: HEAD-403/GET-404 used to be silently
        # accepted (403 in the accept list); the GET answer is the real one.
        status = lc.check_one(f"{self.base}/head-forbid-get-gone", 5, 0, {200, 403})
        self.assertIsNotNone(status)
        self.assertEqual(status.get("code"), 404)

    def test_redirect_followed(self):
        status = lc.check_one(f"{self.base}/redirect", 5, 0, {200})
        self.assertIsNone(status)

    def test_private_redirect_not_fetched(self):
        status = lc.check_one(f"{self.base}/redirect-private", 5, 0, {200}, exclude_private=True)
        self.assertIsNotNone(status)
        self.assertIn("private", str(status.get("details", "")).lower())

    def test_retry_after_429(self):
        status = lc.check_one(f"{self.base}/rate", 5, 2, {200})
        self.assertIsNone(status)

    def test_429_retries_even_when_accepted(self):
        # The Retry-After backoff must run even when 429 is in the accept
        # list (the scanner's list includes it); prove the retry fired by
        # counting requests the handler served.
        self.httpd.rate_count = 0
        status = lc.check_one(f"{self.base}/rate", 5, 2, {200, 429})
        self.assertIsNone(status)
        self.assertGreaterEqual(self.httpd.rate_count, 2)

    def test_429_final_accepted(self):
        status = lc.check_one(f"{self.base}/rate-always", 5, 0, {200, 429})
        self.assertIsNone(status)

    def test_429_final_not_accepted(self):
        status = lc.check_one(f"{self.base}/rate-always", 5, 0, {200})
        self.assertIsNotNone(status)
        self.assertEqual(status.get("code"), 429)

    def test_parse_retry_after_naive_date_is_utc(self):
        self.assertEqual(lc.parse_retry_after("0"), 0.0)
        self.assertIsNone(lc.parse_retry_after(None))
        self.assertIsNone(lc.parse_retry_after("garbage"))
        # A future HTTP-date without an explicit offset must not skew by the
        # local UTC offset (naive dates are GMT per RFC 7231).
        future = email.utils.formatdate(time.time() + 3600, usegmt=False)
        wait = lc.parse_retry_after(future)
        self.assertIsNotNone(wait)
        self.assertGreaterEqual(wait, 0.0)
        self.assertLess(wait, 3700)

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

    def test_malformed_ipv6_url_reported_not_crash(self):
        total, errors, unchecked, error_map = lc.check_all(
            [("f.md", "http://[::1")],
            timeout=5,
            max_retries=0,
            max_concurrency=1,
            accept={200},
            exclude_res=[],
            exclude_private=False,
        )
        self.assertEqual(total, 1)
        self.assertEqual(errors, 1)
        self.assertEqual(unchecked, 0)
        self.assertEqual(error_map["f.md"][0]["status"]["text"], "Network error")


class EgressRefusalTests(unittest.TestCase):
    def test_origin_reset_behind_proxy_is_not_unchecked(self):
        old = os.environ.get("https_proxy")
        os.environ["https_proxy"] = "http://127.0.0.1:9"
        try:
            self.assertFalse(lc._is_egress_refusal(ConnectionResetError(54, "Connection reset by peer")))
            self.assertFalse(lc._is_egress_refusal(ConnectionAbortedError("Connection aborted")))
            self.assertFalse(lc._is_egress_refusal(BrokenPipeError("Broken pipe")))
            self.assertTrue(lc._is_egress_refusal(OSError("Tunnel connection failed: 403 Forbidden")))
        finally:
            if old is None:
                os.environ.pop("https_proxy", None)
            else:
                os.environ["https_proxy"] = old

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

    def test_fallback_parser_multi_line_array(self):
        # The common .lychee.toml formatting: one item per line.
        text = 'exclude = [\n  "localhost",\n  "example\\.com",\n]\n'
        cfg = lc._parse_toml_subset(text)
        self.assertEqual(cfg.get("exclude"), ["localhost", "example\\.com"])

    def test_fallback_parser_hash_inside_value(self):
        text = 'exclude = ["foo#bar"]\n'
        cfg = lc._parse_toml_subset(text)
        self.assertEqual(cfg.get("exclude"), ["foo#bar"])

    def test_fallback_parser_trailing_comment(self):
        text = 'exclude = ["a"] # trailing comment\n'
        cfg = lc._parse_toml_subset(text)
        self.assertEqual(cfg.get("exclude"), ["a"])

    def test_fallback_parser_decodes_basic_string_escapes(self):
        # TOML basic strings decode escapes (matching tomllib); literal
        # '...' strings do not. Undecoded, exclusion regexes silently stop
        # matching on Python < 3.11.
        text = "exclude = [\"a\\\\b\", 'c\\\\d']\n"
        cfg = lc._parse_toml_subset(text)
        self.assertEqual(cfg.get("exclude"), ["a\\b", "c\\\\d"])

    def test_fallback_parser_unicode_escape(self):
        text = 'exclude = ["caf\\u00e9.example"]\n'
        cfg = lc._parse_toml_subset(text)
        self.assertEqual(cfg.get("exclude"), ["café.example"])

    def test_fallback_parser_empty_string_entry(self):
        # An empty quoted string produced an all-empty regex capture tuple
        # that was dispatched to int("") and crashed the parser — before
        # normalize_accept's warn-and-skip could ever run.
        cfg = lc._parse_toml_subset('accept = [""]\n')
        self.assertEqual(cfg.get("accept"), [""])

    def test_fallback_parser_escaped_quote_parity(self):
        # Escaped quotes used to split tokens at the \", producing malformed
        # fragments and dropping later items. tomllib is the reference.
        import tomllib

        text = 'exclude = ["foo\\"bar", "baz"]\n'
        self.assertEqual(
            lc._parse_toml_subset(text).get("exclude"),
            tomllib.loads(text)["exclude"],
        )

    def test_fallback_parser_escaped_quote_scanners(self):
        # The comment and bracket scanners must not treat \" as closing the
        # string: a '#' or ']' after it stays inside the quoted value.
        line = 'exclude = ["foo\\" #b"]'
        self.assertEqual(lc._strip_toml_comment(line), line)  # no comment cut
        self.assertEqual(lc._bracket_depth(line), 0)
        # The ']' stays quoted, so the array opened by '[' never closes.
        self.assertEqual(lc._bracket_depth('["a\\"]"'), 1)

    def test_normalize_accept_empty_fallback_entry_does_not_crash(self):
        # End to end through the fallback: warn-and-skip, empty accept set.
        cfg = lc._parse_toml_subset('accept = [""]\n')
        self.assertEqual(lc.normalize_accept(cfg.get("accept")), set())

    def test_normalize_accept_skips_bad_entries(self):
        self.assertEqual(lc.normalize_accept(["", "200", "x"]), {200})
        self.assertEqual(lc.normalize_accept(403), {403})
        self.assertEqual(lc.normalize_accept(["204", 206]), {204, 206})

    def test_normalize_accept_ranges(self):
        # lychee's documented config example: accept = ["200..=204", "429"].
        # Collapsing the range to nothing made every 200 link report broken.
        self.assertEqual(
            lc.normalize_accept(["200..=204", "429"]),
            {200, 201, 202, 203, 204, 429},
        )
        # The documented comma-string scalar form.
        self.assertEqual(lc.normalize_accept("200, 429"), {200, 429})
        # Rust end-exclusive range.
        self.assertEqual(lc.normalize_accept(["200..204"]), {200, 201, 202, 203})
        self.assertEqual(lc.parse_accept("200..=204"), {200, 201, 202, 203, 204})
        self.assertEqual(lc.normalize_accept([""]), set())

    def test_accept_range_config_keeps_200_links_ok(self):
        with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as fh:
            fh.write('accept = ["200..=204", "429"]\n')
            path = Path(fh.name)
        try:
            cfg = lc.load_lychee_toml(path)
            self.assertEqual(
                lc.normalize_accept(cfg.get("accept")),
                {200, 201, 202, 203, 204, 429},
            )
        finally:
            path.unlink(missing_ok=True)

    def test_accept_empty_entry_does_not_crash(self):
        # int("") used to raise an uncaught ValueError from main().
        with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as fh:
            fh.write('accept = [""]\n')
            path = Path(fh.name)
        try:
            cfg = lc.load_lychee_toml(path)
            self.assertEqual(lc.normalize_accept(cfg.get("accept", [])), set())
        finally:
            path.unlink(missing_ok=True)


class CliSmokeTests(unittest.TestCase):
    def test_cli_emits_json(self):
        httpd, base = start_server()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "a.md").write_text(
                    f"[ok]({base}/ok)\n[bad]({base}/gone)\nsee http://[::1\n",
                    encoding="utf-8",
                )
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
                self.assertEqual(report["total"], 3)
                self.assertEqual(report["errors"], 2)
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
