export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# 关键修复: 只编 arm64。
# 本工具链产生的 arm64e 切片 (chained fixups) 不含任何重定位信息,
# arm64e 进程 (系统"设置"/OneSettings) 加载它时 objc readClass 解引用
# 未修复指针 -> SIGBUS 闪退。去掉 arm64e 切片后, arm64e 进程会回落
# 加载 arm64 切片 (经典 DYLD_INFO 重定位, 已验证完全合法)。
export ARCHS = arm64
INSTALL_TARGET_PROCESSES = MobileNotes

include $(THEOS)/makefiles/common.mk

# 实例 1: 主插件 (注入备忘录, 视频背景渲染)
TWEAK_NAME = NotesVideoBG
NotesVideoBG_FILES = Tweak.x NVBCommon.m
NotesVideoBG_FRAMEWORKS = UIKit AVFoundation CoreMedia
NotesVideoBG_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

# 实例 2: 设置面板 (加载进 系统"设置"/OneSettings, 素材管理+参数调节)
BUNDLE_NAME = NVBPrefs
NVBPrefs_FILES = PrefsController.m NVBCommon.m
# 注意: 不链接 PhotosUI (PHPicker 全部运行时调用, 静态元数据会导致宿主崩溃)
NVBPrefs_FRAMEWORKS = UIKit AVFoundation CoreMedia
NVBPrefs_LDFLAGS = -framework Preferences
NVBPrefs_CFLAGS = -fobjc-arc -fno-threadsafe-statics -Wno-deprecated-declarations
NVBPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
