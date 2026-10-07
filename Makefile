# Portree build driver.
# Why this file exists (see DESIGN.md §8):
#  - The default MacOSX27 SDK makes @State a macro whose plugin ships only with
#    Xcode; builds work CLT-only against the 26 SDK, so SDKROOT is pinned.
#  - swift-testing's macro plugin must be loaded explicitly under CLT.
#  - The user's fish init is broken; recipes run under /bin/bash with /usr/bin/swift.

SHELL := /bin/bash
SDK := /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
SWIFT := /usr/bin/swift
TESTING_PLUGIN := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
TESTFLAGS := -Xswiftc -load-plugin-library -Xswiftc $(TESTING_PLUGIN)

.PHONY: build run test release app icon clean sdkcheck

icon:
	SDKROOT=$(SDK) $(SWIFT) scripts/make-icon.swift
	rm -rf assets/AppIcon.iconset && mkdir -p assets/AppIcon.iconset
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s assets/icon_1024.png --out assets/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  sips -z $$((s*2)) $$((s*2)) assets/icon_1024.png --out assets/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
	rm -rf assets/AppIcon.iconset
	@echo "assets/AppIcon.icns ready"

build: sdkcheck
	SDKROOT=$(SDK) $(SWIFT) build

run: sdkcheck
	SDKROOT=$(SDK) $(SWIFT) run

test: sdkcheck
	SDKROOT=$(SDK) $(SWIFT) test $(TESTFLAGS)

release: sdkcheck
	SDKROOT=$(SDK) $(SWIFT) build -c release

app: release
	scripts/make-app.sh "$$(SDKROOT=$(SDK) $(SWIFT) build -c release --show-bin-path)"

clean:
	rm -rf .build dist

sdkcheck:
	@test -d $(SDK) || { echo "error: $(SDK) missing — see DESIGN.md §8 for fallbacks (26.5 SDK / attribute-free State / install Xcode)"; exit 1; }
