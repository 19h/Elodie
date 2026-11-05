# Remind build entry points.
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Remind.app

# Where crash tests keep their vaults. Everything is removed afterward.
TORTURE_DIR ?= build/torture

.PHONY: core project app test test-rust test-swift self-check torture check-privacy release clean

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

# Everything Remind promises about the network and cloud services, checked against the code.
check-privacy: core
	scripts/check-privacy.sh

# Builds a signed release and a disk image. It doesn't upload anything.
release:
	scripts/release.sh

clean:
	rm -rf build core/target Packages/RemindKit/.build Packages/RemindKit/Frameworks \
		Packages/RemindKit/Sources/CoreABI/Generated Remind.xcodeproj
