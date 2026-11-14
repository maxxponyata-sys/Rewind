TARGET := iphone:clang:10.3:10.0
ARCHS = armv7 arm64
INSTALL_TARGET_PROCESSES = Rewind

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Rewind

Rewind_FILES = $(wildcard Sources/*.m)
Rewind_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AVFoundation AVKit CoreMedia MediaPlayer Security
Rewind_CFLAGS = -fobjc-arc -ISources -Wno-deprecated-declarations
Rewind_CODESIGN_FLAGS = -S

include $(THEOS_MAKE_PATH)/application.mk
