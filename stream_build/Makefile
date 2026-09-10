# Public API:
#   make build|test|package ios|android|macos|windows [VAR=value ...]
#   make combine
#   make rename apple|android
# GN overrides: CONFIG=debug GN_ARGS='key=value key2=value'
#
# From the git root:  cd stream_build && make build ios
# SKIP_DEPS=1 skips gclient sync only; gn/ninja still run.
# SKIP_LICENSES=1 skips license generation only; lipo/zip still run.
# SKIP_MACCATALYST=1 drops catalyst-* from ios build+package only.
# package ios/macos write PRODUCTS/ios and PRODUCTS/macos.
# make combine merges whatever PRODUCTS/*/WebRTC.xcframework exist.
# make rename copies WebRTC.xcframework / libwebrtc.aar to PRODUCTS/renamed/.

SHELL := /bin/bash
.SUFFIXES:

PIPELINE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS  := $(PIPELINE)scripts

CONFIG        ?= release
TARGET_OS     ?= ios
JOBS          ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)
SKIP_DEPS          ?= 0
SKIP_LICENSES      ?= 0
SKIP_MACCATALYST   ?= 0
RUN_HOOKS     ?= 1
GN_ARGS       ?=
EXTRA_GN_ARGS ?=
WEBRTC_REPO   ?= git@github.com:GetStream/webrtc.git
WEBRTC_ROOT   ?=
WEBRTC_SRC    ?= $(abspath $(PIPELINE)/..)
ifneq ($(WEBRTC_ROOT),)
DEPS_ROOT     ?= $(WEBRTC_ROOT)
endif
DEPS_ROOT     ?= $(WEBRTC_SRC)/.gclient_deps
OUT           ?= $(DEPS_ROOT)/out
PRODUCTS      ?= $(DEPS_ROOT)/products
TARGET        ?=
NINJA_TARGET  ?=
ARCHS         ?=
TEST_TARGETS  ?=
ZIP           ?= 0
XCFRAMEWORK   ?= $(PRODUCTS)/WebRTC.xcframework
AAR           ?= $(PRODUCTS)/libwebrtc.aar
RENAMED       ?= $(PRODUCTS)/renamed
SIMULATOR_PLATFORM ?=
SIMULATOR_VERSION  ?=
EXTRA_ARGS    ?=

ALL_GN_ARGS := $(strip $(EXTRA_GN_ARGS) $(GN_ARGS))

CATALYST_SLICES  := catalyst-arm64 catalyst-x64
IOS_SLICES       := ios-arm64-device ios-arm64-simulator ios-x64-simulator $(CATALYST_SLICES)
MACOS_SLICES     := macos-arm64 macos-x64
ANDROID_SLICES   := android-armeabi-v7a android-arm64-v8a android-x86 android-x86_64
WINDOWS_SLICES   := windows-x64 windows-arm64
IOS_TEST_TARGETS   ?= sdk_unittests sdk_framework_unittests
MACOS_TEST_TARGETS ?= rtc_unittests rtc_pc_unittests rtc_stats_unittests
WINDOWS_TEST_TARGETS ?= rtc_unittests rtc_pc_unittests rtc_stats_unittests

ios_slices      = $(if $(filter 1,$(SKIP_MACCATALYST)),$(filter-out $(CATALYST_SLICES),$(IOS_SLICES)),$(IOS_SLICES))
android_slices  = $(if $(ARCHS),$(addprefix android-,$(ARCHS)),$(ANDROID_SLICES))
windows_slices  = $(if $(ARCHS),$(addprefix windows-,$(ARCHS)),$(WINDOWS_SLICES))

PLATFORMS := ios android macos windows
VERBS     := build test package
PLATFORM  := $(firstword $(filter $(PLATFORMS),$(MAKECMDGOALS)))

export DEPS_ROOT WEBRTC_SRC WEBRTC_ROOT WEBRTC_REPO WEBRTC_REVISION WEBRTC_REF
export TARGET_OS JOBS RUN_HOOKS CONFIG OUT PRODUCTS ARCHS SKIP_LICENSES
export GN_ARGS EXTRA_GN_ARGS ALL_GN_ARGS

.DEFAULT_GOAL := help

.PHONY: help check deps runhooks gen ninja slice clean print-gn-args \
	announce require-src require-darwin require-linux require-windows maybe-deps \
	combine apple rename rename-apple rename-android \
	$(PLATFORMS) $(VERBS) \
	build-ios build-macos build-android build-windows \
	test-ios test-macos test-android test-windows \
	package-ios package-macos package-android package-windows \
	$(addprefix build-slice-,$(IOS_SLICES) $(MACOS_SLICES) $(ANDROID_SLICES) $(WINDOWS_SLICES))

