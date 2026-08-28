ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = EveryNotifyVibe

EveryNotifyVibe_FILES = Tweak.xm
EveryNotifyVibe_CFLAGS = -fobjc-arc
EveryNotifyVibe_FRAMEWORKS = Foundation AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk

INSTALL_TARGET_PROCESSES = SpringBoard
