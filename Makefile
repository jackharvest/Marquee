APP_NAME   = Marquee
BUILD_TYPE = debug

# SDK pin — the no-Xcode build's one piece of environment defence.
# The macOS 27 SDK declares SwiftUI's @State/@Binding as MACROS, expanded at compile time by
# libSwiftUIMacros.dylib. That plugin ships inside Xcode's MacOSX platform only, never with the
# Command Line Tools, so once a CLT update points /Library/Developer/CommandLineTools/SDKs/
# MacOSX.sdk at 27.0, every `swift build` here dies on the first @State with "external macro
# implementation type 'SwiftUIMacros.StateMacro' could not be found". The macOS 26 SDK still
# declares them as ordinary property wrappers, needs no plugin, and targets the same
# macos14.0 deployment — so when the selected developer dir has no SwiftUI macro plugin and
# that SDK is installed, build against it. A machine with real Xcode selected finds the plugin
# and this changes nothing.
DEV_DIR := $(shell xcode-select -p 2>/dev/null)
SWIFTUI_MACRO_PLUGIN := $(wildcard \
  $(DEV_DIR)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib \
  $(DEV_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib \
  $(DEV_DIR)/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib)
LEGACY_SDK := /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
ifeq ($(SWIFTUI_MACRO_PLUGIN),)
ifneq ($(wildcard $(LEGACY_SDK)),)
export SDKROOT := $(LEGACY_SDK)
endif
endif
BUILD_DIR  = .build/$(BUILD_TYPE)
APP_BUNDLE = $(APP_NAME).app
RESOURCES_DIR = $(APP_BUNDLE)/Contents/Resources
MACOS_DIR     = $(APP_BUNDLE)/Contents/MacOS

.PHONY: all debug release app run dmg clean

all: app

debug:
	swift build

release:
	swift build -c release
	$(eval BUILD_TYPE := release)
	$(eval BUILD_DIR  := .build/release)

app: debug
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp $(BUILD_DIR)/$(APP_NAME) $(MACOS_DIR)/
	@cp Info.plist $(APP_BUNDLE)/Contents/
	@# Keep the bundle's version in sync with the in-app badge (the single bump point):
	@# extract "vX.Y.Z" from ContentView+Chrome.swift and write it into the copied plist,
	@# so About/Finder/crash reports never show a stale hardcoded version again.
	@V=$$(grep -o 'Text("v[0-9.]*")' Marquee/UI/ContentView+Chrome.swift | grep -o '[0-9][0-9.]*'); \
	 /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $$V" $(APP_BUNDLE)/Contents/Info.plist
	@cp assets/images/AppIcon.icns $(RESOURCES_DIR)/
	@cp assets/images/Marquee-logo-icon.png $(RESOURCES_DIR)/AppIcon.png
	@cp assets/images/Marquee-logo-icon_128.png $(RESOURCES_DIR)/
	@cp assets/images/Marquee-logo-icon_72.png $(RESOURCES_DIR)/
	@cp assets/images/Marquee-logo-icon_64.png $(RESOURCES_DIR)/
	@cp assets/images/Marqee-Title.png $(RESOURCES_DIR)/
	@cp assets/music/*.mp3 $(RESOURCES_DIR)/
	@# Copy SPM-bundled resources if present
	@-cp -rn "$(BUILD_DIR)/Marquee_Marquee.bundle/Contents/Resources/" $(RESOURCES_DIR)/ 2>/dev/null || true
	@# Strip xattr detritus + ad-hoc re-sign so the bundle launches (macOS 26 kills an
	@# invalid-signature bundle with SIGKILL "Code Signature Invalid" on launch).
	@xattr -cr $(APP_BUNDLE)
	@codesign --force --deep --sign - $(APP_BUNDLE) >/dev/null 2>&1 || true
	@echo "✓ Built $(APP_BUNDLE)"

run: app
	@open $(APP_BUNDLE)

dmg: app
	@./tools/build-dmg.sh

clean:
	@rm -rf .build $(APP_BUNDLE)
	@echo "✓ Cleaned"
