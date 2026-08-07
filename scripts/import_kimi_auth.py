#!/usr/bin/env python3
"""Import kimi-auth from local browsers and print the JWT to stdout.

Used by AIQuota for membership GetSubscriptionStats auth.
Requires: pip3 install --user browser-cookie3
"""

from __future__ import annotations

import sys


def main() -> int:
    try:
        import browser_cookie3
    except ImportError:
        print(
            "MISSING_DEP: pip3 install --user browser-cookie3",
            file=sys.stderr,
        )
        return 2

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
            if value.count(".") == 2:
                sys.stdout.write(value)
                return 0

    print("NO_TOKEN", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
