#!/bin/zsh
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/local.codex-token-widget.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
pkill -f "CodexTokenWidget" 2>/dev/null || true
