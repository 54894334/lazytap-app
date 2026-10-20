TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = LazyTap
LazyTap_FILES = src/LTAppMain.m src/LTRootVC.m src/LTRunner.m src/LTKeepAlive.m \
                src/LTConfig.m src/LTHID.m src/LTUITouch.m
LazyTap_CFLAGS = -fobjc-arc -I src \
	-Wno-error -Wno-deprecated-declarations -Wno-unused-function \
	-Wno-objc-method-access -Wno-unused-variable -Wno-unused-value \
	-Wno-nullability-completeness -Wno-format -Wno-incompatible-pointer-types \
	-Wno-unused-but-set-variable -Wno-shorten-64-to-32
LazyTap_FRAMEWORKS = UIKit Foundation QuartzCore AVFoundation WebKit
# 触摸能否打到别的 App，全看这几个 entitlement
LazyTap_CODESIGN_FLAGS = -Sentitlements.plist
LazyTap_INSTALL_PATH = /Applications

include $(THEOS_MAKE_PATH)/application.mk
