#!/bin/bash
# SIOriginal 本地构建脚本（macOS / Linux with iOS SDK）
# 用法：./build.sh

set -e

echo "=== SIOriginal v2.0.6 构建 ==="

# 静态核查先行：括号配平 / 原 IMP 判空 / hook 符号配对。
# 本项目历史上多次因「漏写 SIO_REQUIRE_ORIG」「括号不配平」导致编译失败或
# 运行时崩溃，静态阶段拦下比等 clang 报错更快。
if command -v python3 &> /dev/null; then
    echo ">>> 静态核查 ..."
    python3 tools/static_check.py .
else
    echo "警告：未找到 python3，跳过静态核查"
fi

# 检查工具链
if ! command -v clang &> /dev/null; then
    echo "错误：未找到 clang，请先安装 Xcode"
    exit 1
fi

if ! command -v ldid &> /dev/null; then
    echo "警告：未找到 ldid，dylib 将尝试用 codesign ad-hoc 签名（可 brew install ldid）"
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
# v2.0.2：arm64+arm64e 双架构（A12+ 设备注入要求）
clang -dynamiclib -O2 -arch arm64 -arch arm64e \
    -isysroot "$SDK_PATH" \
    -target arm64-apple-ios14.0 \
    -framework UIKit -framework QuartzCore -framework CoreGraphics -framework AVFoundation -framework UserNotifications \
    -fobjc-arc \
    -Wl,-no_fixup_chains \
    -install_name @rpath/SIOriginal.dylib \
    -o SIOriginal.dylib \
    Tweak/SIOriginal.m

# v1.8.19：dylib 只做无 entitlement 的 ad-hoc 签名。
# 绝不能把 entitlements.plist（platform-application/no-sandbox/persona-mgmt 等
# 私有授权）签进注入库——TrollFools 注入普通 App 后 dyld/AMFI 会直接 SIGKILL。
if [ -z "$SKIP_SIGN" ]; then
    ldid -S SIOriginal.dylib
    echo "✓ dylib 已构建并 ad-hoc 签名（无 entitlement）"
else
    codesign --force --sign - SIOriginal.dylib
    echo "✓ dylib 已构建并 codesign ad-hoc 签名"
fi

# 构建 App
echo ""
echo ">>> 构建 SIOriginal.ipa ..."
rm -rf Payload
APP_DIR="Payload/SIOriginal.app"
mkdir -p "$APP_DIR"

clang -O2 -arch arm64 -arch arm64e \
    -isysroot "$SDK_PATH" \
    -target arm64-apple-ios14.0 \
    -framework UIKit -framework CoreGraphics -framework Foundation \
    -fobjc-arc \
    -Wl,-no_fixup_chains \
    -o "$APP_DIR/SIOriginal" \
    App/main.m

# 复制资源
cp App/Info.plist "$APP_DIR/"
for icon in App/AppIcon.png App/Icon-60@2x.png App/Icon-60@3x.png App/Icon-76@2x.png App/Icon-83.5@2x.png; do
    [ -f "$icon" ] && cp "$icon" "$APP_DIR/"
done

# 配置 App 主程序保留私有 entitlement；整包签名生成 _CodeSignature/CodeResources
if [ -z "$SKIP_SIGN" ]; then
    ldid -Sentitlements.plist "$APP_DIR/SIOriginal"
    command -v codesign &> /dev/null && codesign --force --sign - --entitlements entitlements.plist --generate-entitlement-der "$APP_DIR" || true
else
    codesign --force --sign - --entitlements entitlements.plist --generate-entitlement-der "$APP_DIR"
fi

# 打包 IPA
zip -qr SIOriginal.ipa Payload
echo "✓ IPA 已构建"

# 校验
echo ""
echo ">>> 校验产物 ..."
# 结构审计：逐条目校验 FAT 架构表。
# 起因：v2.0.6 发布产物里 FAT 头第 2 个条目声明 x86_64，但指向的偏移处
# 实际是 ASCII 字符串而非 Mach-O 头。lipo -info 不校验这个，能一路过 CI。
if command -v python3 &> /dev/null; then
    python3 tools/audit_dylib.py SIOriginal.dylib
fi
otool -D SIOriginal.dylib | grep -q '@rpath/SIOriginal.dylib' && echo "✓ install_name = @rpath/SIOriginal.dylib"
unzip -l SIOriginal.ipa | grep -q '_CodeSignature/CodeResources' && echo "✓ CodeResources 存在" || echo "⚠ IPA 缺少 CodeResources"

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
