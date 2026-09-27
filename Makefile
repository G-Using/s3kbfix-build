ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:14.0
THEOS_PACKAGE_SCHEME = rootless
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = S3TextKeyboardFix
S3TextKeyboardFix_FILES = Tweak.xm
S3TextKeyboardFix_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
S3TextKeyboardFix_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

before-package::
	find $(THEOS_STAGING_DIR) -name '*.dylib' -type f | while read f; do ldid -S "$$f" 2>/dev/null || true; done
