# hkprobe — does Cmd+Tab reach us after the system app switcher is disabled?
#
# Separate bundle from axprobe on purpose: axprobe promises never to mutate
# anything, and this tool flips WindowServer hotkey state. Same stable signing
# identity, its own bundle id, its own Accessibility row.
#
# The hotkey state lives in WindowServer and is not persisted, and ANY process
# can re-enable it — `make restore` recovers even if a run died mid-way.

SHELL      := /bin/bash
HERE       := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
NAME       := HKProbe
BUNDLE_ID  := com.paulwu.opentab.hkprobe
IDENTITY   := OpenTab Dev Signing
BUILD      := $(HERE)/build
APP        := $(BUILD)/$(NAME).app
INSTALLED  := $(HOME)/Applications/$(NAME).app
OUT        := $(HERE)/out
SOURCES    := $(wildcard $(HERE)/Sources/*.swift)

SWIFTFLAGS := -swift-version 6 -strict-concurrency=complete -O \
              -target arm64-apple-macos14.0 \
              -framework AppKit -framework Carbon -framework ApplicationServices

.PHONY: all build sign install status run restore reset-perms clean help

all: install

help:
	@echo "make install   Build, sign, copy to ~/Applications"
	@echo "make status    Trust state + current symbolic hotkey state (read-only)"
	@echo "make run       The experiment (~30s, needs a human at the keyboard)"
	@echo "make restore   Re-enable Cmd+Tab / Cmd+Shift+Tab from a fresh process"

$(HERE)/.cert-stamp:
	@bash "$(HERE)/../axprobe/Scripts/make-signing-cert.sh" "$(IDENTITY)"
	@touch "$@"

build: $(HERE)/.cert-stamp $(SOURCES) $(HERE)/Support/Info.plist
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS"
	@cp "$(HERE)/Support/Info.plist" "$(APP)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	swiftc $(SWIFTFLAGS) $(SOURCES) -o "$(APP)/Contents/MacOS/hkprobe"
	@$(MAKE) --no-print-directory sign
	@echo "Built $(APP)"

sign:
	@codesign --force --sign "$(IDENTITY)" --identifier "$(BUNDLE_ID)" \
		--options runtime --timestamp=none "$(APP)"
	@codesign --verify --strict --verbose=1 "$(APP)"
	@echo -n "designated requirement: "
	@codesign -d -r- "$(APP)" 2>/dev/null | sed 's/^designated => //'

install: build
	@mkdir -p "$(HOME)/Applications"
	@rm -rf "$(INSTALLED)"
	@cp -R "$(APP)" "$(INSTALLED)"
	@echo "Installed $(INSTALLED)"

define run
	@mkdir -p "$(OUT)"
	@rm -f "$(OUT)/$(1).txt"
	@open -n -W -a "$(INSTALLED)" --args $(1) --out "$(OUT)" || true
	@cat "$(OUT)/$(1).txt" 2>/dev/null || echo "no output written"
endef

status:
	$(call run,status)

run:
	$(call run,run)

restore:
	$(call run,restore)

reset-perms:
	tccutil reset Accessibility $(BUNDLE_ID)

clean:
	rm -rf "$(BUILD)" "$(OUT)" "$(HERE)/.cert-stamp"
