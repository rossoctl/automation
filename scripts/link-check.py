#!/usr/bin/env python3
"""Stdlib link checker that emits lychee-compatible JSON.

Used by link-health-scanner.sh when LINK_CHECKER=python. Accepts the same
scanner argv previously passed to lychee so the call site stays one branch.

Python 3.8+; stdlib only (urllib, concurrent.futures, html.parser, re,
ipaddress, tomllib when available).
"""
from __future__ import annotations

import argparse
import concurrent.futures
import email.utils
import html.parser
import ipaddress
import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

USER_AGENT = "RepoManLinkChecker/1.0 (+https://github.com/rossoctl/repoman)"
MAX_REDIRECTS = 10
PER_HOST_CAP = 2
RETRY_AFTER_CAP_SECS = 30
SCAN_EXTENSIONS = {".md", ".markdown", ".html", ".htm"}

# --- TOML subset (exclude / exclude_path / accept) ---------------------------------

def _parse_toml_subset(text: str) -> Dict[str, object]:
    """Minimal parser for .lychee.toml keys we honor, when tomllib is absent."""
    result: Dict[str, object] = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, _, rest = line.partition("=")
        key = key.strip()
        rest = rest.strip()
        if key not in ("exclude", "exclude_path", "accept"):
            continue
        if rest.startswith("["):
            inner = rest[1 : rest.rfind("]")]
            items: List[object] = []
            for part in re.findall(r'"([^"]*)"|\'([^\']*)\'|(-?\d+)', inner):
                if part[0] != "":
                    items.append(part[0])
                elif part[1] != "":
                    items.append(part[1])
                else:
                    items.append(int(part[2]))
            result[key] = items
        elif rest.startswith('"') or rest.startswith("'"):
            result[key] = rest[1:-1]
        else:
            try:
                result[key] = int(rest)
            except ValueError:
                result[key] = rest
    return result


def load_lychee_toml(path: Path) -> Dict[str, object]:
    text = path.read_text(encoding="utf-8", errors="replace")
    try:
        import tomllib  # type: ignore[attr-defined]

        data = tomllib.loads(text)
    except ImportError:
        data = _parse_toml_subset(text)
    except Exception as exc:  # noqa: BLE001 — fall back to subset parser
        print(f"WARN: tomllib failed on {path}: {exc}; using subset parser", file=sys.stderr)
        data = _parse_toml_subset(text)

    known = {"exclude", "exclude_path", "accept"}
    for key in list(data.keys()):
        if key not in known:
            print(f"WARN: ignoring unsupported .lychee.toml key: {key}", file=sys.stderr)
    return {k: data[k] for k in known if k in data}


# --- Markdown / HTML extraction ---------------------------------------------------

FENCE_RE = re.compile(r"^(`{3,}|~{3,})")
INLINE_CODE_RE = re.compile(r"`+[^`]*`+")
MD_INLINE_RE = re.compile(
    r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"
)
MD_REF_DEF_RE = re.compile(r"^\s*\[([^\]]+)\]:\s*(\S+)", re.MULTILINE)
MD_REF_USE_RE = re.compile(r"\[([^\]]*)\]\[([^\]]*)\]")
MD_AUTOLINK_RE = re.compile(r"<(https?://[^>\s]+)>", re.IGNORECASE)
BARE_URL_RE = re.compile(r"(?<![(\[<\"'])(https?://[^\s<>\)\]\"']+)", re.IGNORECASE)


class _HrefSrcParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.urls: List[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag: str, attrs) -> None:  # noqa: ANN001
        tag_l = tag.lower()
        if tag_l in ("code", "pre"):
            self._skip_depth += 1
            return
        if self._skip_depth:
            return
        attr_map = {k.lower(): v for k, v in attrs if v}
        for key in ("href", "src"):
            if key in attr_map:
                self.urls.append(attr_map[key])

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in ("code", "pre") and self._skip_depth:
            self._skip_depth -= 1


def _strip_code_regions(text: str) -> str:
    """Remove fenced, indented, and inline code so their URLs are not extracted."""
    lines = text.splitlines(keepends=True)
    out: List[str] = []
    in_fence = False
    fence_marker = ""
    for line in lines:
        if in_fence:
            if line.lstrip().startswith(fence_marker):
                in_fence = False
                fence_marker = ""
            out.append("\n" if line.endswith("\n") else "")
            continue
        m = FENCE_RE.match(line.lstrip())
        if m:
            in_fence = True
            fence_marker = m.group(1)[0] * len(m.group(1))
            out.append("\n" if line.endswith("\n") else "")
            continue
        # Indented code block: line starts with 4 spaces or a tab (and is not blank).
        if re.match(r"^(?: {4}|\t)", line) and line.strip():
            out.append("\n" if line.endswith("\n") else "")
            continue
        # Blank out inline code spans.
        cleaned = INLINE_CODE_RE.sub(lambda m: " " * len(m.group(0)), line)
        out.append(cleaned)
    return "".join(out)


