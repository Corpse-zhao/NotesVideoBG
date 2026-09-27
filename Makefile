export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# arm64e 进程 (系统"设置"/OneSettings) 强制要求 arm64e 切片。
# 必须 clang>=12 工具链 (iOS 14+ arm64e ABI), clang-10 老 ABI 的 arm64e 切片
# 会让 objc readClass 直接 SIGBUS (v2.2-v2.6 的崩溃根因)。
export ARCHS = arm64 arm64e
# 主插件同时注入备忘录(渲染背景)与系统设置(承载设置面板, 不再使用独立 bundle)
INSTALL_TARGET_PROCESSES = MobileNotes Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NotesVideoBG
NotesVideoBG_FILES = Tweak.x NVBCommon.m PrefsController.m
NotesVideoBG_FRAMEWORKS = UIKit AVFoundation CoreMedia
# 设置面板类 (PSListController 子类) 在本 dylib 内, 需链接 Preferences
NotesVideoBG_LDFLAGS = -framework Preferences
NotesVideoBG_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
