APP       := Crumb
VERSION   := 1.2.0
BUILD     := build
BUNDLE    := $(BUILD)/$(APP).app
BINARY    := $(BUNDLE)/Contents/MacOS/$(APP)
PREFIX    ?= /Applications

# The GitHub repository that updates come from ("owner/name"), taken from the clone's origin.
REPOSITORY ?= $(shell git remote get-url origin 2>/dev/null | sed -E 's,^(git@github\.com:|https://github\.com/),,; s,\.git$$,,')

CXX       := clang++
MIN_MACOS := 27.0
TARGET    := -arch arm64 -mmacosx-version-min=$(MIN_MACOS)

CORE_SRC  := $(wildcard src/core/*.cpp)
APP_SRC   := $(wildcard src/app/*.mm)
CORE_OBJ  := $(CORE_SRC:src/%.cpp=$(BUILD)/obj/%.o)
APP_OBJ   := $(APP_SRC:src/%.mm=$(BUILD)/obj/%.o)

CXXFLAGS  += $(TARGET) -std=c++20 -Oz -flto -Wall -Wextra -Wshadow -Wno-unused-parameter -fvisibility=hidden -MMD -MP
OBJCFLAGS := -fobjc-arc
LDFLAGS   += $(TARGET) -dead_strip -flto
LIBS      := -framework AppKit -framework Carbon -framework ServiceManagement -framework ImageIO -framework QuartzCore \
             -framework CoreText -framework Security -framework IOSurface

ICON      := resources/$(APP).icns
RESOURCES := $(BUNDLE)/Contents/Info.plist $(if $(wildcard $(ICON)),$(BUNDLE)/Contents/Resources/$(APP).icns)

.PHONY: all app run test install uninstall icon clean

all: app

app: $(BUILD)/.signed

# Ad-hoc sign whenever something in the bundle changed.
$(BUILD)/.signed: $(BINARY) $(RESOURCES)
	@codesign --force --sign - $(BUNDLE)
	@touch $@
	@echo "Built $(BUNDLE) ($$(du -sh $(BUNDLE) | cut -f1))"

$(BINARY): $(CORE_OBJ) $(APP_OBJ)
	@mkdir -p $(@D)
	$(CXX) $(LDFLAGS) $^ -o $@ $(LIBS)
	@strip -x $@

$(BUNDLE)/Contents/Info.plist: resources/Info.plist Makefile
	@mkdir -p $(@D)
	@sed -e 's/__VERSION__/$(VERSION)/g' -e 's#__REPOSITORY__#$(REPOSITORY)#g' $< > $@

$(BUNDLE)/Contents/Resources/$(APP).icns: $(ICON)
	@mkdir -p $(@D)
	@cp $< $@

$(BUILD)/obj/%.o: src/%.cpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/obj/%.o: src/%.mm
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $(OBJCFLAGS) -c $< -o $@

# Unit tests for the core (history store, fuzzy search, text helpers).
test: $(BUILD)/tests
	@$(BUILD)/tests

$(BUILD)/tests: tests/core_tests.cpp $(CORE_SRC) src/core/*.hpp
	@mkdir -p $(@D)
	$(CXX) -std=c++20 -O1 -g -Wall -Wextra -fsanitize=address,undefined tests/core_tests.cpp $(CORE_SRC) -o $@

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

icon: tools/icon.cpp
	@mkdir -p $(BUILD)/icon.iconset
	$(CXX) -std=c++20 -O2 $< -o $(BUILD)/icon -framework CoreGraphics -framework ImageIO -framework CoreFoundation
	@$(BUILD)/icon $(BUILD)/icon.iconset
	@iconutil -c icns $(BUILD)/icon.iconset -o $(ICON)
	@echo "Wrote $(ICON)"

clean:
	rm -rf $(BUILD)

-include $(CORE_OBJ:.o=.d) $(APP_OBJ:.o=.d)
