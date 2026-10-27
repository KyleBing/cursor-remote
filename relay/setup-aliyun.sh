#!/bin/bash
# 在 kylebing.cn 那台阿里云上执行：装 frps + 在现有 443 站点上加 /cursor-remote/ 路径
# 用法: sudo bash setup-aliyun.sh [frp_token]
# 特点：复用现有 kylebing.cn 证书，不需要新增 DNS 记录
set -euo pipefail

TOKEN="${1:-}"
if [ -z "$TOKEN" ]; then
  TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

NGINX_CONF=/etc/nginx/sites-enabled/default
SNIPPET=/etc/nginx/snippets/cursor-remote.conf
MARKER="# cursor-remote (由 setup-aliyun.sh 注入)"

echo "▸ frp token: $TOKEN"

# ---------- 1. 装 frps（二进制由调用方预先上传到 /tmp/frps）----------
if [ ! -x /opt/frp/frps ]; then
  if [ ! -f /tmp/frps ]; then
    echo "✗ 缺少 /tmp/frps，请先 scp 上传：scp frps root@host:/tmp/frps"
    exit 1
  fi
  mkdir -p /opt/frp
  install -m 755 /tmp/frps /opt/frp/frps
  rm -f /tmp/frps
  echo "  ✓ /opt/frp/frps"
else
  echo "▸ frps 已存在"
fi

# ---------- 2. frps 配置 ----------
# 1Mbps + 1G 内存的小机器，只做纯隧道，不做多余的事
cat > /opt/frp/frps.toml <<EOF
bindAddr = "0.0.0.0"
bindPort = 7000
proxyBindAddr = "127.0.0.1"
auth.method = "token"
auth.token = "$TOKEN"
allowPorts = [{ start = 8787, end = 8787 }]
transport.tls.force = true
log.to = "console"
log.level = "warn"
EOF
chmod 600 /opt/frp/frps.toml

# ---------- 3. systemd ----------
cat > /etc/systemd/system/frps.service <<'EOF'
[Unit]
Description=frp server (cursor-remote tunnel)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/frp/frps -c /opt/frp/frps.toml
Restart=always
RestartSec=5
# 小内存机器，限制一下
MemoryMax=128M

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable frps >/dev/null 2>&1
systemctl restart frps
sleep 2
systemctl is-active --quiet frps || { echo "✗ frps 启动失败"; journalctl -u frps -n 20 --no-pager; exit 1; }
echo "  ✓ frps 运行中"

# ---------- 4. nginx：把 location 放进独立 snippet，主配置只加一行 include ----------
echo "▸ 写入 $SNIPPET"
cat > "$SNIPPET" <<'EOF'
# cursor-remote 反向代理：https://kylebing.cn/cursor-remote/ → 127.0.0.1:8787（frp 隧道到 Mac）
location /cursor-remote/ {
    proxy_pass http://127.0.0.1:8787/;
    proxy_http_version 1.1;

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # SSE 必须关缓冲，否则事件流会被 nginx 攒住，手机上看着像卡死
    proxy_buffering off;
    proxy_cache off;
    proxy_set_header Connection "";

    # 任务可能跑很久，别中途掐断
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}

# 少了结尾斜杠就补上，避免 App 拼出 /cursor-remoteapi/xxx
location = /cursor-remote {
    return 301 /cursor-remote/;
}
EOF

# 只在缺失时注入，重复执行不会叠加
if grep -q "cursor-remote (由 setup-aliyun.sh 注入)" "$NGINX_CONF" 2>/dev/null; then
  echo "▸ include 已存在，跳过注入"
else
  echo "▸ 备份并注入 include"
  # 备份绝不能放 sites-enabled/：nginx 会加载该目录下所有文件，
  # 备份副本会导致 duplicate upstream / duplicate server 报错
  BACKUP_DIR=/root/nginx-backups
  mkdir -p "$BACKUP_DIR"
  BACKUP="$BACKUP_DIR/default.$(date +%Y%m%d%H%M%S)"
  cp -a "$NGINX_CONF" "$BACKUP"
  # 插到 Certbot 管理的 listen 行之前，仍在 server 块内部
  awk -v marker="$MARKER" '
    BEGIN { done = 0 }
    !done && /listen \[::\]:443 ssl ipv6only=on;/ {
      print "\t" marker
      print "\tinclude snippets/cursor-remote.conf;"
      print ""
      done = 1
    }
    { print }
  ' "$NGINX_CONF" > "${NGINX_CONF}.new"

  if ! grep -q "include snippets/cursor-remote.conf;" "${NGINX_CONF}.new"; then
    echo "✗ 注入失败：没找到锚点行，已放弃（原配置未改动）"
    rm -f "${NGINX_CONF}.new"
    exit 1
  fi
  mv "${NGINX_CONF}.new" "$NGINX_CONF"
fi

# ---------- 5. 校验并重载 ----------
if nginx -t 2>/dev/null; then
  systemctl reload nginx
  echo "  ✓ nginx 已重载"
else
  echo "✗ nginx 配置校验失败，从备份恢复"
  LATEST=$(ls -t /root/nginx-backups/default.* 2>/dev/null | head -1)
  [ -n "$LATEST" ] && cp -a "$LATEST" "$NGINX_CONF"
  nginx -t
  exit 1
fi

echo
echo "════ 完成 ════"
echo "访问地址: https://kylebing.cn/cursor-remote/"
echo "frp token: $TOKEN"
echo "把 token 填到 Mac 端：./scripts/install-frpc.sh 47.104.156.196 $TOKEN"