ifneq ($(filter build,$(MAKECMDGOALS)),)
  ifneq ($(filter package,$(MAKECMDGOALS)),)
    package: build
  endif
endif

help:
	@echo "make build|test|package ios|android|macos|windows [VAR=value ...]"
	@echo "make combine"
	@echo "make rename apple|android"
	@echo
	@echo "  build    gn gen + ninja"
	@echo "  test     build and run tests"
	@echo "  package  assemble artifacts (xcframework, aar, zip)"
	@echo "  combine  merge PRODUCTS/*/WebRTC.xcframework into one xcframework"
	@echo "  rename   copy+rebrand for wrapper SDKs (original untouched)"
	@echo
	@echo "  CONFIG=release (default, is_debug=false) or CONFIG=debug"
	@echo "  tests always gn-gen with debug, ignoring CONFIG"
	@echo "  SKIP_DEPS=1 skips gclient sync only; build/test/package still run"
	@echo "  SKIP_LICENSES=1 skips license generation only; lipo/zip still run"
	@echo "  SKIP_MACCATALYST=1 drops catalyst-arm64 catalyst-x64 from ios"
	@echo
	@echo "  make package ios"
	@echo "  make package macos"
	@echo "  make combine          # merges whatever platform dirs exist under PRODUCTS"
	@echo "  make rename apple XCFRAMEWORK=path/to/WebRTC.xcframework"
	@echo "  make rename android AAR=path/to/libwebrtc.aar"
	@echo "  make build package ios     compile then pack"
	@echo "  make build android ARCHS=arm64-v8a"
	@echo "  make build ios GN_ARGS='rtc_use_h264=false' CONFIG=debug"
	@echo "  make build ios DEPS_ROOT=/tmp/webrtc-deps"
	@echo "  make build ios SKIP_MACCATALYST=1"
	@echo
	@echo "Also: deps runhooks check clean print-gn-args TARGET=slice"
	@echo "Vars: DEPS_ROOT WEBRTC_SRC OUT PRODUCTS CONFIG GN_ARGS JOBS ARCHS ZIP XCFRAMEWORK AAR RENAMED SKIP_DEPS SKIP_LICENSES SKIP_MACCATALYST"

check:
	@$(SCRIPTS)/check.sh

deps:
	@$(SCRIPTS)/deps.sh sync

runhooks:
	@$(SCRIPTS)/deps.sh runhooks

print-gn-args:
	@test -n "$(TARGET)" || { echo "TARGET is required (slice name)"; exit 1; }
	@$(SCRIPTS)/gn-gen.sh --print --slice "$(TARGET)" --config "$(CONFIG)" --extra "$(ALL_GN_ARGS)"

require-src:
	@test -n "$(WEBRTC_SRC)" || { echo "WEBRTC_SRC is required"; exit 1; }
	@test -f "$(WEBRTC_SRC)/DEPS" || { echo "No WebRTC checkout at $(WEBRTC_SRC)"; exit 1; }

require-darwin:
	@test "$$(uname -s)" = Darwin || { echo "Apple targets require macOS"; exit 1; }

require-linux:
	@test "$$(uname -s)" = Linux || { echo "Android builds require Linux"; exit 1; }

require-windows:
	@case "$$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exit 0 ;; esac; \
	 test "$${OS}" = Windows_NT || { echo "Windows targets require Windows"; exit 1; }

maybe-deps:
ifneq ($(SKIP_DEPS),1)
	$(MAKE) deps
endif

$(PLATFORMS) apple:
	@:

