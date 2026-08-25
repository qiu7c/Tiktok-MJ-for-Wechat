ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0
DEBUG = 0
FINALPACKAGE = 1

INSTALL_TARGET_PROCESSES = WeChat

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TiktokMJ

TiktokMJ_FILES = Tweak.xm $(wildcard Sources/*.m)
TiktokMJ_OBJCFLAGS = -fobjc-arc
TiktokMJ_FRAMEWORKS = UIKit Foundation QuartzCore CoreImage AVFoundation Metal MetalKit

include $(THEOS_MAKE_PATH)/tweak.mk
