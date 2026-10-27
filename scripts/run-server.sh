#!/bin/bash
# 编译并启动 cursor-remote 服务端（前台运行，Ctrl-C 退出）
set -euo pipefail

cd "$(dirname "$0")/../server"

mkdir -p bin
go build -o bin/cursor-remote .

# 把用户参数透传给服务端，例如 -port 8787
exec ./bin/cursor-remote "$@"
