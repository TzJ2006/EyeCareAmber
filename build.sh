#!/bin/bash
#
# 构建 Amber.app。
#
#   ./build.sh              仅 arm64（Apple Silicon 原生，推荐）
#   ./build.sh --universal  arm64 + x86_64 通用二进制
#   ./build.sh --install    构建完成后安装到 /Applications 并启动
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Amber"
DISPLAY_NAME="琥珀护眼"
BUNDLE_ID="com.amber.eyecare"
VERSION="1.0.0"

UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=true ;;
    --install)   INSTALL=true ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

if $UNIVERSAL; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  echo "▸ 构建通用二进制 (arm64 + x86_64)…"
else
  ARCH_FLAGS=(--arch arm64)
  echo "▸ 构建 arm64 原生二进制…"
fi

swift build -c release "${ARCH_FLAGS[@]}"

BIN_PATH="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/$APP_NAME"
[ -f "$BIN_PATH" ] || { echo "找不到产物：$BIN_PATH"; exit 1; }

APP_DIR="build/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

RESOURCE_BUNDLE="$(dirname "$BIN_PATH")/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>         <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key>      <string>15.0</string>

    <!-- 纯菜单栏应用：不进 Dock、不进 Cmd-Tab -->
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>

    <!-- 只有「日出日落来源 = 使用定位」时才会触发这个权限请求 -->
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>用于计算你所在地的日出日落时间，从而在天黑时自动调整屏幕色温。只取一次坐标并缓存在本地，不会持续定位，也不会上传。</string>

    <key>NSHumanReadableCopyright</key>    <string>本地构建，无网络请求</string>
</dict>
</plist>
PLIST

# 临时签名。SMAppService（开机自启）要求有签名才能注册。
codesign --force --sign - --timestamp=none "$APP_DIR" 2>/dev/null \
  || echo "⚠︎  签名失败，开机自启可能无法使用"

SIZE=$(du -sh "$APP_DIR" | cut -f1)
echo "✓ 已生成 $APP_DIR ($SIZE)"
lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null | sed 's/^/  架构：/'

if $INSTALL; then
  echo "▸ 安装到 /Applications…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_DIR" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "✓ 已启动，看菜单栏右上角"
else
  echo ""
  echo "试运行：  open $APP_DIR"
  echo "安装：    ./build.sh --install"
fi
