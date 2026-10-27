#!/usr/bin/env bash
# Install optionai → ~/.local/bin + orb assets → ~/.local/share/optionai + login LaunchAgent
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/optionai"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
LABEL="com.cdiak.optionai"
PLIST="${LAUNCH_AGENTS}/${LABEL}.plist"
DEST="${BIN_DIR}/optionai"

mkdir -p "$BIN_DIR" "$SHARE_DIR" "$LAUNCH_AGENTS"

./build.sh "$DEST"

# Orb assets (vendored thinking-orbs engine + driver page)
rm -rf "${SHARE_DIR}/orb"
cp -R orb "${SHARE_DIR}/orb"

# Stop current agent
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true

# Resolve claude CLI: env → PATH → common locations
if [[ -z "${CLAUDE_CLI:-}" ]]; then
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_CLI="$(command -v claude)"
  elif [[ -x "${HOME}/.claude/local/claude" ]]; then
    CLAUDE_CLI="${HOME}/.claude/local/claude"
  else
    CLAUDE_CLI="/opt/homebrew/bin/claude"
  fi
fi
OPTIONAI_MODEL="${OPTIONAI_MODEL:-}"
OPTIONAI_TIMEOUT="${OPTIONAI_TIMEOUT:-180}"

if [[ ! -x "$CLAUDE_CLI" ]]; then
  echo "warning: claude CLI not found at $CLAUDE_CLI. Set CLAUDE_CLI and re-run." >&2
fi

# Escape XML special chars in paths for plist
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

CLI_XML="$(xml_escape "$CLAUDE_CLI")"
MODEL_XML="$(xml_escape "$OPTIONAI_MODEL")"
TIMEOUT_XML="$(xml_escape "$OPTIONAI_TIMEOUT")"
ORB_XML="$(xml_escape "${SHARE_DIR}/orb")"
DEST_XML="$(xml_escape "$DEST")"
HOME_XML="$(xml_escape "$HOME")"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${DEST_XML}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLAUDE_CLI</key>
    <string>${CLI_XML}</string>
    <key>OPTIONAI_MODEL</key>
    <string>${MODEL_XML}</string>
    <key>OPTIONAI_TIMEOUT</key>
    <string>${TIMEOUT_XML}</string>
    <key>OPTIONAI_ORB_DIR</key>
    <string>${ORB_XML}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME_XML}/Library/Logs/optionai.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME_XML}/Library/Logs/optionai.log</string>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
  || launchctl load "$PLIST"

echo
echo "Installed optionai"
echo "  binary:  $DEST"
echo "  orb:     ${SHARE_DIR}/orb"
echo "  agent:   $PLIST"
echo "  log:     $HOME/Library/Logs/optionai.log"
echo "  claude:  $CLAUDE_CLI"
echo "  model:   ${OPTIONAI_MODEL:-(cli default)}"
echo
echo "Hotkeys: Option+A+I  — Claude (hold Option, press A and I together)"
echo "         Option+L+M  — local Qwen3.5 9B Q4_K_M through Ollama"
echo "         Press either chord while running to cancel."
echo "Local model setup: see LOCAL_MODEL.md (Ollama must be running)."
echo
echo "Context rule:"
echo "  selection → the selection is the context"
echo "  no selection → the whole textbox is the context, split at the cursor"
echo "  web canvas apps (Google Docs) → highlight first; optionai copies it invisibly and restores your clipboard"
echo
echo "Permissions (first run):"
echo "  System Settings → Privacy & Security → Accessibility → optionai"
echo "  If missing from the list, run once: $DEST"
echo "  Both hotkeys activate automatically once granted (menu bar: ◌ → AI, no restart)"
echo
echo "Menu bar: \"AI\" idle · \"◍\" thinking (plus a floating orb near the caret)"
echo "Uninstall: ./uninstall.sh"
