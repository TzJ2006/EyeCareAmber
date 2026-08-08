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
# 发布流程会用 tag 覆盖这个值（AMBER_VERSION=1.2.3），
# 保证 Info.plist 里的版本号和 git tag 永远一致。
VERSION="${AMBER_VERSION:-1.0.0}"

UNIVERSAL=false
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=true ;;
    --install)   INSTALL=true ;;
    *) echo "未知参数：$arg"; exit 1 ;;
  esac
done

# 逐架构原生构建，再用 lipo 合并。
#
# **不要**改成 `swift build --arch arm64 --arch x86_64`。那条路径会转给 xcbuild，
# 有两个问题：
#   1. Swift 6.1 上它接不到 Package.swift 的 swiftLanguageMode，报
#      「SWIFT_VERSION '' is unsupported」+「Unexpected duplicate tasks」直接构建失败。
#   2. 就算能过，它产出的资源 bundle 是嵌套布局（Contents/Resources/）且保留
#      规范大小写（zh-Hans.lproj），与原生构建的扁平 + 小写（zh-hans.lproj）不一致，
#      两套布局同时存在极易出问题。
# 单个 --arch 走的是原生路径，两次构建产出的布局完全一致。
build_arch() {
  local arch="$1"
  swift build -c release --arch "$arch" >&2
  swift build -c release --arch "$arch" --show-bin-path
}

APP_DIR="build/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

if $UNIVERSAL; then
  echo "▸ 构建通用二进制 (arm64 + x86_64)…"
  ARM_DIR="$(build_arch arm64)"
  X86_DIR="$(build_arch x86_64)"
  lipo -create "$ARM_DIR/$APP_NAME" "$X86_DIR/$APP_NAME" \
       -output "$APP_DIR/Contents/MacOS/$APP_NAME"
  BIN_DIR="$ARM_DIR"       # 两个架构的资源 bundle 完全相同，取其一
else
  echo "▸ 构建 arm64 原生二进制…"
  BIN_DIR="$(build_arch arm64)"
  cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
fi

# 资源 bundle 必须存在。以前这里是 `if [ -d ]` 静默跳过，
# 结果打出过一个没有任何本地化资源的 .app，而且所有检查都说没问题。
RESOURCE_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
[ -d "$RESOURCE_BUNDLE" ] || {
  echo "✗ 找不到资源 bundle：$RESOURCE_BUNDLE"
  echo "  没有它，界面所有文案都会退化成显示原始 key。"
  exit 1
}
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
find "$APP_DIR/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle" \
     -maxdepth 2 -name "*.lproj" -print -quit | grep -q . || {
  echo "✗ 资源 bundle 里没有任何 .lproj"; exit 1
}

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
