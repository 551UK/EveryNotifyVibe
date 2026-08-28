ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = EveryNotifyVibePrefs

EveryNotifyVibePrefs_FILES = ENVRootListController.m ENVApplicationListController.m
EveryNotifyVibePrefs_CFLAGS = -fobjc-arc
EveryNotifyVibePrefs_FRAMEWORKS = UIKit CoreFoundation Foundation
EveryNotifyVibePrefs_PRIVATE_FRAMEWORKS = Preferences
EveryNotifyVibePrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
