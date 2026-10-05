# SIOriginal — Theos 工程
# 编译 dylib：make
# 云端构建走 .github/workflows/build.yml（纯 clang，不依赖 theos）
TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SIOriginal
SIOriginal_FILES = Tweak/SIOriginal.m
SIOriginal_CFLAGS = -fobjc-arc
SIOriginal_FRAMEWORKS = UIKit QuartzCore AVFoundation UserNotifications

include $(THEOS_MAKE_PATH)/tweak.mk
