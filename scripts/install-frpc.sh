#!/bin/bash
# 把 frpc 注册成 LaunchAgent：开机自启、断线自动重连
# 用法: ./scripts/install-frpc.sh <serverAddr> <token> [remoteDomain]
#       ./scripts/install-frpc.sh remove
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="cn.kylebing.cursor-remote-frpc"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
FRP_DIR="$HOME/.cursor-remote/frp"
LOG_DIR="$HOME/.cursor-remote"
FRP_VERSION="0.71.1"

# 卸载
if [ "${1:-}" = "remove" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "✓ 已移除 frpc LaunchAgent"
  exit 0
fi

SERVER="${1:?用法: install-frpc.sh <serverAddr> <token> [remoteDomain]}"
TOKEN="${2:?缺少 token}"

mkdir -p "$FRP_DIR" "$LOG_DIR" "$(dirname "$PLIST")"

# ---------- 下载 frpc（macOS arm64 或 amd64 自动判断）----------
if [ ! -x "$FRP_DIR/frpc" ]; then
  case "$(uname -m)" in
    arm64)  ARCH="darwin_arm64" ;;
    x86_64) ARCH="darwin_amd64" ;;
    *) echo "✗ 不支持的架构 $(uname -m)"; exit 1 ;;
  esac
  echo "▸ 下载 frp $FRP_VERSION ($ARCH)"
  TMP=$(mktemp -d)
  curl -fsSL -o "$TMP/frp.tar.gz" \
    "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_${ARCH}.tar.gz"
  tar -xzf "$TMP/frp.tar.gz" -C "$TMP"
  install -m 755 "$TMP/frp_${FRP_VERSION}_${ARCH}/frpc" "$FRP_DIR/frpc"
  rm -rf "$TMP"
  echo "  ✓ $FRP_DIR/frpc"
else
  echo "▸ frpc 已存在"
fi

# ---------- 写配置 ----------
echo "▸ 写入 $FRP_DIR/frpc.toml"
cat > "$FRP_DIR/frpc.toml" <<EOF
serverAddr = "$SERVER"
serverPort = 7000
auth.method = "token"
auth.token = "$TOKEN"
transport.tls.enable = true
transport.heartbeatInterval = 30
transport.heartbeatTimeout = 90

[[proxies]]
name = "cursor-remote"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8787
remotePort = 8787
EOF
chmod 600 "$FRP_DIR/frpc.toml"

# ---------- LaunchAgent ----------
echo "▸ 注册 $LABEL"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$FRP_DIR/frpc</string>
        <string>-c</string>
        <string>$FRP_DIR/frpc.toml</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/frpc.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/frpc.err.log</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "════ 完成 ════"
echo "状态: launchctl print gui/$(id -u)/$LABEL | head -20"
echo "日志: $LOG_DIR/frpc.log"
echo "提示: Mac 需保持不休眠，建议 caffeinate -s"
