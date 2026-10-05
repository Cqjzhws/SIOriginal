#!/bin/bash
# SIOriginal 本地构建脚本（macOS / Linux with iOS SDK）
# 用法：./build.sh

set -e

echo "=== SIOriginal v1.8.18 构建 ==="

# 检查工具链
if ! command -v clang &> /dev/null; then
    echo "错误：未找到 clang，请先安装 Xcode"
    exit 1
fi

if ! command -v ldid &> /dev/null; then
    echo "警告：未找到 ldid，将跳过签名（可 brew install ldid 安装）"
    SKIP_SIGN=1
fi

# 获取 iOS SDK 路径
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")
if [ -z "$SDK_PATH" ]; then
    echo "错误：未找到 iOS SDK，请安装 Xcode 并同意许可协议"
    exit 1
fi

echo "SDK: $SDK_PATH"

# 构建 dylib
echo ""
echo ">>> 构建 SIOriginal.dylib ..."
clang -dynamiclib -O2 -arch arm64 \
    -isysroot "$SDK_PATH" \
    -target arm64-apple-ios14.0 \
    -framework UIKit -framework QuartzCore -framework AVFoundation -framework UserNotifications \
    -fobjc-arc \
    -install_name /Library/MobileSubstrate/DynamicLibraries/SIOriginal.dylib \
    -o SIOriginal.dylib \
    Tweak/SIOriginal.m

if [ -z "$SKIP_SIGN" ]; then
    ldid -Sentitlements.plist SIOriginal.dylib
    echo "✓ dylib 已构建并签名"
else
    echo "✓ dylib 已构建（未签名）"
fi

# 构建 App
echo ""
echo ">>> 构建 SIOriginal.ipa ..."
rm -rf Payload
APP_DIR="Payload/SIOriginal.app"
mkdir -p "$APP_DIR"

clang -O2 -arch arm64 \
    -isysroot "$SDK_PATH" \
    -target arm64-apple-ios14.0 \
    -framework UIKit -framework CoreGraphics -framework Foundation \
    -fobjc-arc \
    -o "$APP_DIR/SIOriginal" \
    App/main.m

# 复制资源
cp App/Info.plist "$APP_DIR/"
for icon in App/AppIcon.png App/Icon-60@2x.png App/Icon-60@3x.png App/Icon-76@2x.png App/Icon-83.5@2x.png; do
    [ -f "$icon" ] && cp "$icon" "$APP_DIR/"
done

# 签名
if [ -z "$SKIP_SIGN" ]; then
    ldid -Sentitlements.plist "$APP_DIR/SIOriginal"
fi

# 打包 IPA
zip -qr SIOriginal.ipa Payload
echo "✓ IPA 已构建"

# 清理
rm -rf Payload

echo ""
echo "=== 构建完成 ==="
echo "产物："
ls -lh SIOriginal.dylib SIOriginal.ipa
echo ""
echo "安装："
echo "  1. TrollStore 安装 SIOriginal.ipa"
echo "  2. TrollFools 注入 SIOriginal.dylib 到目标 App"
