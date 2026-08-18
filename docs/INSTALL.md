# Install AIQuota

## Recommended Path

1. Download `AIQuota-<version>.dmg` from GitHub Releases.
2. Open the DMG.
3. Drag `AIQuota.app` into Applications.
4. Launch AIQuota.

AIQuota lives in the macOS menu bar. Click the menu bar item to open the popover, or choose "Open Dashboard" from the popover.

## First Launch

AIQuota creates local app data here:

```text
~/Library/Application Support/TokenStep
```

It stores:

- `data/usage.json`: generated token usage summary
- `config/settings.json`: daily goal and refresh settings
- `logs/`: login item logs

## Updates

AIQuota checks GitHub Releases for new versions by default. When a new signed release is available, the menu bar popover and Settings window show an update prompt. AIQuota downloads the DMG to Downloads and opens it; macOS verifies the app when you install it.

## Login Item

AIQuota enables login launch by default on first run so usage tracking is less likely to miss a day. You can turn this off in Settings.

## Supported Clients

AIQuota currently supports:

- Codex
- Claude Code

If neither client has local usage metadata, AIQuota will open normally and show an empty state until data appears.

## Uninstall

1. Quit AIQuota from the menu bar popover.
2. Delete `AIQuota.app` from Applications.
3. Optional: delete local data:

```bash
rm -rf "$HOME/Library/Application Support/TokenStep"
rm -f "$HOME/Library/LaunchAgents/com.huangshu.TokenStep.login.plist"
```
