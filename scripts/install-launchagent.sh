#!/bin/bash
# 把服务端注册成 LaunchAgent：开机自启、崩溃自动拉起
# 用法: ./scripts/install-launchagent.sh [remove]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="cn.kylebing.cursor-remote"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.cursor-remote"

if [ "${1:-}" = "remove" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "✓ 已移除 LaunchAgent"
  exit 0
fi

mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

echo "▸ 编译服务端"
(cd "$ROOT/server" && go build -o bin/cursor-remote .)

echo "▸ 写入 $PLIST"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$ROOT/server/bin/cursor-remote</string>
        <string>-addr</string>
        <string>127.0.0.1</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$ROOT/server</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/server.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/server.err.log</string>
</dict>
</plist>
PLIST_EOF

# 先卸载旧的再装上，避免重复注册报错
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "✓ 已启动，日志在 $LOG_DIR/server.log"
echo "  查看 token: $ROOT/server/bin/cursor-remote -print-token"
echo "  注意：Mac 需保持不休眠，建议接电源并执行 caffeinate -s"
