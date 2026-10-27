#!/bin/bash
# 编译并把 App 装到已连接的真机
# 用法: ./scripts/install-ios.sh [设备名或UDID]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/ios"
cd "$IOS"

# 工程不存在就先生成
if [ ! -d "CursorRemote.xcodeproj" ]; then
  echo "▸ 生成 Xcode 工程"
  xcodegen generate
fi

# 从 xcodebuild 的目标列表里解析出真机 UDID（排除模拟器）
list_devices() {
  xcodebuild -project CursorRemote.xcodeproj -scheme CursorRemote -showdestinations 2>/dev/null \
    | grep "platform:iOS," \
    | grep -v "Simulator"
}

# 按名称或 UDID 匹配设备
resolve_device() {
  local query="$1"
  list_devices | while IFS= read -r line; do
    if [ -n "$query" ] && [[ "$line" != *"$query"* ]]; then
      continue
    fi
    echo "$line" | sed -n 's/.*id:\([^,}]*\).*/\1/p' | tr -d ' '
    break
  done
}

QUERY="${1:-}"
if [ -z "$QUERY" ]; then
  echo "▸ 探测已连接的真机"
fi
DEVICE="$(resolve_device "$QUERY")"

if [ -z "$DEVICE" ]; then
  echo "✗ 没有匹配的真机，请连接设备或手动传入设备名/UDID" >&2
  echo "  当前可用真机：" >&2
  list_devices >&2
  exit 1
fi
echo "▸ 目标设备: $DEVICE"

echo "▸ 编译（Debug）"
xcodebuild -project CursorRemote.xcodeproj \
  -scheme CursorRemote \
  -configuration Debug \
  -destination "id=$DEVICE" \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  build | grep -E "error:|warning: |BUILD" || true

APP="$IOS/build/Build/Products/Debug-iphoneos/CursorRemote.app"
if [ ! -d "$APP" ]; then
  echo "✗ 构建产物不存在: $APP" >&2
  exit 1
fi

echo "▸ 安装到设备"
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "✓ 已安装：远程 Cursor"
