#!/bin/zsh
# FoxFixOneDrive - One-Click Installer for macOS
set -eu

REPO_DIR="${0:A:h}"
INSTALL_DIR="${HOME}/.local/share/onedrive-guard"
CACHE_DIR="${HOME}/.cache/onedrive-guard"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.foxingmac.onedrive-guard.plist"
LABEL="com.foxingmac.onedrive-guard"

echo "==> [1/4] 正在准备安装目录与清理下载隔离属性 (Preparing directories)..."
xattr -cr "$REPO_DIR" 2>/dev/null || true
mkdir -p "$INSTALL_DIR" "$CACHE_DIR" "${HOME}/Library/LaunchAgents"

echo "==> [2/4] 正在部署穿透勿扰模式的右上角静音悬浮通知组件 (onedrive_hud)..."
if command -v swiftc >/dev/null 2>&1 && [[ -f "${REPO_DIR}/src/onedrive_hud.swift" ]]; then
  swiftc -O "${REPO_DIR}/src/onedrive_hud.swift" -o "${INSTALL_DIR}/onedrive_hud"
  chmod +x "${INSTALL_DIR}/onedrive_hud"
elif [[ -f "${REPO_DIR}/bin/onedrive_hud" ]]; then
  cp "${REPO_DIR}/bin/onedrive_hud" "${INSTALL_DIR}/onedrive_hud"
  chmod +x "${INSTALL_DIR}/onedrive_hud"
else
  echo "    (未检测到 swiftc 或预编译二进制，将自动回退使用 macOS 系统通知中心)"
fi

echo "==> [3/4] 正在安装 FoxFixOneDrive v7 守护脚本与开机自启配置..."
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

echo "==> [4/4] 正在启动后台守护服务 (${LABEL})..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || launchctl kickstart -k "gui/$(id -u)/${LABEL}"

"${INSTALL_DIR}/onedrive_guard.sh" --test-notify
"${INSTALL_DIR}/onedrive_guard.sh" --once
echo ""
echo "✅ FoxFixOneDrive 已成功安装并在后台静默运行（支持开机自启）！"
echo "   日志文件: ${CACHE_DIR}/guard.log"
