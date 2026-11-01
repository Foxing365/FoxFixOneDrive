#!/bin/zsh
# FoxFixOneDrive - Uninstaller for macOS
set -u

INSTALL_DIR="${HOME}/.local/share/onedrive-guard"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.foxingmac.onedrive-guard.plist"
LABEL="com.foxingmac.onedrive-guard"

echo "==> Restoring OneDrive to default P-Core scheduling..."
if [[ -x "${INSTALL_DIR}/onedrive_guard.sh" ]]; then
  "${INSTALL_DIR}/onedrive_guard.sh" --restore || true
fi

echo "==> Unloading LaunchAgent (${LABEL})..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
rm -f "$PLIST_PATH"
rm -rf "$INSTALL_DIR"

echo "✅ FoxFixOneDrive has been cleanly uninstalled."
