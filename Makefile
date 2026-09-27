export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# arm64e 进程 (系统"设置") 需要 arm64e 切片, 且必须用 macOS CI (Apple 原生工具链):
# Linux 工具链的 arm64e 注入设置进程时 objc readClass SIGBUS (v2.2-v3.1 的崩溃根因)。
export ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobileNotes

include $(THEOS)/makefiles/common.mk

# 实例 1: 主插件 (注入备忘录, 视频背景渲染)
TWEAK_NAME = NotesVideoBG
NotesVideoBG_FILES = Tweak.x NVBCommon.m
NotesVideoBG_FRAMEWORKS = UIKit AVFoundation CoreMedia
NotesVideoBG_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

# 实例 2: 设置面板 bundle (v3.3 恢复经典架构: 入口 plist 必须
# 带 bundle + isController + entryControllerClass 三个键才会显示,
# 本机 preferenceloader 实测: 缺 bundle 键或缺 isController 均不显示)
BUNDLE_NAME = NVBPrefs
NVBPrefs_FILES = PrefsController.m NVBCommon.m
# 注意: 不链接 PhotosUI (PHPicker 全部运行时调用, 静态元数据会导致宿主崩溃)
NVBPrefs_FRAMEWORKS = UIKit AVFoundation CoreMedia
NVBPrefs_LDFLAGS = -framework Preferences -F$(THEOS)/sdks/iPhoneOS14.5.sdk/System/Library/PrivateFrameworks
NVBPrefs_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations
NVBPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
