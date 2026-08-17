#!/usr/bin/env bash
set -euo pipefail

LABEL="com.cdiak.optionai"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true

rm -f "$PLIST"
rm -f "${HOME}/.local/bin/optionai"
rm -rf "${HOME}/.local/share/optionai"

echo "Uninstalled optionai (log left at ~/Library/Logs/optionai.log)"
