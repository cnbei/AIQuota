# AIQuota

[English](README.md) | [简体中文](README.zh-CN.md)

macOS menu bar app that shows remaining AI coding quota as a colored ring.

**Providers**

| Provider | Source | What the ring shows |
| --- | --- | --- |
| **Codex** (default) | `~/.codex/auth.json` → ChatGPT usage API | Remaining quota % |
| **Cursor** | Local Cursor login (`state.vscdb`) → Dashboard usage API | Remaining **Cursor Models** % (aligned with [Spending](https://cursor.com/dashboard/spending)) |
| **Kimi** | Website `kimi-auth` cookie → membership stats | Remaining **membership total usage** % |
| **Grok** | `~/.grok/auth.json` → Grok Build billing API | Remaining **Grok Build** credits % |

Ring colors: green = plenty left, red = almost used up. The number in the center is **remaining percent**.

## Requirements

- macOS 13+
- Xcode Command Line Tools / Swift 5.9+
- **Codex / Cursor**: already signed in on this Mac
- **Kimi**: website session cookie `kimi-auth` (not the Code CLI OAuth token)
- **Grok**: run `grok login` so `~/.grok/auth.json` has a valid OIDC session

Optional (for one-click Kimi import):

```bash
pip3 install --user browser-cookie3
```

## Run

```bash
./scripts/run.sh
```

Builds a release binary and launches `dist/AIQuota.app` (menu-bar only, no Dock icon via `LSUIElement`).

Build only:

```bash
swift build -c release
```

## Usage

1. Click the menu bar ring to open the panel.
2. Use the segmented control to switch **Codex / Cursor / Kimi**.
3. **Refresh** pulls the latest usage (auto-refresh about every 3 minutes).
4. **Open dashboard** jumps to the provider’s usage page.
5. **Pin** (top-right) floats a sticky panel so it stays open while you follow browser steps (useful for Kimi auth).
6. On **Cursor**, switch the menu-bar ring between **Cursor Models** and **Other Models**.
7. On **Kimi**, switch the menu-bar ring between **总体** (membership total) and **Kimi Code** (tightest of Code 5h / 7d).

The panel also lists **reset schedule** windows when the API provides them (e.g. 5h / 7d / 30d). Preferences persist across launches.

### Kimi auth

Kimi Code CLI tokens cannot call the membership stats API (401). You need the website cookie:

1. Sign in at [My quota](https://www.kimi.com/membership/subscription?tab=quota).
2. In AIQuota, switch to **Kimi** → **Import web login** (reads Chrome / Edge / Brave / Chromium / Safari cookies via `browser-cookie3`).
3. If that fails: DevTools → Application → Cookies → copy `kimi-auth` → **Paste kimi-auth**.
4. Or set env var `KIMI_AUTH_TOKEN`.

The token is cached under `~/Library/Application Support/AIQuota/`.

Kimi auth UI (tutorial / paste / import) appears **only** on the Kimi tab.

## Privacy

Credentials stay on your machine. The app only uses existing local login state (or a cookie you paste) to call each provider’s usage endpoint. Nothing is uploaded to a third-party server.

Usage APIs are unofficial / internal and may break when vendors change them.

## License

Use and modify freely for personal use.