announce:
	@effective="$(CONFIG)"; \
	 note=""; \
	 if [[ "$(VERB)" == test ]]; then \
	   effective=debug; \
	   note=" (tests always debug)"; \
	 fi; \
	 echo "==> $(strip $(VERB) $(PLATFORM))"; \
	 echo "    config:     $$effective$$note"; \
	 echo "    deps_root:  $(DEPS_ROOT)"; \
	 echo "    src:        $(WEBRTC_SRC)"; \
	 echo "    out:        $(OUT)"; \
	 products="$(PRODUCTS)"; \
	 case "$(PLATFORM)" in \
	   ios) products="$(PRODUCTS)/ios" ;; \
	   macos) products="$(PRODUCTS)/macos" ;; \
	 esac; \
	 echo "    products:   $$products"; \
	 echo "    jobs:       $(JOBS)"; \
	 echo "    skip_deps:  $(SKIP_DEPS)"; \
	 echo "    skip_licenses: $(SKIP_LICENSES)"; \
	 echo "    skip_maccatalyst: $(SKIP_MACCATALYST)"; \
	 if [[ -n "$(ALL_GN_ARGS)" ]]; then echo "    gn_args:    $(ALL_GN_ARGS)"; fi; \
	 case "$(PLATFORM)" in \
	   ios) echo "    slices:     $(ios_slices)" ;; \
	   macos) echo "    slices:     $(MACOS_SLICES)" ;; \
	   android) \
	     if [[ "$(VERB)" != rename ]]; then echo "    slices:     $(android_slices)"; fi ;; \
	   windows) echo "    slices:     $(windows_slices)" ;; \
	 esac; \
	 if [[ "$(VERB)" == test ]]; then \
	   case "$(PLATFORM)" in \
	     ios) echo "    tests:      $(if $(TEST_TARGETS),$(TEST_TARGETS),$(IOS_TEST_TARGETS))" ;; \
	     macos) echo "    tests:      $(if $(TEST_TARGETS),$(TEST_TARGETS),$(MACOS_TEST_TARGETS))" ;; \
	     windows) echo "    tests:      $(if $(TEST_TARGETS),$(TEST_TARGETS),$(WINDOWS_TEST_TARGETS))" ;; \
	   esac; \
	 fi; \
	 if [[ "$(VERB)" == rename ]]; then \
	   case "$(PLATFORM)" in \
	     apple) \
	       echo "    input:      $(XCFRAMEWORK)"; \
	       echo "    output:     $(RENAMED)/StreamWebRTC.xcframework" ;; \
	     android) \
	       echo "    input:      $(AAR)"; \
	       echo "    output:     $(RENAMED)/libwebrtc.aar" ;; \
	   esac; \
	 fi; \
	 if [[ "$$(uname -s)" == Darwin ]]; then \
	   echo "    xcode:      $$(xcodebuild -version 2>/dev/null | paste -sd ' ' -)"; \
	   echo "    developer:  $${DEVELOPER_DIR:-$$(xcode-select -p 2>/dev/null)}"; \
	 fi

build test package:
	@test -n "$(PLATFORM)" || { echo "usage: make $@ ios|android|macos|windows"; exit 1; }
	@$(MAKE) --no-print-directory announce VERB=$@ PLATFORM="$(PLATFORM)"
	@$(MAKE) --no-print-directory $@-$(PLATFORM)

combine: require-darwin require-src
	@$(MAKE) --no-print-directory announce VERB=combine PLATFORM=
	@$(SCRIPTS)/combine-apple.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(OUT)" \
		--products "$(PRODUCTS)" \
		$(if $(filter 1,$(ZIP)),--zip,)

rename:
	@target="$(firstword $(filter apple android,$(MAKECMDGOALS)))"; \
	 test -n "$$target" || { echo "usage: make rename apple|android"; exit 1; }; \
	 $(MAKE) --no-print-directory announce VERB=rename PLATFORM="$$target"; \
	 $(MAKE) --no-print-directory rename-$$target

rename-apple: require-darwin
	@$(SCRIPTS)/rename-apple.sh \
		--src "$(XCFRAMEWORK)" \
		--dest "$(RENAMED)"

rename-android:
	@$(SCRIPTS)/rename-android.sh \
		--src "$(AAR)" \
		--dest "$(RENAMED)"

gen: require-src
	@test -n "$(TARGET)" || { echo "TARGET is required (slice name)"; exit 1; }
	@$(SCRIPTS)/gn-gen.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(OUT)/$(TARGET)" \
		--slice "$(TARGET)" \
		--config "$(CONFIG)" \
		--extra "$(ALL_GN_ARGS)"

ninja: require-src
	@test -n "$(TARGET)" || { echo "TARGET is required (slice name)"; exit 1; }
	@ninja_bin="$$($(SCRIPTS)/common.sh ninja "$(WEBRTC_SRC)")"; \
	 ninja_target="$(NINJA_TARGET)"; \
	 if [[ -z "$$ninja_target" ]]; then \
	   ninja_target="$$($(SCRIPTS)/gn-gen.sh --ninja-target "$(TARGET)")"; \
	 fi; \
	 echo "$$ninja_bin -C $(OUT)/$(TARGET) $$ninja_target"; \
	 "$$ninja_bin" -C "$(OUT)/$(TARGET)" $$ninja_target -j"$(JOBS)"

slice: gen ninja

$(addprefix build-slice-,$(IOS_SLICES) $(MACOS_SLICES) $(ANDROID_SLICES) $(WINDOWS_SLICES)): build-slice-%: require-src
	@$(MAKE) --no-print-directory slice TARGET=$*

