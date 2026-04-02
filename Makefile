PREFIX ?= /usr/local
BINARY = xdr-boost
BUILD_DIR = .build

APP_NAME = XDR Boost
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build install uninstall clean launch-agent remove-agent app dmg

build:
	@mkdir -p $(BUILD_DIR)
	swiftc -O -o $(BUILD_DIR)/$(BINARY) Sources/main.swift \
		-framework Cocoa -framework MetalKit -framework Metal

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

app: build
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp $(BUILD_DIR)/$(BINARY) "$(APP_BUNDLE)/Contents/MacOS/$(BINARY)"
	@cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@cp AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@codesign --force --sign - "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

dmg: app
	@rm -rf "$(BUILD_DIR)/dmg"
	@mkdir -p "$(BUILD_DIR)/dmg"
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/dmg/"
	@ln -s /Applications "$(BUILD_DIR)/dmg/Applications"
	@hdiutil create -volname "XDR Boost" -srcfolder "$(BUILD_DIR)/dmg" \
		-ov -format UDZO "$(BUILD_DIR)/XDR-Boost.dmg"
	@rm -rf "$(BUILD_DIR)/dmg"
	@echo "Built $(BUILD_DIR)/XDR-Boost.dmg"

clean:
	rm -rf $(BUILD_DIR)
