APP       := Crumb
VERSION   := 2.0.1
BUILD     := build
BUNDLE    := $(BUILD)/$(APP).app
BINARY    := $(BUNDLE)/Contents/MacOS/$(APP)
DMG       := $(BUILD)/$(APP).dmg
PREFIX    ?= /Applications

# The GitHub repository that updates come from ("owner/name"), taken from the clone's origin.
REPOSITORY ?= $(shell git remote get-url origin 2>/dev/null | sed -E 's,^(git@github\.com:|https://github\.com/),,; s,\.git$$,,')

SWIFTC    := swiftc
MIN_MACOS := 27.0
TARGET    := -target arm64-apple-macos$(MIN_MACOS) -swift-version 6

CORE_SRC  := $(wildcard Sources/Core/*.swift)
APP_SRC   := $(wildcard Sources/App/*.swift)

# Small and fast: one optimized module, no reflection metadata, unused code stripped.
SWIFTFLAGS := $(TARGET) -Osize -wmo -Xfrontend -disable-reflection-metadata -Xlinker -dead_strip

# Code signing identity: "-" (ad hoc) for local builds. Releases are signed with the project's own certificate
# (SHA-1 below), so every version has the same designated requirement: macOS keeps Crumb's permissions across
# updates, and Homebrew sees the same signer when it upgrades the cask.
RELEASE_ID    := 81F65FC5A119EA54887FA776BB93DAB3F18BAE31
SIGN_ID       ?= -
SIGN_KEYCHAIN ?=
SIGN          := codesign --force --sign "$(SIGN_ID)" $(if $(SIGN_KEYCHAIN),--keychain "$(SIGN_KEYCHAIN)") --timestamp=none

ICON      := resources/$(APP).icns
RESOURCES := $(BUNDLE)/Contents/Info.plist $(if $(wildcard $(ICON)),$(BUNDLE)/Contents/Resources/$(APP).icns)

.PHONY: all app dmg release run test install uninstall icon clean

all: app

app: $(BUILD)/.signed

# Sign whenever something in the bundle changed.
$(BUILD)/.signed: $(BINARY) $(RESOURCES)
	@$(SIGN) $(BUNDLE)
	@touch $@
	@echo "Built $(BUNDLE) ($$(du -sh $(BUNDLE) | cut -f1))"

$(BINARY): $(CORE_SRC) $(APP_SRC)
	@mkdir -p $(@D)
	$(SWIFTC) $(SWIFTFLAGS) -module-name $(APP) $^ -o $@
	@strip -x $@

$(BUNDLE)/Contents/Info.plist: resources/Info.plist Makefile
	@mkdir -p $(@D)
	@sed -e 's/__VERSION__/$(VERSION)/g' -e 's#__REPOSITORY__#$(REPOSITORY)#g' $< > $@

$(BUNDLE)/Contents/Resources/$(APP).icns: $(ICON)
	@mkdir -p $(@D)
	@cp $< $@

# A disk image to drag Crumb into Applications from.
dmg: app
	@rm -rf $(BUILD)/dmg $(DMG)
	@mkdir -p $(BUILD)/dmg
	@ditto $(BUNDLE) $(BUILD)/dmg/$(APP).app
	@ln -s /Applications $(BUILD)/dmg/Applications
	@hdiutil create -quiet -volname $(APP) -srcfolder $(BUILD)/dmg -fs HFS+ -format ULMO -ov $(DMG)
	@rm -rf $(BUILD)/dmg
	@echo "Built $(DMG) ($$(du -sh $(DMG) | cut -f1))"

# Certificate-signed app and disk image for GitHub releases (see .github/workflows/release.yml).
release:
	@$(MAKE) clean
	@$(MAKE) dmg SIGN_ID="$(RELEASE_ID)" SIGN_KEYCHAIN="$(SIGN_KEYCHAIN)" VERSION="$(VERSION)" REPOSITORY="$(REPOSITORY)"
	@codesign --verify --deep --strict $(BUNDLE)
	@codesign -d -r- $(BUNDLE) 2>&1 | grep -q 'certificate leaf' || (echo "release is not certificate-signed" && false)
	@test "$$(lipo -archs $(BINARY))" = arm64 || (echo "release is not arm64 only" && false)
	@vtool -show-build $(BINARY) | grep -q "minos $(MIN_MACOS)" || (echo "release has the wrong minimum macOS" && false)

# Unit tests for the core (history store, fuzzy search, text helpers), with AddressSanitizer.
test: $(BUILD)/tests
	@$(BUILD)/tests

$(BUILD)/tests: $(CORE_SRC) tests/main.swift
	@mkdir -p $(@D)
	$(SWIFTC) $(TARGET) -Onone -g -sanitize=address -module-name CrumbTests $^ -o $@

run: app
	@pkill -x $(APP) || true
	@open $(BUNDLE)

install: app
	@pkill -x $(APP) || true
	@rm -rf "$(PREFIX)/$(APP).app"
	@ditto $(BUNDLE) "$(PREFIX)/$(APP).app"
	@open "$(PREFIX)/$(APP).app"
	@echo "Installed $(PREFIX)/$(APP).app"

uninstall:
	@pkill -x $(APP) || true
	@rm -rf "$(PREFIX)/$(APP).app"

icon: tools/icon.swift
	@mkdir -p $(BUILD)/icon.iconset
	$(SWIFTC) $(TARGET) -O $< -o $(BUILD)/icon
	@$(BUILD)/icon $(BUILD)/icon.iconset
	@iconutil -c icns $(BUILD)/icon.iconset -o $(ICON)
	@echo "Wrote $(ICON)"

clean:
	rm -rf $(BUILD)
