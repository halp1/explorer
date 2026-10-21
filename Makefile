# Explorer build. Uses SwiftPM only (no Xcode project); bundles the .app by hand.
SWIFT_FLAGS := --disable-sandbox --cache-path $(CURDIR)/.build/spmcache
CONFIG ?= debug
ARCHS ?= arm64
APP := build/Explorer.app
SIGN_ID ?= -
BIN = $(shell swift build $(SWIFT_FLAGS) -c $(CONFIG) --show-bin-path)

.PHONY: all build app run test clean icon

all: app

build:
	swift build $(SWIFT_FLAGS) -c $(CONFIG) --product Explorer
	swift build $(SWIFT_FLAGS) -c $(CONFIG) --product ExplorerHelper

icon: build/AppIcon.icns

build/AppIcon.icns: scripts/make-icon.swift
	@mkdir -p build/AppIcon.iconset
	swift scripts/make-icon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o $@

app: build icon
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Library/LaunchDaemons
	cp $(BIN)/Explorer $(APP)/Contents/MacOS/Explorer
	cp $(BIN)/ExplorerHelper $(APP)/Contents/MacOS/com.halp.explorer.Helper
	cp Support/Explorer-Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	cp Support/com.halp.explorer.Helper.plist $(APP)/Contents/Library/LaunchDaemons/
	cp Resources/explorer Resources/Explorer.sdef build/AppIcon.icns $(APP)/Contents/Resources/
	cp -R Resources/en.lproj $(APP)/Contents/Resources/ 2>/dev/null || true
	chmod +x $(APP)/Contents/Resources/explorer
	@# Copy any SwiftPM resource bundles
	@for b in $(BIN)/*.bundle; do [ -e "$$b" ] && cp -R "$$b" $(APP)/Contents/Resources/ || true; done
	codesign --force --options runtime --sign "$(SIGN_ID)" --identifier com.halp.explorer.Helper $(APP)/Contents/MacOS/com.halp.explorer.Helper
	codesign --force --options runtime --sign "$(SIGN_ID)" --entitlements Support/Explorer.entitlements $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

test:
	swift test $(SWIFT_FLAGS)

clean:
	rm -rf .build build
