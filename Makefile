export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = MobileNotes

include $(THEOS_MAKE_PATH)/common.mk

# 实例 1: 主插件 (注入备忘录, 视频背景渲染)
TWEAK_NAME = NotesVideoBG
NotesVideoBG_FILES = Tweak.x NVBCommon.m
NotesVideoBG_FRAMEWORKS = UIKit AVFoundation CoreMedia
NotesVideoBG_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

# 实例 2: 设置面板 (加载进 系统"设置"/OneSettings, 素材管理+参数调节)
BUNDLE_NAME = NVBPrefs
NVBPrefs_FILES = PrefsController.m NVBCommon.m
NVBPrefs_FRAMEWORKS = UIKit AVFoundation CoreMedia PhotosUI
NVBPrefs_LDFLAGS = -framework Preferences
NVBPrefs_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations
NVBPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
