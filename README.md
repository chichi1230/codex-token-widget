# Codex Token Widget

Small macOS floating widget for Codex rate-limit visibility.

It reads the latest local Codex session `payload.rate_limits` event from:

- `~/.codex/sessions/**/*.jsonl`

The widget displays the same two windows shown in Codex: the 5-hour limit and the weekly limit, with remaining percentage and reset time/date.

## Build and Start

```zsh
cd ~/codex-token-widget
chmod +x install.sh uninstall.sh
./install.sh
```

## Stop

```zsh
cd ~/codex-token-widget
./uninstall.sh
```

## Configuration

Edit `config.json`, then rerun `./install.sh`.

- `sessionsRootPath`: Codex session JSONL directory.
- `refreshSeconds`: refresh interval.
- `alwaysOnTop`: keep the widget over other windows.
- `windowX` and `windowY`: fixed position. Leave `null` to use the top-center island position.

## Repair Loop

After changing Swift or config:

```zsh
cd ~/codex-token-widget
swiftc CodexTokenWidget.swift -o build/CodexTokenWidget.app/Contents/MacOS/CodexTokenWidget -framework AppKit
build/CodexTokenWidget.app/Contents/MacOS/CodexTokenWidget --print
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.codex-token-widget.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.codex-token-widget.plist 2>/dev/null || true
launchctl kickstart gui/$(id -u)/local.codex-token-widget 2>/dev/null || launchctl load ~/Library/LaunchAgents/local.codex-token-widget.plist
```

Check errors:

```zsh
tail -50 ~/codex-token-widget/widget.err.log
```
