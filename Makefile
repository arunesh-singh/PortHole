# Developer entry points. See docs/DEVELOPMENT.md.
#
#   make run       build (Debug, ad-hoc signed) and launch PortHole
#   make cli       build the `porthole` command-line tool
#   make dmg       universal ad-hoc DMG in build/release/
#   make release   Developer ID signed + notarized DMG (needs Apple credentials)

DERIVED := build/dd
DEBUG_APP := $(DERIVED)/Build/Products/Debug/PortHole.app
ADHOC := CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=

.PHONY: deps project build run cli dmg release clean

deps: Vendor/lib/libmtp.a

Vendor/lib/libmtp.a:
	scripts/build-deps.sh

project: deps
	xcodegen generate --quiet

build: project
	xcodebuild build -project PortHole.xcodeproj -scheme PortHole -configuration Debug \
		-derivedDataPath $(DERIVED) $(ADHOC) -quiet

run: build
	-osascript -e 'quit app "PortHole"' 2>/dev/null
	@sleep 2
	open $(DEBUG_APP)

cli: project
	xcodebuild build -project PortHole.xcodeproj -scheme porthole -configuration Debug \
		-derivedDataPath $(DERIVED) $(ADHOC) -quiet
	@echo "built $(DERIVED)/Build/Products/Debug/porthole"

dmg: deps
	scripts/release.sh --adhoc

release: deps
	scripts/release.sh

clean:
	rm -rf build PortHole.xcodeproj
