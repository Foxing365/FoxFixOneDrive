#!/bin/zsh
# FoxFixOneDrive - Status & Recent Log Viewer
set -u

INSTALL_DIR="${HOME}/.local/share/onedrive-guard"
CACHE_DIR="${HOME}/.cache/onedrive-guard"
LABEL="com.foxingmac.onedrive-guard"

echo "=== LaunchAgent Status ==="
launchctl list | grep -E "PID|${LABEL}" || echo "Not loaded."
echo ""
echo "=== Live OneDrive Check ==="
if [[ -x "${INSTALL_DIR}/onedrive_guard.sh" ]]; then
  "${INSTALL_DIR}/onedrive_guard.sh" --once
else
  "${0:A:h}/src/onedrive_guard.sh" --once
fi
echo ""
echo "=== Recent Guard Logs (${CACHE_DIR}/guard.log) ==="
tail -n 20 "${CACHE_DIR}/guard.log" 2>/dev/null || echo "No logs yet."
