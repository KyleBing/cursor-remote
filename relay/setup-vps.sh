#!/bin/bash
# 在 VPS 上执行：安装 frps + nginx 站点 + Let's Encrypt 证书
# 用法: sudo bash setup-vps.sh <域名> [frp_token] [--skip-tls]
#   例: sudo bash setup-vps.sh cr.taiwuict.com
#   --skip-tls 只装 frps 不配 nginx/证书，用于先用纯隧道验证连通性
set -euo pipefail

DOMAIN="${1:?用法: setup-vps.sh <域名> [frp_token] [--skip-tls]}"
TOKEN="${2:-}"
SKIP_TLS=0
if [ "$TOKEN" = "--skip-tls" ]; then TOKEN=""; SKIP_TLS=1; fi
if [ "${3:-}" = "--skip-tls" ]; then SKIP_TLS=1; fi
FRP_VERSION="0.71.1"

# 没给 token 就现场生成一个
if [ -z "$TOKEN" ]; then
  TOKEN=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi

echo "▸ 域名: $DOMAIN"
echo "▸ frp token: $TOKEN"

# ---------- 1. 安装 frps ----------
if [ ! -x /opt/frp/frps ]; then
  echo "▸ 下载 frp $FRP_VERSION"
  TMP=$(mktemp -d)
  curl -fsSL -o "$TMP/frp.tar.gz" \
    "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz"
  tar -xzf "$TMP/frp.tar.gz" -C "$TMP"
  mkdir -p /opt/frp
  install -m 755 "$TMP/frp_${FRP_VERSION}_linux_amd64/frps" /opt/frp/frps
  rm -rf "$TMP"
  echo "  ✓ /opt/frp/frps"
else
  echo "▸ frps 已存在，跳过下载"
fi

# ---------- 2. frps 配置 ----------
echo "▸ 写入 /opt/frp/frps.toml"
cat > /opt/frp/frps.toml <<EOF
bindAddr = "0.0.0.0"
bindPort = 7000
proxyBindAddr = "127.0.0.1"
auth.method = "token"
auth.token = "$TOKEN"
allowPorts = [{ start = 8787, end = 8787 }]
transport.tls.force = true
log.to = "console"
log.level = "info"
EOF
chmod 600 /opt/frp/frps.toml

# ---------- 3. systemd 服务 ----------
echo "▸ 注册 frps.service"
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
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable frps >/dev/null 2>&1
systemctl restart frps
sleep 2
if systemctl is-active --quiet frps; then
  echo "  ✓ frps 运行中"
else
  echo "  ✗ frps 启动失败:"; journalctl -u frps -n 20 --no-pager
  exit 1
fi

# ---------- 4. nginx：先只开 80 供 ACME 验证 ----------
if [ "$SKIP_TLS" = "1" ]; then
  echo
  echo "════ frps 已就绪（跳过 nginx/证书）════"
  echo "frps 监听: 7000（控制）/ 127.0.0.1:8787（隧道出口）"
  echo "frp token: $TOKEN"
  echo
  echo "下一步：等 $DOMAIN 的 A 记录指向本机后，重跑本脚本即可自动配好 443。"
  exit 0
fi

echo "▸ 配置 nginx（阶段一：仅 80 端口 ACME 验证）"
mkdir -p /var/www/certbot
cat > /etc/nginx/sites-available/cursor-remote <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
ln -sf /etc/nginx/sites-available/cursor-remote /etc/nginx/sites-enabled/cursor-remote

# 先校验再 reload，绝不把已有站点搞挂
if nginx -t 2>/dev/null; then
  systemctl reload nginx
  echo "  ✓ nginx 已 reload"
else
  echo "  ✗ nginx 配置校验失败，已回滚"
  rm -f /etc/nginx/sites-enabled/cursor-remote
  nginx -t
  exit 1
fi

# ---------- 5. 申请证书 ----------
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  echo "▸ 申请 Let's Encrypt 证书"
  if ! command -v certbot >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq certbot
  fi
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email \
    --keep-until-expiring
else
  echo "▸ 证书已存在，跳过申请"
fi

if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  echo "✗ 证书申请失败。请确认 $DOMAIN 的 A 记录已指向本机，且 80 端口对外开放。"
  exit 1
fi

# ---------- 6. nginx：开启 443 反代 ----------
echo "▸ 配置 nginx（阶段二：443 反代到 frp 隧道）"
cat > /etc/nginx/sites-available/cursor-remote <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:CursorRemote:1m;
    ssl_session_timeout 10m;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # SSE 必须关缓冲，否则事件流会被 nginx 攒住
        proxy_buffering off;
        proxy_cache off;
        proxy_set_header Connection "";
        # 长连接：任务跑几十分钟也不掐断
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    client_max_body_size 1m;
}
EOF

if nginx -t 2>/dev/null; then
  systemctl reload nginx
  echo "  ✓ 443 已启用"
else
  echo "  ✗ nginx 配置校验失败"
  nginx -t
  exit 1
fi

# ---------- 7. 证书自动续期 ----------
# certbot 的 apt 包自带 systemd timer，确认一下
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

echo
echo "════ 完成 ════"
echo "服务地址: https://$DOMAIN"
echo "frp token: $TOKEN"
echo "把域名和 token 填到 Mac 端的 frpc.toml，再启动 frpc 即可。"
echo
echo "注意：云厂商安全组需要放行 443（App 访问）和 7000（Mac 连入）。"