build-ios: require-darwin maybe-deps require-src $(addprefix build-slice-,$(ios_slices))
build-macos: require-darwin maybe-deps require-src $(addprefix build-slice-,$(MACOS_SLICES))
build-android: require-linux maybe-deps require-src $(addprefix build-slice-,$(android_slices))
build-windows: require-windows maybe-deps require-src $(addprefix build-slice-,$(windows_slices))

package-ios: require-darwin require-src
	@$(SCRIPTS)/package-apple.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(OUT)" \
		--products "$(PRODUCTS)/ios" \
		--slices "$(ios_slices)" \
		$(if $(filter 1,$(ZIP)),--zip,)

package-macos: require-darwin require-src
	@$(SCRIPTS)/package-apple.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(OUT)" \
		--products "$(PRODUCTS)/macos" \
		--slices "$(MACOS_SLICES)" \
		$(if $(filter 1,$(ZIP)),--zip,)

package-android: require-linux require-src
	@$(SCRIPTS)/package-android.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(OUT)" \
		--products "$(PRODUCTS)" \
		--slices "$(android_slices)"

package-windows: require-windows require-src
	@$(SCRIPTS)/package-windows.sh \
		--out "$(OUT)" \
		--products "$(PRODUCTS)" \
		--slices "$(windows_slices)" \
		$(if $(filter 1,$(ZIP)),--zip,)

test-ios: require-darwin maybe-deps require-src
	@$(SCRIPTS)/gn-gen.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(OUT)/ios_tests" \
		--config debug \
		--overlay ios-test \
		--extra "$(ALL_GN_ARGS)"
	@ninja_bin="$$($(SCRIPTS)/common.sh ninja "$(WEBRTC_SRC)")"; \
	 targets="$(if $(TEST_TARGETS),$(TEST_TARGETS),$(IOS_TEST_TARGETS))"; \
	 echo "$$ninja_bin -C $(OUT)/ios_tests $$targets"; \
	 "$$ninja_bin" -C "$(OUT)/ios_tests" $$targets -j"$(JOBS)"
	@$(SCRIPTS)/run-ios-tests.sh \
		--build-dir "$(OUT)/ios_tests" \
		--targets "$(if $(TEST_TARGETS),$(TEST_TARGETS),$(IOS_TEST_TARGETS))" \
		$(if $(SIMULATOR_PLATFORM),--platform "$(SIMULATOR_PLATFORM)",) \
		$(if $(SIMULATOR_VERSION),--version "$(SIMULATOR_VERSION)",) \
		$(if $(EXTRA_ARGS),--extra "$(EXTRA_ARGS)",)

test-macos: require-darwin maybe-deps require-src
	@$(SCRIPTS)/gn-gen.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(OUT)/webrtc_tests" \
		--config debug \
		--overlay macos-test \
		--extra "$(ALL_GN_ARGS)"
	@ninja_bin="$$($(SCRIPTS)/common.sh ninja "$(WEBRTC_SRC)")"; \
	 targets="$(if $(TEST_TARGETS),$(TEST_TARGETS),$(MACOS_TEST_TARGETS))"; \
	 echo "$$ninja_bin -C $(OUT)/webrtc_tests $$targets"; \
	 "$$ninja_bin" -C "$(OUT)/webrtc_tests" $$targets -j"$(JOBS)"; \
	 filter="$$(tr -d '\n' < "$(SCRIPTS)/macos-gtest-filter.txt")"; \
	 for target in $$targets; do \
	   echo "$(OUT)/webrtc_tests/$$target"; \
	   "$(OUT)/webrtc_tests/$$target" --gtest_filter="-$$filter" $(EXTRA_ARGS); \
	 done

test-android:
	@echo "error: make test android is not wired (no device runner)." >&2
	@echo "use: make build android && make package android" >&2
	@exit 1

test-windows: require-windows maybe-deps require-src
	@$(SCRIPTS)/gn-gen.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(OUT)/windows_tests" \
		--config debug \
		--overlay windows-test \
		--extra "$(ALL_GN_ARGS)"
	@ninja_bin="$$($(SCRIPTS)/common.sh ninja "$(WEBRTC_SRC)")"; \
	 targets="$(if $(TEST_TARGETS),$(TEST_TARGETS),$(WINDOWS_TEST_TARGETS))"; \
	 echo "$$ninja_bin -C $(OUT)/windows_tests $$targets"; \
	 "$$ninja_bin" -C "$(OUT)/windows_tests" $$targets -j"$(JOBS)"; \
	 for target in $$targets; do \
	   echo "$(OUT)/windows_tests/$$target"; \
	   "$(OUT)/windows_tests/$$target" $(EXTRA_ARGS); \
	 done

clean: require-src
	rm -rf "$(OUT)" "$(PRODUCTS)"
