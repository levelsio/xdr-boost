PREFIX ?= /usr/local
BINARY = xdr-boost
BUILD_DIR = .build
MACOS_MIN = 12.0

.PHONY: build install uninstall clean launch-agent remove-agent

build:
	@mkdir -p $(BUILD_DIR)
	swiftc -O -target $(shell uname -m)-apple-macos$(MACOS_MIN) -o $(BUILD_DIR)/$(BINARY) Sources/*.swift \
		-framework Cocoa -framework MetalKit -framework Metal -framework SwiftUI -framework IOKit

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