def _drop_unused_ref_defs(text: str) -> str:
    """Remove `[label]: url` lines whose label is never referenced.

    Lychee does not extract those unused definitions, and a later bare-URL
    pass would otherwise treat the definition target as a link.
    """
    used = set()
    for text_label, ref_label in MD_REF_USE_RE.findall(text):
        label = (ref_label or text_label).strip().lower()
        if label:
            used.add(label)

    def repl(match: re.Match) -> str:
        if match.group(1).strip().lower() in used:
            return match.group(0)
        return ""

    return MD_REF_DEF_RE.sub(repl, text)


def extract_urls_from_text(text: str) -> List[str]:
    cleaned = _drop_unused_ref_defs(_strip_code_regions(text))
    found: List[str] = []
    found.extend(MD_INLINE_RE.findall(cleaned))
    found.extend(url for _label, url in MD_REF_DEF_RE.findall(cleaned))
    found.extend(MD_AUTOLINK_RE.findall(cleaned))
    found.extend(BARE_URL_RE.findall(cleaned))

    parser = _HrefSrcParser()
    try:
        parser.feed(cleaned)
        parser.close()
    except Exception:  # noqa: BLE001 — malformed HTML should not abort the scan
        pass
    found.extend(parser.urls)

    # Normalize: drop angle-bracket leftovers / trailing punctuation common in prose.
    normalized: List[str] = []
    for url in found:
        u = url.strip().rstrip(".,;:!?)\"'")
        if u:
            normalized.append(u)
    return normalized


def path_matches_exclude(rel: str, patterns: List[str]) -> bool:
    for pat in patterns:
        try:
            if re.search(pat, rel):
                return True
        except re.error:
            if pat in rel:
                return True
    return False


def collect_links(
    root: Path,
    schemes: Set[str],
    exclude_paths: List[str],
) -> List[Tuple[str, str]]:
    """Return deduped (relative_filepath, url) pairs under root."""
    pairs: List[Tuple[str, str]] = []
    seen: Set[Tuple[str, str]] = set()
    root = root.resolve()

    for dirpath, dirnames, filenames in os.walk(root):
        # Prune .git and exclude-path matches early.
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""
        pruned = []
        for d in list(dirnames):
            if d == ".git":
                continue
            candidate = f"{rel_dir}/{d}" if rel_dir else d
            if path_matches_exclude(candidate, exclude_paths) or path_matches_exclude(
                d, exclude_paths
            ):
                continue
            pruned.append(d)
        dirnames[:] = pruned

        for name in filenames:
            ext = Path(name).suffix.lower()
            if ext not in SCAN_EXTENSIONS:
                continue
            abs_path = Path(dirpath) / name
            rel = str(abs_path.relative_to(root)).replace(os.sep, "/")
            if path_matches_exclude(rel, exclude_paths):
                continue
            try:
                text = abs_path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                print(f"WARN: cannot read {rel}: {exc}", file=sys.stderr)
                continue
            for url in extract_urls_from_text(text):
                parsed = urllib.parse.urlparse(url)
                if parsed.scheme.lower() not in schemes:
                    continue
                key = (rel, url)
                if key in seen:
                    continue
                seen.add(key)
                pairs.append(key)
    return pairs


# --- Checking ---------------------------------------------------------------------

def proxy_env_set() -> bool:
    for key in os.environ:
        if key.lower() in ("http_proxy", "https_proxy", "all_proxy") and os.environ[key]:
            return True
    return False


def is_private_host(host: str) -> Optional[bool]:
    """Return True if host is private, False if public, None on DNS failure."""
    if not host:
        return False
    # Strip brackets from IPv6 literals.
    h = host.strip("[]")
    try:
        ip = ipaddress.ip_address(h)
        return bool(
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
            or (isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped and (
                ip.ipv4_mapped.is_private
                or ip.ipv4_mapped.is_loopback
                or ip.ipv4_mapped.is_link_local
            ))
        )
    except ValueError:
        pass
    try:
        infos = socket.getaddrinfo(h, None)
    except socket.gaierror:
        return None
    if not infos:
        return None
    all_private = True
    for info in infos:
        addr = info[4][0]
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            all_private = False
            continue
        if not (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
        ):
            all_private = False
    return all_private


