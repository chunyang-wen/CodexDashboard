PROJECT ?= CodexDashboard.xcodeproj
SCHEME ?= CodexDashboard
APP_NAME ?= CodexDashboard
APPCAST_DIR ?= docs
DOWNLOAD_URL_PREFIX ?= https://github.com/chunyang-wen/CodexDashboard/releases/download
SPARKLE_BIN ?= $(HOME)/.developer/SparkleBin/bin
VERSION ?= $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | grep -w MARKETING_VERSION | head -n 1 | awk '{print $$3}')
XCODEBUILD_EXTRA_ARGS ?=

.PHONY: all build build-release archive appcast release clean

all: build

build:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath build/DerivedData \
		$(XCODEBUILD_EXTRA_ARGS) \
		build

build-release:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath build/DerivedData \
		$(XCODEBUILD_EXTRA_ARGS) \
		build

archive: build-release
	@if [ -z "$(VERSION)" ]; then echo "Error: Failed to determine MARKETING_VERSION"; exit 1; fi
	@echo "Packaging $(APP_NAME) version $(VERSION)..."
	@mkdir -p build
	ditto -c -k --keepParent build/DerivedData/Build/Products/Release/$(APP_NAME).app build/$(APP_NAME)-$(VERSION).zip
	@/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' build/DerivedData/Build/Products/Release/$(APP_NAME).app/Contents/Info.plist >/dev/null || \
		(echo "Error: SUPublicEDKey is missing from the built app Info.plist"; exit 1)
	@echo "Created archive: build/$(APP_NAME)-$(VERSION).zip"

appcast:
	@if [ -z "$(VERSION)" ]; then echo "Error: Failed to determine MARKETING_VERSION"; exit 1; fi
	@if [ ! -f "build/$(APP_NAME)-$(VERSION).zip" ]; then \
		echo "Error: Archive build/$(APP_NAME)-$(VERSION).zip not found. Run 'make archive' first."; \
		exit 1; \
	fi
	@mkdir -p $(APPCAST_DIR)
	@echo "Staging zip for appcast generation..."
	cp build/$(APP_NAME)-$(VERSION).zip $(APPCAST_DIR)/$(APP_NAME)-$(VERSION).zip
	@echo "Generating appcast in $(APPCAST_DIR)..."
	@if [ -n "$${SPARKLE_ED_KEY:-}" ]; then \
		printf '%s' "$${SPARKLE_ED_KEY}" | $(SPARKLE_BIN)/generate_appcast \
			--ed-key-file - \
			--download-url-prefix $(DOWNLOAD_URL_PREFIX)/v$(VERSION)/ \
			$(APPCAST_DIR); \
	else \
		$(SPARKLE_BIN)/generate_appcast \
			--download-url-prefix $(DOWNLOAD_URL_PREFIX)/v$(VERSION)/ \
			$(APPCAST_DIR); \
	fi
	@echo "Removing temporary zip from $(APPCAST_DIR)..."
	rm -f $(APPCAST_DIR)/$(APP_NAME)-$(VERSION).zip
	@enclosures=$$(grep -c '<enclosure ' $(APPCAST_DIR)/appcast.xml || true); \
	 signatures=$$(grep -o 'sparkle:edSignature=' $(APPCAST_DIR)/appcast.xml | wc -l | tr -d ' '); \
	 if [ "$$enclosures" -gt 0 ] && [ "$$enclosures" -eq "$$signatures" ]; then \
		echo "✅ Appcast generated with an EdDSA signature on every enclosure"; \
	 else \
		echo "⚠️ Appcast signature check failed: enclosures=$$enclosures signatures=$$signatures"; \
		exit 1; \
	 fi

release: archive appcast
	@echo "🚀 Release build, archive, and signed appcast complete!"

clean:
	rm -rf build
