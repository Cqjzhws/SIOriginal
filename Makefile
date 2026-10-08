# SIOriginal — Theos 工程
# 编译 dylib：make
# 云端构建走 .github/workflows/build.yml（纯 clang，不依赖 theos）
TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SIOriginal
# v2.6.0：SIOTimeScale.m（时间源缩放引擎）+ fishhook.c（符号重绑定，MIT）
SIOriginal_FILES = Tweak/SIOriginal.m Tweak/SIOTimeScale.m Tweak/fishhook.c
SIOriginal_CFLAGS = -fobjc-arc
# v2.0.7：不再链接 AVFoundation / UserNotifications —— 链接期依赖会让 dyld 在
# 每个被注入 App 的冷启动路径上加载整套框架。二者已改为运行时惰性解析
# （dlopen+dlsym / objc_getClass），首次进后台真正需要保活时才加载。
SIOriginal_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
