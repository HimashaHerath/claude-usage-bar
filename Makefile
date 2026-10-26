# Claude Usage: a menu bar item for Claude plan usage.
#   make install   build, sign, copy to ~/Applications and launch
#   make zip       universal release zip in build/
APP     := build/Claude Usage.app
BIN     := $(APP)/Contents/MacOS/ClaudeUsage
DEST    := $(HOME)/Applications/Claude Usage.app
SOURCES := $(wildcard Sources/*.swift)
TARGET  := apple-macos15
# Sign with your Apple Development certificate when you have one, else ad hoc.
# Either way the Keychain asks once per build for Claude Code-credentials.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development" && echo "Apple Development" || echo "-")

.PHONY: build install run demo screenshots icon zip clean

build:
	mkdir -p "$(APP)/Contents/MacOS" build/obj
	mkdir -p "$(APP)/Contents/Resources"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	xcrun swiftc -O -target arm64-$(TARGET) -o build/obj/ClaudeUsage-arm64 $(SOURCES)
	xcrun swiftc -O -target x86_64-$(TARGET) -o build/obj/ClaudeUsage-x86_64 $(SOURCES)
	lipo -create -output "$(BIN)" build/obj/ClaudeUsage-arm64 build/obj/ClaudeUsage-x86_64
	codesign --force --options runtime --sign "$(SIGN_ID)" "$(APP)"

install: build
	-pkill -x ClaudeUsage
	rm -rf "$(DEST)"
	ditto "$(APP)" "$(DEST)"
	# Re-register so Finder and Spotlight drop a cached icon.
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(DEST)"
	open "$(DEST)"

run: build
	-pkill -x ClaudeUsage
	open "$(APP)"

# Fake data, no Keychain access, panel open on launch.
demo: build
	-pkill -x ClaudeUsage
	open "$(APP)" --args -demo YES

screenshots: build
	mkdir -p docs
	"$(BIN)" -snapshot "$(CURDIR)/docs/panel-dark.png" -appearance dark
	"$(BIN)" -snapshot "$(CURDIR)/docs/panel-light.png" -appearance light

# Re-render the app icon from scripts/make-icon.swift.
icon:
	mkdir -p build/AppIcon.iconset Resources
	xcrun swift scripts/make-icon.swift docs/icon.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s docs/icon.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) docs/icon.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

zip:
	$(MAKE) build SIGN_ID=-
	cd build && ditto -c -k --keepParent "Claude Usage.app" ClaudeUsage.zip

clean:
	rm -rf build
