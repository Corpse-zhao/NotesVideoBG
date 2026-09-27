export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# arm64e 进程 (系统"设置"/OneSettings) 强制要求 arm64e 切片, 不接受回落 arm64。
# 工具链默认 arm64e 输出缺 LC_DYLD_CHAINED_FIXUPS (指针已链式编码但无修复信息),
# dyld 拒载/SIGBUS。显式开启链式修复让 ld 输出带 fixup 信息的合法 arm64e 切片。
export ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobileNotes

include $(THEOS)/makefiles/common.mk

# 实例 1: 主插件 (注入备忘录, 视频背景渲染)
TWEAK_NAME = NotesVideoBG
NotesVideoBG_FILES = Tweak.x NVBCommon.m
NotesVideoBG_FRAMEWORKS = UIKit AVFoundation CoreMedia
NotesVideoBG_LDFLAGS = -Wl,-fixup_chains
NotesVideoBG_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

# 实例 2: 设置面板 (加载进 系统"设置"/OneSettings, 素材管理+参数调节)
BUNDLE_NAME = NVBPrefs
NVBPrefs_FILES = PrefsController.m NVBCommon.m
# 注意: 不链接 PhotosUI (PHPicker 全部运行时调用, 静态元数据会导致宿主崩溃)
NVBPrefs_FRAMEWORKS = UIKit AVFoundation CoreMedia
NVBPrefs_LDFLAGS = -framework Preferences -Wl,-fixup_chains
NVBPrefs_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations
NVBPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
