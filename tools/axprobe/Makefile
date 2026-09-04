# axprobe — Accessibility tree probe for OpenTab.
#
# Two rules make this file what it is:
#   1. Sign with a STABLE self-signed identity, never ad-hoc. An ad-hoc
#      designated requirement is a bare cdhash, so the TCC grant breaks on the
#      next rebuild and the permission has to be granted again.
#   2. Never run the binary directly. A binary launched from a granted terminal
#      inherits that terminal's Accessibility grant and reports a false
#      positive. Every run below goes through `open -n -W -a`.

SHELL      := /bin/bash
HERE       := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
NAME       := AXProbe
BUNDLE_ID  := im.opentab.tools.axprobe
IDENTITY   := OpenTab Dev Signing
BUILD      := $(HERE)/build
APP        := $(BUILD)/$(NAME).app
INSTALLED  := $(HOME)/Applications/$(NAME).app
OUT        := $(HERE)/out
SOURCES    := $(wildcard $(HERE)/Sources/*.swift)

# macOS 14.0 is the deployment target; Swift 6 language mode with complete
# concurrency checking. -c/-o (not -typecheck) because region-based isolation is
# a SIL pass and only runs during real code generation.
SWIFTFLAGS := -swift-version 6 -strict-concurrency=complete -O \
              -target arm64-apple-macos14.0 \
              -framework AppKit -framework ApplicationServices -framework Security

.PHONY: all build sign install doctor list spaces token spacemap selftest dumps reset-perms clean help

all: install

help:
	@echo "make build        Compile and sign $(NAME).app into build/"
	@echo "make install      Copy the app to ~/Applications (needed for tccutil)"
	@echo "make doctor       Ask the installed app whether it holds the grant"
	@echo "make list         List running apps and their window counts"
	@echo "make spaces       Compare AX-reachable windows against the WindowServer"
	@echo "make token PID=<pid> WID=<id[,id]>  Strategy C: reach windows via remote token"
	@echo "make spacemap WID=<id[,id]>         CGS Space attribution for the given windows"
	@echo "make dumps        Dump every target app that is currently running"
	@echo "make dump APP=<bundle-id|name>   Dump one app"
	@echo "make tabs APP=<bundle-id|name>   Probe one app for tab elements"
	@echo "make selftest     Verify the walker's depth/breadth/budget caps"
	@echo "make reset-perms  Revoke the Accessibility grant to retest onboarding"
	@echo "make clean        Remove build/ and out/"

## Create the stable signing identity if it does not exist yet (idempotent).
$(HERE)/.cert-stamp:
	@bash "$(HERE)/Scripts/make-signing-cert.sh" "$(IDENTITY)"
	@touch "$@"

## Compile, assemble the bundle, and sign it.
build: $(HERE)/.cert-stamp $(SOURCES) $(HERE)/Support/Info.plist
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS"
	@cp "$(HERE)/Support/Info.plist" "$(APP)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	swiftc $(SWIFTFLAGS) $(SOURCES) -o "$(APP)/Contents/MacOS/axprobe"
	@$(MAKE) --no-print-directory sign
	@echo "Built $(APP)"

## Sign with the stable identity and print the designated requirement, which is
## the thing TCC actually keys the grant on.
sign:
	@codesign --force --sign "$(IDENTITY)" --identifier "$(BUNDLE_ID)" \
		--options runtime --timestamp=none "$(APP)"
	@codesign --verify --strict --verbose=1 "$(APP)"
	@echo -n "designated requirement: "
	@codesign -d -r- "$(APP)" 2>/dev/null | sed 's/^designated => //'

## tccutil resolves a bundle id through LaunchServices, and LaunchServices will
## not resolve one under build/ or /tmp. ~/Applications is why this step exists.
install: build
	@mkdir -p "$(HOME)/Applications"
	@rm -rf "$(INSTALLED)"
	@cp -R "$(APP)" "$(INSTALLED)"
	@echo "Installed $(INSTALLED)"
	@codesign -d -r- "$(INSTALLED)" 2>/dev/null | sed 's/^designated => /installed DR: /'

# $(1) = command name for the output file, $(2) = arguments
define run
	@mkdir -p "$(OUT)"
	@rm -f "$(OUT)/error.txt" "$(OUT)/error.json"
	@open -n -W -a "$(INSTALLED)" --args $(2) --out "$(OUT)" || true
	@if [ -f "$(OUT)/error.txt" ]; then cat "$(OUT)/error.txt"; exit 1; fi
	@cat "$(OUT)/$(1).txt"
endef

doctor:
	$(call run,doctor,doctor)

list:
	$(call run,list,list)

spaces:
	$(call run,spaces,spaces)

selftest:
	$(call run,selftest,selftest)

## Strategy C. One process per invocation so a bad token segfaults one run, not
## the batch. PID selects the process, WID the comma-separated CGWindowIDs to reach.
PID ?=
WID ?=
token:
	@test -n "$(PID)" || { echo "usage: make token PID=<pid> WID=<id[,id]>"; exit 2; }
	@mkdir -p "$(OUT)"
	@open -n -W -a "$(INSTALLED)" --args token --pid "$(PID)" --wid "$(WID)" --out "$(OUT)" || true
	@cat "$(OUT)"/token-pid$(PID)*.txt 2>/dev/null || cat "$(OUT)/token-error.txt"

spacemap:
	@mkdir -p "$(OUT)"
	@open -n -W -a "$(INSTALLED)" --args spacemap --wid "$(WID)" --out "$(OUT)" || true
	@cat "$(OUT)/spacemap.txt" 2>/dev/null || cat "$(OUT)/spacemap-error.txt"

APP ?=
dump:
	@test -n "$(APP)" || { echo "usage: make dump APP=<bundle-id|name>"; exit 2; }
	@mkdir -p "$(OUT)"
	@open -n -W -a "$(INSTALLED)" --args dump "$(APP)" --values --out "$(OUT)" || true
	@cat "$(OUT)"/dump-*.txt

tabs:
	@test -n "$(APP)" || { echo "usage: make tabs APP=<bundle-id|name>"; exit 2; }
	@mkdir -p "$(OUT)"
	@open -n -W -a "$(INSTALLED)" --args tabs "$(APP)" --out "$(OUT)" || true
	@cat "$(OUT)"/tabs-*.txt

## Every app we care about for tab extraction. Missing apps are skipped.
TARGETS := com.todesktop.230313mzl4w4u92 com.microsoft.VSCode com.apple.dt.Xcode \
           com.apple.finder com.apple.Preview com.apple.Terminal notion.id \
           com.figma.Desktop com.apple.Safari com.google.Chrome \
           org.mozilla.firefox company.thebrowser.Browser

dumps:
	@mkdir -p "$(OUT)"
	@for id in $(TARGETS); do \
		rm -f "$(OUT)/error.txt" "$(OUT)/error.json"; \
		open -n -W -a "$(INSTALLED)" --args dump "$$id" --values --exact --out "$(OUT)" >/dev/null 2>&1 || true; \
		if [ -f "$(OUT)/error.txt" ]; then echo "  skipped $$id (not running)"; continue; fi; \
		open -n -W -a "$(INSTALLED)" --args tabs "$$id" --exact --out "$(OUT)" >/dev/null 2>&1 || true; \
		echo "  probed  $$id"; \
	done
	@rm -f "$(OUT)/error.txt" "$(OUT)/error.json"
	@echo "Wrote $$(ls -1 "$(OUT)"/*.json 2>/dev/null | wc -l | tr -d ' ') JSON files to $(OUT)"

## Revoke the grant to retest first-run onboarding. No sudo needed.
reset-perms:
	tccutil reset Accessibility $(BUNDLE_ID)

clean:
	rm -rf "$(BUILD)" "$(OUT)" "$(HERE)/.cert-stamp"
