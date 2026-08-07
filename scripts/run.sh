#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN="$ROOT/.build/release/AIQuota"

# Bundle as a minimal .app so Dock/menu-bar behavior is correct (LSUIElement).
APP="$ROOT/dist/AIQuota.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AIQuota"
cp "$ROOT/scripts/import_kimi_auth.py" "$APP/Contents/Resources/import_kimi_auth.py"
chmod +x "$APP/Contents/Resources/import_kimi_auth.py"
# Ensure helper can find repo scripts during development.
export AIQUOTA_HOME="$ROOT"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AIQuota</string>
  <key>CFBundleIdentifier</key>
  <string>local.aiquota</string>
  <key>CFBundleName</key>
  <string>AIQuota</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Clear quarantine if present.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Restart previous instance quietly.
pkill -x AIQuota 2>/dev/null || true
open "$APP"
echo "Started $APP"
