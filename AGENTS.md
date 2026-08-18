# AGENTS.md

## Cursor Cloud specific instructions

### Platform reality: this is a macOS-only app

AIQuota is a macOS menu bar GUI application (SwiftPM executable, `platforms: [.macOS(.v13)]`).
Its source imports Apple-only frameworks — `SwiftUI` (`MenuBarExtra`), `AppKit`
(`NSApplication`, `NSPanel`, `NSHostingView`, `NSWorkspace`), `Security`, and `CommonCrypto`.
None of these exist in Swift for Linux, so the Cloud Agent Linux VM **cannot build or run the
full app**. A real build/run/test requires macOS 13+ with Xcode Command Line Tools.

- Build/run the actual app (macOS only): `./scripts/run.sh` (builds `-c release`, bundles
  `dist/AIQuota.app`, launches it) or just `swift build -c release`.
- There is **no test target** and **no configured linter** (no SwiftLint/swift-format config);
  `swift build` is the effective correctness check. Do not invent lint/test commands.

### What the Linux VM can do

A Swift toolchain (Swift 6.3.3 via `swiftly`) is installed so you can edit and syntax-check the
pure-logic code. `swift` is not on `PATH` in a fresh shell — source the env first:

```bash
. "$HOME/.local/share/swiftly/env.sh"
```

- `swift package describe` works (resolves the manifest).
- `swift build` **fails on Linux** with `error: no such module 'SwiftUI'` (and `AppKit`, etc.).
  This is expected on Linux and is **not** a code regression — do not try to "fix" it here.
- The Foundation-only provider/network files parse cleanly, e.g.:
  `swiftc -parse Sources/HTTP.swift Sources/Providers/CodexProvider.swift ...`
  (Files like `Sources/AIQuotaApp.swift`, `Sources/Models.swift`, `Sources/QuotaRingView.swift`
  and `Sources/Providers/KimiWebAuth.swift` depend on Apple frameworks and will not compile here.)

### Runtime credentials (macOS only, for reference)

The app reads existing local login state per provider: Codex `~/.codex/auth.json`, Cursor
`state.vscdb`, Grok `~/.grok/auth.json`, Kimi website `kimi-auth` cookie (or `KIMI_AUTH_TOKEN`
env var). These are irrelevant on the Linux VM since the app cannot run there.
