# SIOriginal v3.0 — Theos 工程（可选路径）
# ---------------------------------------------------------------------------
# 注意：本项目**不依赖 Theos 也能构建**。官方构建链走 .github/workflows/build.yml
# 的纯 clang 调用（macOS runner + iPhoneOS SDK），Theos 只是给本地有环境的开发者
# 用的便捷入口。两边的编译选项保持一致（-fobjc-arc / -Wl,-no_fixup_chains 等），
# 否则会出现「本地能编、CI 编不过」或产物行为不一致。
#
#   make            → 编译 SIOriginal.dylib
#   make package    → 打 deb（需要 dpkg）
#
# v3.0 结构：单文件 → 11 个模块。
#   配置状态、时长换算、门控、TLS、安装表都在 include/SIOInternal.h 里唯一声明；
#   每个 .m 只实现自己那一层的唯一职责（见各文件头部注释）。
# ---------------------------------------------------------------------------

TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SIOriginal

# 基础设施（顺序无关，链接器自行解析）
SIOriginal_FILES = \
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
    Tweak/hooks/SIOSpringBoard.m

SIOriginal_CFLAGS = -fobjc-arc -Isupport
# v2.0.7：不再链接 AVFoundation / UserNotifications —— 链接期依赖会让 dyld 在
# 每个被注入 App 的冷启动路径上加载整套框架（连带 CoreMedia/CoreAudio 一串依赖），
# 即使该 App 从不进后台保活。二者已改为运行时惰性解析
# （dlopen+dlsym / objc_getClass），首次真正需要时才加载。
SIOriginal_FRAMEWORKS = UIKit QuartzCore CoreGraphics

# arm64e 需要 clang 显式允许；-no_fixup_chains 避免在未签名/巨魔环境下
# dyld 对链式修复的额外处理开销与兼容问题。
SIOriginal_LDFLAGS = -Wl,-no_fixup_chains

include $(THEOS_MAKE_PATH)/tweak.mk
