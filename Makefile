PREFIX ?= /usr/local
BINARY = xdr-boost
BUILD_DIR = .build
APP_DIR = $(BUILD_DIR)/XDR Boost.app
CODE_SIGN_IDENTITY ?= -
ARCH ?= $(shell uname -m)
SWIFT_TARGET ?= $(ARCH)-apple-macos12.0

.PHONY: build app dmg install uninstall clean launch-agent remove-agent

build:
	@mkdir -p $(BUILD_DIR)
	swiftc -target $(SWIFT_TARGET) -O -o $(BUILD_DIR)/$(BINARY) Sources/main.swift Sources/GammaTable.swift \
		-framework Cocoa -framework MetalKit -framework Metal

app: build
	@mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_DIR)/$(BINARY)" "$(APP_DIR)/Contents/MacOS/$(BINARY)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	swiftc -o "$(BUILD_DIR)/make-icon" Scripts/make-icon.swift -framework AppKit
	"$(BUILD_DIR)/make-icon" "$(BUILD_DIR)/AppIcon.iconset"
	iconutil -c icns "$(BUILD_DIR)/AppIcon.iconset" -o "$(APP_DIR)/Contents/Resources/AppIcon.icns"
	cp LICENSE "$(APP_DIR)/Contents/Resources/LICENSE"
	cp Resources/INSTALL.txt "$(BUILD_DIR)/INSTALL.txt"
	codesign --force --sign "$(CODE_SIGN_IDENTITY)" "$(APP_DIR)"

dmg: app
	sh Scripts/package-dmg.sh "$(BUILD_DIR)"

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BUILD_DIR)/$(BINARY) $(PREFIX)/bin/$(BINARY)

uninstall: remove-agent
	rm -f $(PREFIX)/bin/$(BINARY)

# Install LaunchAgent to start on login
launch-agent: install
	@mkdir -p ~/Library/LaunchAgents
	@sed "s|__BINARY__|$(PREFIX)/bin/$(BINARY)|g" \
		com.xdr-boost.agent.plist > ~/Library/LaunchAgents/com.xdr-boost.agent.plist
	launchctl load ~/Library/LaunchAgents/com.xdr-boost.agent.plist
	@echo "xdr-boost will now start on login"

remove-agent:
	-launchctl unload ~/Library/LaunchAgents/com.xdr-boost.agent.plist 2>/dev/null
	rm -f ~/Library/LaunchAgents/com.xdr-boost.agent.plist

clean:
	rm -rf $(BUILD_DIR)
