# OpenTab build/run/test loop. Every target is non-interactive and agent-safe.
#
# Two rules this file exists to enforce:
#   1. The app is always signed with the stable "OpenTab Dev Signing" identity.
#      The identity is fixed in project.yml, so xcodebuild, Xcode and
#      `xcodebuild test` all produce the same designated requirement and the
#      Accessibility grant survives rebuilds.
#   2. The app is never executed directly. A binary launched from a granted
#      terminal inherits that terminal's TCC attribution and reports a false
#      positive; every launch below goes through `open -a`.
# macOS ships GNU Make 3.81, which has no .SHELLFLAGS: recipes that need
# pipefail set it inside the recipe line.
SHELL       := /bin/bash

HERE        := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
APP_NAME    := OpenTab
BUNDLE_ID   := im.opentab.app
SUBSYSTEM   := im.opentab.app
SIGN_CN     := OpenTab Dev Signing
CONFIG      ?= Debug
DERIVED     := $(HERE)/build/DerivedData
PRODUCT     := $(DERIVED)/Build/Products/$(CONFIG)/$(APP_NAME).app
# tccutil resolves bundle ids through LaunchServices, which will not resolve an
# app under build/ or /tmp. ~/Applications is why install exists.
INSTALL_DIR := $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(APP_NAME).app
OUT         := $(HERE)/build/out
# `log` is a shell builtin in some shells; always use the absolute path.
LOG         := /usr/bin/log
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

.PHONY: all project build test test-app run stop sign install logs logs-stream \
        reset-perms selftest clean help

all: build

help:
	@echo "make build        xcodegen generate + xcodebuild, print the designated requirement"
	@echo "make test         swift test (pure logic, no GUI, no permissions)"
	@echo "make test-app     xcodebuild test, app-hosted (needs a logged-in GUI session)"
	@echo "make install      Copy the built app to ~/Applications"
	@echo "make run          Kill the old instance, relaunch via open -a, show logs"
	@echo "make selftest     Launch the installed app in diagnostic mode; output in build/out/"
	@echo "make logs         Last 2 minutes of the app's unified log"
	@echo "make reset-perms  Revoke the Accessibility and Apple Events grants"
	@echo "make sign         Create the stable signing identity (idempotent)"

## Regenerate OpenTab.xcodeproj from project.yml. Run after adding files.
project:
	cd "$(HERE)" && xcodegen generate --quiet

## Fast unit tests: pure logic only, no GUI, no permissions, no Xcode.
## Without `pipefail` the grep filter would report a green run for a failing
## `swift test`.
test:
	cd "$(HERE)/Packages/OpenTabKit" && set -o pipefail && swift test 2>&1 \
	  | { grep -E "Test Case|Executed|error:|warning:|failed" || true; }

## Tests that need the real app bundle (Info.plist contract, self-process AX).
test-app: project
	@mkdir -p "$(HERE)/build"
	@cd "$(HERE)" && xcodebuild test -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) \
	  -configuration Debug -destination 'platform=macOS' \
	  -derivedDataPath "$(DERIVED)" > "$(HERE)/build/xcodebuild-test.log" 2>&1; status=$$?; \
	  grep -E "Test Case|Executed|error:|\*\* TEST" "$(HERE)/build/xcodebuild-test.log"; exit $$status
	@codesign -d -r- "$(DERIVED)/Build/Products/Debug/$(APP_NAME).app" 2>&1 | grep designated

## Create the stable signing identity (idempotent, safe to run every time).
sign: $(HERE)/.cert-stamp

$(HERE)/.cert-stamp:
	@bash "$(HERE)/Scripts/make-signing-cert.sh" "$(SIGN_CN)"
	@touch "$@"

## A failed compile must fail the target: a stale product would otherwise be
## installed and run, so the full log is kept and only summarised here.
build: project sign
	@mkdir -p "$(HERE)/build"
	@cd "$(HERE)" && if ! xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) \
	  -configuration $(CONFIG) -derivedDataPath "$(DERIVED)" \
	  build > "$(HERE)/build/xcodebuild.log" 2>&1; then \
	  grep -E "error:" "$(HERE)/build/xcodebuild.log" || tail -20 "$(HERE)/build/xcodebuild.log"; exit 1; fi
	@grep -E "warning:|\*\* BUILD" "$(HERE)/build/xcodebuild.log" | grep -v "Metadata extraction skipped" || true
	@codesign -d -r- "$(PRODUCT)" 2>&1 | grep designated

## Copy to ~/Applications so the bundle path (and thus the TCC row) is stable.
install: build
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED)"
	cp -R "$(PRODUCT)" "$(INSTALLED)"
	"$(LSREGISTER)" -f "$(INSTALLED)"
	@echo "installed -> $(INSTALLED)"
	@codesign -d -r- "$(INSTALLED)" 2>&1 | sed 's/^designated => /installed DR: /' | grep "installed DR"

stop:
	@pkill -x $(APP_NAME) 2>/dev/null && echo "stopped running instance" || true

## Kill the old instance, relaunch from ~/Applications, tail the logs.
run: install stop
	@open -a "$(INSTALLED)"
	@sleep 1
	@$(MAKE) --no-print-directory logs

## Diagnostic run. Enumeration timings, filter statistics and trust state are
## written to build/out/selftest.txt because an app launched via `open` has no
## stdout to print to.
selftest: install
	@mkdir -p "$(OUT)"
	@rm -f "$(OUT)/selftest.txt"
	@open -n -W -a "$(INSTALLED)" --args --selftest --out "$(OUT)" || true
	@cat "$(OUT)/selftest.txt" 2>/dev/null || echo "no output written"

logs:
	$(LOG) show --style compact --last 2m --predicate 'subsystem == "$(SUBSYSTEM)"'

## Follow logs live until interrupted.
logs-stream:
	$(LOG) stream --style compact --predicate 'subsystem == "$(SUBSYSTEM)"'

## Revoke the grants to test the first-run experience. Needs the app installed.
reset-perms:
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset AppleEvents $(BUNDLE_ID)

clean:
	rm -rf "$(HERE)/build" "$(HERE)/$(APP_NAME).xcodeproj"
	cd "$(HERE)/Packages/OpenTabKit" && rm -rf .build
