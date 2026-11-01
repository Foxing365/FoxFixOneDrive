#!/bin/zsh
# FoxFixOneDrive - One-Click Installer for macOS
set -eu

REPO_DIR="${0:A:h}"
INSTALL_DIR="${HOME}/.local/share/onedrive-guard"
CACHE_DIR="${HOME}/.cache/onedrive-guard"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.foxingmac.onedrive-guard.plist"
LABEL="com.foxingmac.onedrive-guard"

echo "==> [1/4] Preparing directories..."
mkdir -p "$INSTALL_DIR" "$CACHE_DIR" "${HOME}/Library/LaunchAgents"

echo "==> [2/4] Compiling native Do-Not-Disturb-piercing HUD binary (onedrive_hud)..."
if command -v swiftc >/dev/null 2>&1; then
  swiftc -O "${REPO_DIR}/src/onedrive_hud.swift" -o "${INSTALL_DIR}/onedrive_hud"
  chmod +x "${INSTALL_DIR}/onedrive_hud"
else
  echo "    (swiftc not found; falling back to standard macOS Notification Center)"
fi

echo "==> [3/4] Installing FoxFixOneDrive daemon script..."
cp "${REPO_DIR}/src/onedrive_guard.sh" "${INSTALL_DIR}/onedrive_guard.sh"
chmod +x "${INSTALL_DIR}/onedrive_guard.sh"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>${INSTALL_DIR}/onedrive_guard.sh</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>${CACHE_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${CACHE_DIR}/stderr.log</string>
</dict>
</plist>
EOF

echo "==> [4/4] Starting LaunchAgent (${LABEL})..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"

"${INSTALL_DIR}/onedrive_guard.sh" --test-notify
"${INSTALL_DIR}/onedrive_guard.sh" --once
echo ""
echo "✅ FoxFixOneDrive installed and running in background!"
echo "   Log file: ${CACHE_DIR}/guard.log"
