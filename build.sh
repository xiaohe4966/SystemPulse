#!/bin/bash
# SystemPulse 构建脚本 —— 纯 swiftc / clang，不需要 Xcode 工程
#
#   ./build.sh              编译 Universal 版本（arm64 + x86_64，可分发）
#   ./build.sh --run        编译后启动
#   ./build.sh --native     只编译当前机器架构（更快，适合本机调试）
#
# 参数可组合，例如：./build.sh --native --run
# 应用图标由 tools/MakeAppIcon 现场绘制（无需图片素材），可用环境变量换风格：
#   SYSTEMPULSE_ICON_STYLE=pulse ./build.sh      # chip（默认）/ pulse / minimal
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/SystemPulse.app"
BUILD="$ROOT/.build"
DEPLOY="11.0"
ICON_STYLE="${SYSTEMPULSE_ICON_STYLE:-chip}"

RUN=0
NATIVE=0
for arg in "$@"; do
    case "$arg" in
        --run)    RUN=1 ;;
        --native) NATIVE=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "未知参数: $arg（可用: --run / --native / --help）" >&2; exit 1 ;;
    esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>SystemPulse</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>local.systempulse.monitor</string>
    <key>CFBundleName</key>
    <string>SystemPulse</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <string>1</string>
    <key>NSHighResolutionCapable</key>
    <string>1</string>
</dict>
</plist>
PLIST

# 应用图标：用自带生成器画 10 档 PNG，再合成 icns（16/32/64 档自动简化细节）
echo "生成应用图标 ($ICON_STYLE) ..."
swiftc -swift-version 5 -O "$ROOT/tools/MakeAppIcon/main.swift" -o "$BUILD/makeicon"
rm -rf "$BUILD/AppIcon.iconset"
"$BUILD/makeicon" --style "$ICON_STYLE" --iconset "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# 温度读取用 C 实现（IOKit 私有 HID 接口），编译成对象文件后与 Swift 一起链接
compile_arch() {
    local arch="$1" out="$2"
    clang -O2 -arch "$arch" -mmacosx-version-min="$DEPLOY" \
        -c "$ROOT/Sources/TemperatureProbe.c" -o "$BUILD/TemperatureProbe-$arch.o"
    swiftc -swift-version 5 -O -target "$arch-apple-macos$DEPLOY" \
        -import-objc-header "$ROOT/Sources/TemperatureProbe.h" \
        -o "$out" \
        "$ROOT/Sources/"*.swift "$BUILD/TemperatureProbe-$arch.o"
}

BIN="$APP/Contents/MacOS/SystemPulse"
if [[ "$NATIVE" -eq 1 ]]; then
    echo "编译本机架构 ($(uname -m)) ..."
    compile_arch "$(uname -m)" "$BIN"
else
    echo "编译 Universal (arm64 + x86_64) ..."
    compile_arch arm64 "$BUILD/SystemPulse-arm64"
    compile_arch x86_64 "$BUILD/SystemPulse-x86_64"
    lipo -create -output "$BIN" \
        "$BUILD/SystemPulse-arm64" "$BUILD/SystemPulse-x86_64"
fi

# ad-hoc 签名，保证本机可直接运行
codesign --force --sign - "$APP" 2>/dev/null || true

echo "构建完成: $APP ($(lipo -archs "$BIN" | tr '\n' ' '))"
if [[ "$RUN" -eq 1 ]]; then
    open "$APP"
    echo "已启动，菜单栏右上角可找到心电图图标"
fi
