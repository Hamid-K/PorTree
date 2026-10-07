# PorTree build driver. Works in two environments:
#  - CLT-only Macs (no Xcode): pins SDKROOT to the MacOSX26 SDK (the 27 SDK's
#    @State macro plugin ships only with Xcode) and loads swift-testing's
#    macro plugin explicitly. See DESIGN.md §8.
#  - Machines/CI runners with full Xcode (incl. GitHub macos-* arm64 runners):
#    no pin needed; plain toolchain paths work.

SHELL := /bin/bash
SWIFT := /usr/bin/swift
CLT_SDK := /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
SDKPIN := $(if $(wildcard $(CLT_SDK)),SDKROOT=$(CLT_SDK),)
TESTING_PLUGIN := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
TESTFLAGS := $(if $(wildcard $(TESTING_PLUGIN)),-Xswiftc -load-plugin-library -Xswiftc $(TESTING_PLUGIN),)

.PHONY: build run test release app icon clean

build:
	$(SDKPIN) $(SWIFT) build

run:
	$(SDKPIN) $(SWIFT) run

test:
	$(SDKPIN) $(SWIFT) test $(TESTFLAGS)

release:
	$(SDKPIN) $(SWIFT) build -c release

app: release
	scripts/make-app.sh "$$($(SDKPIN) $(SWIFT) build -c release --show-bin-path)"

icon:
	$(SDKPIN) $(SWIFT) scripts/make-icon.swift
	rm -rf assets/AppIcon.iconset && mkdir -p assets/AppIcon.iconset
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s assets/icon_1024.png --out assets/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  sips -z $$((s*2)) $$((s*2)) assets/icon_1024.png --out assets/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
	rm -rf assets/AppIcon.iconset
	@echo "assets/AppIcon.icns ready"

clean:
	rm -rf .build dist
