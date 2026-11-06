# Elodie build entry points.
DERIVED := build/Elodie
APP := $(DERIVED)/Build/Products/Debug/Elodie.app

# Where crash tests keep their vaults. Everything is removed afterward.
TORTURE_DIR ?= build/torture

.PHONY: core project app filming-app test test-rust test-swift self-check torture check-privacy scenarios bench interaction-test release distribute app-store app-store-screenshots clean

core:
	scripts/build-core.sh debug

project: core
	xcodegen generate --quiet

app: project
	xcodebuild -project Elodie.xcodeproj -scheme Elodie -configuration Debug \
		-derivedDataPath $(DERIVED) -quiet build

# A development build whose timeline other apps can capture, for filming Elodie.
filming-app: project
	xcodebuild -project Elodie.xcodeproj -scheme "Elodie Filming" -configuration FilmingDebug \
		-derivedDataPath $(DERIVED) -quiet build

test: test-rust test-swift check-privacy

test-rust:
	cd core && cargo test --workspace --no-fail-fast --quiet

test-swift: core
	swift test --package-path Packages/ElodieKit --quiet

self-check: app
	$(APP)/Contents/MacOS/Elodie --self-check

torture:
	scripts/torture.sh $(TORTURE_DIR)

# Draws every screen, and checks that controls stay readable on hard backdrops. This takes
# no focus and no permission, and the images land in build/scenarios.
scenarios: app
	scripts/scenarios.sh

# Measures scrubbing against the plan's budgets on an encoded fixture.
bench: app
	@mkdir -p build
	@rm -f build/bench.txt build/bench.txt.error
	@open -n "$(PWD)/$(APP)" --args --scenario bench --out "$(PWD)/build/bench.txt"
	@for i in $$(seq 1 480); do [ -f build/bench.txt ] || [ -f build/bench.txt.error ] && break; sleep 0.5; done
	@cat build/bench.txt build/bench.txt.error 2>/dev/null; echo

# Real events through the real overlay. It takes over the screen and keyboard for a few
# seconds, so it asks first.
interaction-test: app
	scripts/interaction-test.sh

# Everything Elodie promises about the network and cloud services, checked against the code.
check-privacy: core
	scripts/check-privacy.sh

# Builds a signed release and a disk image. It doesn't upload anything.
release:
	scripts/release.sh

# Builds a notarized zip that opens on any Mac. This sends the build to Apple to notarize.
distribute:
	scripts/release.sh --distribute

# Builds the sandboxed App Store edition and checks it. It doesn't upload anything.
app-store:
	scripts/app-store.sh

# Renders the App Store listing's screenshots into docs/app-store/screenshots.
app-store-screenshots: app
	scripts/app-store-screenshots.sh

clean:
	rm -rf build core/target Packages/ElodieKit/.build Packages/ElodieKit/Frameworks \
		Packages/ElodieKit/Sources/CoreABI/Generated Elodie.xcodeproj