def url_excluded(url: str, exclude_res: List[re.Pattern]) -> bool:
    for cre in exclude_res:
        if cre.search(url):
            return True
    return False


def parse_retry_after(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    value = value.strip()
    if re.fullmatch(r"\d+", value):
        return float(value)
    try:
        dt = email.utils.parsedate_to_datetime(value)
        return max(0.0, dt.timestamp() - time.time())
    except (TypeError, ValueError, OverflowError):
        return None


def _is_egress_refusal(exc: BaseException) -> bool:
    """True when a proxy gateway refused CONNECT (only meaningful with a proxy)."""
    if not proxy_env_set():
        return False
    msg = str(exc)
    lower = msg.lower()
    if "tunnel connection failed" in lower and "403" in msg:
        return True
    # A reset after the CONNECT tunnel is up is the origin, not an egress refusal.
    if "tunnel connection failed" in lower and any(
        tok in lower for tok in ("reset", "closed", "refused", "abort")
    ):
        return True
    # urllib wraps proxy CONNECT failures as URLError/OSError with the tunnel text.
    if isinstance(exc, urllib.error.URLError):
        reason = getattr(exc, "reason", None)
        if reason is not None and reason is not exc:
            return _is_egress_refusal(reason if isinstance(reason, BaseException) else Exception(str(reason)))
    return False


def _classify_exception(exc: BaseException) -> Dict[str, object]:
    if _is_egress_refusal(exc):
        return {"text": "unchecked", "details": str(exc)}
    if isinstance(exc, socket.timeout) or isinstance(exc, TimeoutError):
        return {"text": "Timeout", "details": str(exc)}
    if isinstance(exc, socket.gaierror):
        return {"text": "Failed to resolve host", "details": str(exc)}
    msg = str(exc).lower()
    if "timed out" in msg or "timeout" in msg:
        return {"text": "Timeout", "details": str(exc)}
    if "name or service not known" in msg or "nodename nor servname" in msg or "getaddrinfo" in msg:
        return {"text": "Failed to resolve host", "details": str(exc)}
    if any(tok in msg for tok in ("refused", "reset", "closed", "unreachable", "connect")):
        # Prefer unchecked over unreachable when proxy refusal signatures match.
        return {"text": "Connection refused", "details": str(exc)}
    return {"text": "Network error", "details": str(exc)}


def _open(req: urllib.request.Request, timeout: float, exclude_private: bool = False):
    ctx = ssl.create_default_context()

    class _LimitedRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
            if exclude_private:
                host = urllib.parse.urlparse(newurl).hostname or ""
                if host and is_private_host(host) is True:
                    raise urllib.error.URLError(f"redirect to private host {host}")
            count = getattr(req, "_redirect_count", 0) + 1
            if count > MAX_REDIRECTS:
                raise urllib.error.HTTPError(
                    req.full_url, code, f"too many redirects (>{MAX_REDIRECTS})", headers, fp
                )
            new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
            if new_req is not None:
                new_req._redirect_count = count  # type: ignore[attr-defined]
            return new_req

    opener = urllib.request.build_opener(
        _LimitedRedirect,
        urllib.request.HTTPSHandler(context=ctx),
    )
    return opener.open(req, timeout=timeout)


def check_one(
    url: str,
    timeout: float,
    max_retries: int,
    accept: Set[int],
    exclude_private: bool = False,
) -> Optional[Dict[str, object]]:
    """Return a status dict on failure/unchecked, or None on success."""
    attempts = max_retries + 1
    last_status: Optional[Dict[str, object]] = None

    for attempt in range(attempts):
        try:
            status = _check_once(url, timeout, accept, exclude_private)
            if status is None:
                return None
            # Retry on 429.
            if status.get("code") == 429 and attempt < attempts - 1:
                wait = parse_retry_after(status.pop("_retry_after", None))
                if wait is None:
                    wait = 1.0
                if wait > RETRY_AFTER_CAP_SECS:
                    # Cap exceeded: stop retrying; 429 is in the default accept
                    # list so treat as success when accept includes it.
                    if 429 in accept:
                        return None
                    return {"code": 429, "text": "429"}
                time.sleep(wait)
                last_status = status
                continue
            # Egress refusals are never retried — they are not "broken".
            if status.get("text") == "unchecked":
                return status
            # Retry on transient network errors represented as text statuses.
            if "code" not in status and status.get("text") in (
                "Timeout",
                "Connection refused",
                "Network error",
            ):
                if attempt < attempts - 1:
                    last_status = status
                    time.sleep(0.5 * (attempt + 1))
                    continue
            return status
        except Exception as exc:  # noqa: BLE001
            classified = _classify_exception(exc)
            if classified.get("text") == "unchecked":
                return classified
            last_status = classified
            if attempt < attempts - 1 and classified.get("text") in (
                "Timeout",
                "Connection refused",
                "Network error",
            ):
                time.sleep(0.5 * (attempt + 1))
                continue
            return classified
    return last_status


def _check_once(
    url: str, timeout: float, accept: Set[int], exclude_private: bool = False
) -> Optional[Dict[str, object]]:
    headers = {"User-Agent": USER_AGENT}
    # HEAD first.
    try:
        req = urllib.request.Request(url, method="HEAD", headers=headers)
        with _open(req, timeout, exclude_private) as resp:
            code = getattr(resp, "status", None) or resp.getcode()
            if code in accept:
                return None
            if code in (405, 403, 501):
                return _get_fallback(url, timeout, accept, headers, exclude_private)
            if code == 429:
                return {
                    "code": 429,
                    "text": "429",
                    "_retry_after": resp.headers.get("Retry-After"),
                }
            return {"code": int(code), "text": str(code)}
    except urllib.error.HTTPError as exc:
        code = exc.code
        if code in accept:
            return None
        if code in (405, 403, 501):
            return _get_fallback(url, timeout, accept, headers, exclude_private)
        if code == 429:
            return {
                "code": 429,
                "text": "429",
                "_retry_after": exc.headers.get("Retry-After") if exc.headers else None,
            }
        return {"code": int(code), "text": str(code)}
    except Exception as exc:  # noqa: BLE001
        return _classify_exception(exc)


def _get_fallback(
    url: str,
    timeout: float,
    accept: Set[int],
    headers: Dict[str, str],
    exclude_private: bool = False,
) -> Optional[Dict[str, object]]:
    try:
        req = urllib.request.Request(url, method="GET", headers=headers)
        with _open(req, timeout, exclude_private) as resp:
            code = getattr(resp, "status", None) or resp.getcode()
            # Drain a little so some servers don't reset.
            try:
                resp.read(1024)
            except Exception:  # noqa: BLE001
                pass
            if code in accept:
                return None
            if code == 429:
                return {
                    "code": 429,
                    "text": "429",
                    "_retry_after": resp.headers.get("Retry-After"),
                }
            return {"code": int(code), "text": str(code)}
    except urllib.error.HTTPError as exc:
        code = exc.code
        if code in accept:
            return None
        if code == 429:
            return {
                "code": 429,
                "text": "429",
                "_retry_after": exc.headers.get("Retry-After") if exc.headers else None,
            }
        return {"code": int(code), "text": str(code)}
    except Exception as exc:  # noqa: BLE001
        return _classify_exception(exc)


class HostSemaphorePool:
    """Limit concurrent in-flight checks per hostname."""

    def __init__(self, per_host: int) -> None:
        import threading

        self._per_host = per_host
        self._lock = threading.Lock()
        self._sems: Dict[str, "threading.Semaphore"] = {}

    def acquire(self, host: str) -> None:
        import threading

        with self._lock:
            sem = self._sems.get(host)
            if sem is None:
                sem = threading.Semaphore(self._per_host)
                self._sems[host] = sem
        sem.acquire()

    def release(self, host: str) -> None:
        with self._lock:
            sem = self._sems.get(host)
        if sem is not None:
            sem.release()


def check_all(
    pairs: List[Tuple[str, str]],
    timeout: float,
    max_retries: int,
    max_concurrency: int,
    accept: Set[int],
    exclude_res: List[re.Pattern],
    exclude_private: bool,
) -> Tuple[int, int, int, Dict[str, List[Dict[str, object]]]]:
    """Return (total, errors, unchecked, error_map)."""
    # Filter excludes / private before counting toward total (lychee excludes
    # are not part of total checked in our report; we count only checked URLs).
    to_check: List[Tuple[str, str]] = []
    for filepath, url in pairs:
        if url_excluded(url, exclude_res):
            continue
        host = urllib.parse.urlparse(url).hostname or ""
        if exclude_private:
            priv = is_private_host(host)
            if priv is True:
                continue
            # DNS failure during private check: still attempt the URL; the
            # checker will report dns if it cannot resolve.
        to_check.append((filepath, url))

    total = len(to_check)
    error_map: Dict[str, List[Dict[str, object]]] = defaultdict(list)
    errors = 0
    unchecked = 0
    host_pool = HostSemaphorePool(PER_HOST_CAP)

    def worker(item: Tuple[str, str]) -> Tuple[str, str, Optional[Dict[str, object]]]:
        filepath, url = item
        host = urllib.parse.urlparse(url).hostname or ""
        host_pool.acquire(host)
        try:
            status = check_one(url, timeout, max_retries, accept, exclude_private)
        finally:
            host_pool.release(host)
        return filepath, url, status

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, max_concurrency)) as pool:
        futures = [pool.submit(worker, item) for item in to_check]
        for fut in concurrent.futures.as_completed(futures):
            filepath, url, status = fut.result()
            if status is None:
                continue
            # Strip internal retry metadata.
            status = {k: v for k, v in status.items() if not k.startswith("_")}
            entry = {"url": url, "status": status}
            error_map[filepath].append(entry)
            if status.get("text") == "unchecked":
                unchecked += 1
            else:
                errors += 1

    return total, errors, unchecked, dict(error_map)


