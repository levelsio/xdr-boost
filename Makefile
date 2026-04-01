PREFIX ?= /usr/local
BINARY = xdr-boost
BUILD_DIR = .build
DIST_DIR = dist

.PHONY: build app dmg release install-local install uninstall clean launch-agent remove-agent

build:
	@./scripts/build-local

app:
	@VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" ARCHS="$(ARCHS)" BUILD_DIR="$(PWD)/$(BUILD_DIR)" DIST_DIR="$(PWD)/$(DIST_DIR)" ./scripts/package-app

dmg:
	@VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" ARCHS="$(ARCHS)" BUILD_DIR="$(PWD)/$(BUILD_DIR)" DIST_DIR="$(PWD)/$(DIST_DIR)" ./scripts/package-dmg

release:
	@VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" ARCHS="$(ARCHS)" NOTARY_PROFILE="$(NOTARY_PROFILE)" BUILD_ROOT="$(PWD)/build/release/direct" ./scripts/release-direct.sh

install-local:
	@VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" ARCHS="$(ARCHS)" BUILD_DIR="$(PWD)/$(BUILD_DIR)" DIST_DIR="$(PWD)/$(DIST_DIR)" ./scripts/install-local

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
	rm -rf $(BUILD_DIR) $(DIST_DIR) build
