#!/bin/bash
# 接电源时阻止 Mac 睡眠，保证 frp 隧道不断
# 用法: ./scripts/install-caffeinate.sh [remove]
# 注意：合盖仍会睡眠，远程使用需保持开盖或接外接显示器
set -euo pipefail

LABEL="cn.kylebing.cursor-remote-awake"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = "remove" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "✓ 已移除，Mac 恢复正常的睡眠策略"
  exit 0
fi

mkdir -p "$(dirname "$PLIST")"

# -s 仅在接电源时阻止系统睡眠，用电池时仍然按正常策略休眠
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✓ 已启用：接电源时阻止睡眠"
echo "  撤销: ./scripts/install-caffeinate.sh remove"
echo "  注意：合盖依然会睡，远程使用请保持开盖"
