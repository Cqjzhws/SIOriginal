#!/usr/bin/env bash
# ============================================================================
#  build.sh — 本地/CI 通用构建脚本（需 macOS + Xcode Command Line Tools）
# ============================================================================
#  产出：
#    SIOriginal.dylib   — 注入用（双架构，无 entitlement 签名）
#    SIOriginal.ipa     — 配置 App
#
#  与 .github/workflows/build.yml 的编译参数保持一致，避免
#  「本地能编、CI 编不过」或产物行为不一致。
#
#  用法：
#    ./build.sh              # 编译 + 审计（不打 IPA）
#    ./build.sh --ipa        # 编译 + 打 IPA
#    ./build.sh --check      # 只跑静态核查（不编译）
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

VER="3.0.0"
DO_IPA=0
ONLY_CHECK=0
for arg in "$@"; do
  case "$arg" in
    --ipa)   DO_IPA=1 ;;
    --check) ONLY_CHECK=1 ;;
    *) echo "未知参数: $arg"; exit 2 ;;
  esac
done

# 依赖检查 —— 缺一个就早失败，不要等到编译到一半才报错。
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少依赖: $1" >&2
    echo "提示: xcode-select --install && brew install ldid" >&2
    exit 1
  fi
}

echo "=== SIOriginal v$VER 构建 ==="

# ---------------------------------------------------------------------------
# 第 1 步：静态核查（不需要 Mac，任何平台都能跑）
# ---------------------------------------------------------------------------
echo "--- [1/5] 静态核查"
python3 tools/static_check.py .
python3 tools/check_v300.py .
python3 tools/check_symbols.py .
python3 tools/check_config_keys.py .
python3 tools/test_frame_align.py

if [ "$ONLY_CHECK" = "1" ]; then
  echo "=== 仅核查模式，结束 ==="
  exit 0
fi

need xcrun; need clang; need ldid

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "     SDK: $SDK"

# ---------------------------------------------------------------------------
# 第 2 步：编译 dylib（arm64 + arm64e 双架构）
# ---------------------------------------------------------------------------
echo "--- [2/5] 编译 dylib"
clang -dynamiclib -O2 \
  -arch arm64 -arch arm64e \
  -isysroot "$SDK" \
  -target arm64-apple-ios14.0 \
  -framework UIKit -framework QuartzCore -framework CoreGraphics \
  -fobjc-arc \
  -I Tweak/include -I Tweak \
  -Wl,-no_fixup_chains \
  -install_name @rpath/SIOriginal.dylib \
  -o SIOriginal.dylib \
  Tweak/SIOCore.m \
  Tweak/SIOPlatform.m \
  Tweak/SIOConfig.m \
  Tweak/SIOEngine.m \
  Tweak/SIOScheduler.m \
  Tweak/SIOUI.m \
  Tweak/SIOInstaller.m \
  Tweak/SIOBackground.m \
  Tweak/hooks/SIOCoreAnimation.m \
  Tweak/hooks/SIOUIViewAnim.m \
  Tweak/hooks/SIOViewControllers.m \
  Tweak/hooks/SIOControls.m \
  Tweak/hooks/SIOCollections.m \
  Tweak/hooks/SIOScrollView.m \
  Tweak/hooks/SIOHighRefresh.m \
  Tweak/hooks/SIOSpringBoard.m

# 注入用 dylib 必须「不带任何 entitlement」ad-hoc 签名。
# 嵌入私有 entitlement 会被 AMFI 在宿主 App 里 SIGKILL（表现为注入后启动闪退）。
ldid -S SIOriginal.dylib

# ---------------------------------------------------------------------------
# 第 3 步：产物结构审计
# ---------------------------------------------------------------------------
echo "--- [3/5] 结构审计"
otool -D SIOriginal.dylib | grep -q '@rpath/SIOriginal.dylib' \
  || { echo "FAIL: install_name 必须是 @rpath/SIOriginal.dylib"; exit 1; }

lipo -info SIOriginal.dylib | tee /tmp/sio_lipo.txt
grep -q arm64  /tmp/sio_lipo.txt || { echo "FAIL: 缺 arm64"; exit 1; }
grep -q arm64e /tmp/sio_lipo.txt || { echo "FAIL: 缺 arm64e"; exit 1; }

if ldid -e SIOriginal.dylib 2>/dev/null | grep -q .; then
  echo "FAIL: dylib 内嵌了 entitlement，注入普通 App 会被 AMFI 杀死"; exit 1
fi

# 红线 #4：不得链接 AVFoundation / UserNotifications
if otool -L SIOriginal.dylib | grep -qE 'AVFoundation|UserNotifications'; then
  echo "FAIL: dylib 不应链接 AVFoundation/UserNotifications（惰性加载）"; exit 1
fi

python3 tools/test_audit_dylib.py
python3 tools/audit_dylib.py SIOriginal.dylib
echo "     审计通过"

# ---------------------------------------------------------------------------
# 第 4 步：编译配置 App
# ---------------------------------------------------------------------------
echo "--- [4/5] 编译配置 App"
APP_DIR="Payload/SIOriginal.app"
rm -rf Payload
mkdir -p "$APP_DIR"

clang -O2 \
  -arch arm64 -arch arm64e \
  -isysroot "$SDK" \
  -target arm64-apple-ios14.0 \
  -framework UIKit -framework CoreGraphics -framework Foundation \
  -fobjc-arc \
  -Wl,-no_fixup_chains \
  -o "$APP_DIR/SIOriginal" \
  App/main.m

cp App/Info.plist "$APP_DIR/"
for icon in App/assets/*.png; do
  [ -f "$icon" ] && cp "$icon" "$APP_DIR/"
done

# 配置 App 主程序需要私有 entitlement（写 /var/Managed Preferences、
# posix_spawn persona 提权重启），由 TrollStore 安装时保留授权。
codesign --force --sign - --entitlements entitlements.plist \
  --generate-entitlement-der "$APP_DIR"

# ---------------------------------------------------------------------------
# 第 5 步：打 IPA
# ---------------------------------------------------------------------------
if [ "$DO_IPA" = "1" ]; then
  echo "--- [5/5] 打 IPA"
  rm -f SIOriginal.ipa
  if command -v zip >/dev/null 2>&1; then
    zip -qr SIOriginal.ipa Payload
  else
    # zip 不可用时用 python 兜底（保持路径分隔符为 /）
    python3 - <<'PY'
import zipfile, os
with zipfile.ZipFile('SIOriginal.ipa', 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _d, files in os.walk('Payload'):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, p.replace(os.sep, '/'))
PY
  fi
  unzip -l SIOriginal.ipa | grep -q '_CodeSignature/CodeResources' \
    || { echo "FAIL: IPA 缺包签名清单"; exit 1; }
  echo "     SIOriginal.ipa 已生成"
else
  echo "--- [5/5] 跳过 IPA（加 --ipa 生成）"
fi

echo
echo "=== 构建完成 ==="
ls -l SIOriginal.dylib 2>/dev/null || true
ls -l SIOriginal.ipa   2>/dev/null || true
