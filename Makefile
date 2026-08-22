PROJECT = CodexDashboard.xcodeproj
SCHEME = CodexDashboard
APP_NAME = CodexDashboard
APPCAST_DIR = docs
DOWNLOAD_URL_PREFIX = https://github.com/chunyang-wen/CodexDashboard/releases/download
SPARKLE_BIN = $(HOME)/.developer/SparkleBin/bin

.PHONY: all build build-release archive appcast release clean

all: build

build:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath build/DerivedData \
		build

build-release:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'platform=macOS,arch=arm64' \
		-derivedDataPath build/DerivedData \
		build

archive: build-release
	$(eval VERSION := $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | grep -w MARKETING_VERSION | head -n 1 | awk '{print $$3}'))
	@if [ -z "$(VERSION)" ]; then echo "Error: Failed to determine MARKETING_VERSION"; exit 1; fi
	@echo "Packaging $(APP_NAME) version $(VERSION)..."
	@mkdir -p build
	ditto -c -k --keepParent build/DerivedData/Build/Products/Release/$(APP_NAME).app build/$(APP_NAME)-$(VERSION).zip
	@echo "Created archive: build/$(APP_NAME)-$(VERSION).zip"

appcast:
	$(eval VERSION := $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null | grep -w MARKETING_VERSION | head -n 1 | awk '{print $$3}'))
	@if [ -z "$(VERSION)" ]; then echo "Error: Failed to determine MARKETING_VERSION"; exit 1; fi
	@if [ ! -f "build/$(APP_NAME)-$(VERSION).zip" ]; then \
		echo "Error: Archive build/$(APP_NAME)-$(VERSION).zip not found. Run 'make archive' first."; \
		exit 1; \
	fi
	@mkdir -p $(APPCAST_DIR)
	@echo "Staging zip for appcast generation..."
	cp build/$(APP_NAME)-$(VERSION).zip $(APPCAST_DIR)/$(APP_NAME)-$(VERSION).zip
	@echo "Generating appcast in $(APPCAST_DIR)..."
	$(SPARKLE_BIN)/generate_appcast \
		--download-url-prefix $(DOWNLOAD_URL_PREFIX)/v$(VERSION)/ \
		$(APPCAST_DIR)
	@echo "Removing temporary zip from $(APPCAST_DIR)..."
	rm -f $(APPCAST_DIR)/$(APP_NAME)-$(VERSION).zip
	@if grep -q "sparkle:edSignature" $(APPCAST_DIR)/appcast.xml; then \
		echo "✅ Appcast generated and verified with sparkle:edSignature in $(APPCAST_DIR)/appcast.xml"; \
	else \
		echo "⚠️ Warning: sparkle:edSignature missing from $(APPCAST_DIR)/appcast.xml"; \
		exit 1; \
	fi

release: archive appcast
	@echo "🚀 Release build, archive, and signed appcast complete!"

clean:
	rm -rf build
