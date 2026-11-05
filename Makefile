# Remind build entry points.
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Remind.app

# Where crash tests keep their vaults. Everything is removed afterward.
TORTURE_DIR ?= build/torture

.PHONY: core project app test test-rust test-swift self-check torture clean

core:
	scripts/build-core.sh debug

project: core
	xcodegen generate --quiet

app: project
	xcodebuild -project Remind.xcodeproj -scheme Remind -configuration Debug \
		-derivedDataPath $(DERIVED) -quiet build

test: test-rust test-swift

test-rust:
	cd core && cargo test --workspace --quiet

test-swift: core
	swift test --package-path Packages/RemindKit --quiet

self-check: app
	$(APP)/Contents/MacOS/Remind --self-check

torture:
	scripts/torture.sh $(TORTURE_DIR)

clean:
	rm -rf build core/target Packages/RemindKit/.build Packages/RemindKit/Frameworks \
		Packages/RemindKit/Sources/CoreABI/Generated Remind.xcodeproj
