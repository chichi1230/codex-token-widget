#!/bin/zsh
set -euo pipefail

ROOT="$HOME/codex-token-widget"
APP="$ROOT/build/CodexTokenWidget.app"
BIN="$APP/Contents/MacOS/CodexTokenWidget"
PLIST="$HOME/Library/LaunchAgents/local.codex-token-widget.plist"
DOMAIN="gui/$(id -u)"
LABEL="local.codex-token-widget"

mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
swiftc "$ROOT/CodexTokenWidget.swift" -o "$BIN" -framework AppKit
chmod +x "$BIN"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.codex-token-widget</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$ROOT/widget.log</string>
  <key>StandardErrorPath</key>
  <string>$ROOT/widget.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || true
launchctl kickstart "$DOMAIN/$LABEL" 2>/dev/null || launchctl load "$PLIST"
echo "Installed: $APP"
