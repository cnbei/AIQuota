#!/usr/bin/env python3
"""Import a fresh kimi-auth JWT and print it to stdout.

Prefers the official Kimi Desktop cookie store, then local browsers.
Expired JWTs are skipped so a stale Edge/Chrome cookie cannot hide a
valid Kimi Desktop session.
"""

from __future__ import annotations

import base64
import json
import re
import sqlite3
import sys
import time
from pathlib import Path


def jwt_fresh(token: str, leeway: int = 300) -> bool:
    parts = token.split(".")
    if len(parts) != 3:
        return False
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        data = json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, json.JSONDecodeError):
        return False
    exp = data.get("exp")
    if not isinstance(exp, (int, float)):
        return False
    return exp - time.time() > leeway


def jwt_is_access(token: str) -> bool:
    parts = token.split(".")
    if len(parts) != 3:
        return False
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        data = json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, json.JSONDecodeError):
        return False
    typ = str(data.get("typ") or "").lower()
    return typ != "refresh"


def from_kimi_desktop() -> str | None:
    if token := from_kimi_desktop_daimon():
        return token
    if token := from_kimi_desktop_cookies():
        return token
    return from_kimi_desktop_local_storage()


def from_kimi_desktop_daimon() -> str | None:
    path = (
        Path.home()
        / "Library/Application Support/kimi-desktop/daimon-share/daimon/config.json"
    )
    try:
        payload = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    web = ((payload.get("credentials") or {}).get("kimiWeb") or {})
    access = str(web.get("accessToken") or web.get("access_token") or "").strip()
    if access and jwt_fresh(access) and jwt_is_access(access):
        return access
    return None


def from_kimi_desktop_cookies() -> str | None:
    db = Path.home() / "Library/Application Support/kimi-desktop/Cookies"
    if not db.is_file():
        return None
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    except sqlite3.Error:
        return None
    try:
        rows = con.execute(
            """
            SELECT value FROM cookies
            WHERE name = 'kimi-auth'
              AND (host_key = '.kimi.com' OR host_key = 'kimi.com'
                   OR host_key LIKE '%kimi.com')
            ORDER BY last_access_utc DESC
            LIMIT 5
            """
        ).fetchall()
    except sqlite3.Error:
        return None
    finally:
        con.close()
    for (value,) in rows:
        token = (value or "").strip()
        if jwt_fresh(token) and jwt_is_access(token):
            return token
    return None


def from_kimi_desktop_local_storage() -> str | None:
    roots = [
        Path.home() / "Library/Application Support/kimi-desktop/Local Storage/leveldb",
        Path.home() / "Library/Application Support/kimi-desktop/Session Storage",
    ]
    jwt_re = re.compile(rb"eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}")
    best: str | None = None
    best_exp = 0.0
    for root in roots:
        if not root.is_dir():
            continue
        for path in root.iterdir():
            if path.suffix not in {".log", ".ldb"}:
                continue
            try:
                blob = path.read_bytes()
            except OSError:
                continue
            for raw in jwt_re.findall(blob):
                token = raw.decode("ascii", "ignore")
                if not (jwt_fresh(token) and jwt_is_access(token)):
                    continue
                parts = token.split(".")
                payload = parts[1] + "=" * (-len(parts[1]) % 4)
                try:
                    exp = json.loads(base64.urlsafe_b64decode(payload)).get("exp") or 0
                except (ValueError, json.JSONDecodeError):
                    continue
                if float(exp) > best_exp:
                    best_exp = float(exp)
                    best = token
    return best


def from_browsers() -> str | None:
    try:
        import browser_cookie3
    except ImportError:
        print(
            "MISSING_DEP: pip3 install --user browser-cookie3",
            file=sys.stderr,
        )
        return None

    loaders = []
    for name in ("edge", "chrome", "chromium", "brave", "safari"):
        loader = getattr(browser_cookie3, name, None)
        if loader is not None:
            loaders.append((name, loader))

    for name, loader in loaders:
        try:
            jar = loader(domain_name="kimi.com")
        except Exception as exc:  # noqa: BLE001 — best-effort per browser
            print(f"skip {name}: {type(exc).__name__}", file=sys.stderr)
            continue
        for cookie in jar:
            if cookie.name != "kimi-auth":
                continue
            value = (cookie.value or "").strip()
            if jwt_fresh(value):
                return value
    return None


def main() -> int:
    for getter in (from_kimi_desktop, from_browsers):
        token = getter()
        if token:
            sys.stdout.write(token)
            return 0
    print("NO_TOKEN", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
