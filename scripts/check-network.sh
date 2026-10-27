#!/bin/bash
# Tailscale 可用性诊断（只读，不安装任何东西）
# 在公司那台 Mac 上执行：bash check-network.sh
set -uo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
warn() { echo "  ! $1"; WARN=$((WARN+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# 测试 TCP 端口连通，超时 5 秒
# 用法: tcp_check 主机 端口
tcp_check() {
  nc -z -G 5 -w 5 "$1" "$2" >/dev/null 2>&1
}

echo "════ Tailscale 可用性诊断 ════"
echo "主机: $(hostname)   时间: $(date '+%Y-%m-%d %H:%M')"
echo

echo "【1】本机是否已装 Tailscale"
# 必须有可用的可执行文件（软链存在但目标缺失不算装好）
TS_BIN=""
if command -v tailscale >/dev/null 2>&1 && tailscale version >/dev/null 2>&1; then
  TS_BIN="$(command -v tailscale)"
elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
  TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi

if [ -n "$TS_BIN" ]; then
  ok "已安装 Tailscale（$TS_BIN）"
  # 已装则顺便看看是否在运行
  if ifconfig 2>/dev/null | grep -q "inet 100\."; then
    ok "已在 tailnet 中（检测到 100.x 地址）"
  else
    warn "已安装但未连接 tailnet，需运行后登录"
  fi
else
  # 区分"完全没装"和"装了但是坏的"
  if [ -e "/usr/local/bin/tailscale" ] || [ -e "/opt/homebrew/bin/tailscale" ]; then
    bad "存在 tailscale 命令但无法执行（软链指向缺失的 App），实际未装好"
    ls -l /usr/local/bin/tailscale /opt/homebrew/bin/tailscale 2>/dev/null | sed 's/^/    /'
  else
    warn "未安装 Tailscale"
  fi
fi
echo

echo "【2】设备管理（MDM）状态"
# 公司管控的设备通常无法自由安装软件
ENROLL=$(profiles status -type enrollment 2>/dev/null || true)
if echo "$ENROLL" | grep -qi "MDM enrollment: Yes"; then
  warn "设备受 MDM 管控 —— 装非白名单软件可能被阻止或违规"
elif echo "$ENROLL" | grep -qi "MDM enrollment: No"; then
  ok "未受 MDM 管控"
else
  warn "无法读取 MDM 状态（可能需要权限）"
fi
# 已下发的配置描述文件数量，多则说明公司管得严
PROF_COUNT=$(profiles -P 2>/dev/null | grep -c "attribute: name" || true)
PROF_COUNT=${PROF_COUNT:-0}
echo "    已下发配置描述文件: $PROF_COUNT 个"
echo

echo "【3】Tailscale 控制面连通性"
if tcp_check controlplane.tailscale.com 443; then
  ok "controlplane.tailscale.com:443 可达"
else
  bad "controlplane.tailscale.com:443 不可达 —— 控制面被拦，Tailscale 无法登录"
fi
if tcp_check login.tailscale.com 443; then
  ok "login.tailscale.com:443 可达"
else
  bad "login.tailscale.com:443 不可达"
fi
echo

echo "【4】DERP 中继节点连通性（打洞失败时的兜底通道）"
DERP_OK=0
for h in derp1.tailscale.com derp2.tailscale.com derp9.tailscale.com; do
  if tcp_check "$h" 443; then
    echo "  ✓ $h:443 可达"
    DERP_OK=$((DERP_OK+1))
  else
    echo "  ✗ $h:443 不可达"
  fi
done
if [ "$DERP_OK" -eq 0 ]; then
  bad "所有 DERP 都不可达 —— 即使装上 Tailscale，跨网也可能连不通"
elif [ "$DERP_OK" -lt 3 ]; then
  warn "部分 DERP 不可达（可用但不稳）"
else
  ok "DERP 通道畅通"
fi
echo

echo "【5】通用出站连通性"
if tcp_check 1.1.1.1 443; then
  ok "出站 443 正常"
else
  bad "出站 443 受阻 —— 反向隧道方案也走不通"
fi
# 公司常见 HTTP 代理
if [ -n "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" ]; then
  warn "检测到代理环境变量，Tailscale 不走代理，可能额外受影响"
  echo "    ${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-$http_proxy}}}"
else
  ok "无代理环境变量"
fi
echo

echo "【6】安装途径"
if command -v brew >/dev/null 2>&1; then
  ok "有 Homebrew，可 brew install --cask tailscale"
else
  warn "无 Homebrew，需从 App Store 或官网安装"
fi
# 快速判断是否有管理员权限
if sudo -n true 2>/dev/null; then
  ok "当前账号可免密 sudo"
else
  warn "sudo 需要密码（安装网络扩展会要求管理员授权）"
fi
echo

echo "════ 结论 ════"
if [ "$FAIL" -eq 0 ]; then
  echo "网络层对 Tailscale 友好，装上大概率能用。"
  echo "剩下只看公司制度是否允许装第三方 VPN —— 这个脚本测不出来，得问 IT。"
elif [ "$FAIL" -le 1 ] && [ "$DERP_OK" -gt 0 ]; then
  echo "部分受限，但 DERP 还有可用节点，Tailscale 仍可能工作，建议实装后试。"
else
  echo "网络层拦截明显，Tailscale 走不通。建议改用 VPS 反向隧道（Mac 只出站）。"
fi
echo
echo "通过 $PASS 项 / 警告 $WARN 项 / 失败 $FAIL 项"
