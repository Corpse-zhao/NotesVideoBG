export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = MobileNotes

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NotesVideoBG
NotesVideoBG_FILES = Tweak.x
NotesVideoBG_FRAMEWORKS = UIKit AVFoundation PhotosUI CoreMedia
NotesVideoBG_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -fno-threadsafe-statics

include $(THEOS_MAKE_PATH)/tweak.mk