# --- CLI --------------------------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Stdlib lychee-compatible link checker")
    p.add_argument("root", help="Directory to scan")
    p.add_argument("--format", dest="fmt", default="json", choices=["json"])
    p.add_argument("--scheme", action="append", default=[])
    p.add_argument("--exclude", action="append", default=[])
    p.add_argument("--exclude-path", action="append", default=[])
    p.add_argument("--exclude-all-private", action="store_true")
    p.add_argument("--accept", default="")
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--max-retries", type=int, default=2)
    p.add_argument("--max-concurrency", type=int, default=8)
    p.add_argument("--config", default=None, help="Path to .lychee.toml")
    return p


def parse_accept(raw: str) -> Set[int]:
    codes: Set[int] = set()
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            codes.add(int(part))
        except ValueError:
            print(f"WARN: ignoring non-integer accept code: {part}", file=sys.stderr)
    return codes


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    schemes = {s.lower() for s in (args.scheme or ["http", "https"])}
    excludes = list(args.exclude)
    exclude_paths = list(args.exclude_path)
    accept = parse_accept(args.accept) if args.accept else {200, 204, 206}
    exclude_private = bool(args.exclude_all_private)

    if args.config:
        cfg_path = Path(args.config)
        if cfg_path.is_file():
            cfg = load_lychee_toml(cfg_path)
            if "exclude" in cfg:
                val = cfg["exclude"]
                if isinstance(val, list):
                    excludes.extend(str(x) for x in val)
                else:
                    excludes.append(str(val))
            if "exclude_path" in cfg:
                val = cfg["exclude_path"]
                if isinstance(val, list):
                    exclude_paths.extend(str(x) for x in val)
                else:
                    exclude_paths.append(str(val))
            if "accept" in cfg:
                val = cfg["accept"]
                if isinstance(val, list):
                    accept = {int(x) for x in val}
                else:
                    accept = parse_accept(str(val))
        else:
            print(f"WARN: config not found: {cfg_path}", file=sys.stderr)

    exclude_res: List[re.Pattern] = []
    for pat in excludes:
        try:
            exclude_res.append(re.compile(pat))
        except re.error as exc:
            print(f"WARN: bad exclude regex {pat!r}: {exc}", file=sys.stderr)

    root = Path(args.root)
    if not root.is_dir():
        print(f"ERROR: not a directory: {root}", file=sys.stderr)
        # Still emit empty JSON so the scanner does not treat this as "no output".
        json.dump({"total": 0, "errors": 0, "unchecked": 0, "error_map": {}}, sys.stdout)
        print()
        return 0

    pairs = collect_links(root, schemes, exclude_paths)
    total, errors, unchecked, error_map = check_all(
        pairs,
        timeout=args.timeout,
        max_retries=args.max_retries,
        max_concurrency=args.max_concurrency,
        accept=accept,
        exclude_res=exclude_res,
        exclude_private=exclude_private,
    )

    report = {
        "total": total,
        "errors": errors,
        "unchecked": unchecked,
        "error_map": error_map,
    }
    json.dump(report, sys.stdout)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
