# Remind build entry points.
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Remind.app

# Where crash tests keep their vaults. Everything is removed afterward.
TORTURE_DIR ?= build/torture

.PHONY: core project app test test-rust test-swift self-check torture check-privacy scenarios bench interaction-test release clean

core:
	scripts/build-core.sh debug

project: core
	xcodegen generate --quiet

app: project
	xcodebuild -project Remind.xcodeproj -scheme Remind -configuration Debug \
		-derivedDataPath $(DERIVED) -quiet build

test: test-rust test-swift check-privacy

test-rust:
	cd core && cargo test --workspace --no-fail-fast --quiet

test-swift: core
	swift test --package-path Packages/RemindKit --quiet

self-check: app
	$(APP)/Contents/MacOS/Remind --self-check

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

# Everything Remind promises about the network and cloud services, checked against the code.
check-privacy: core
	scripts/check-privacy.sh

# Builds a signed release and a disk image. It doesn't upload anything.
release:
	scripts/release.sh

clean:
	rm -rf build core/target Packages/RemindKit/.build Packages/RemindKit/Frameworks \
		Packages/RemindKit/Sources/CoreABI/Generated Remind.xcodeproj
