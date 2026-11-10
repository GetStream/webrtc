# Public API:
#   make bootstrap
#   make build|test|package ios|android|macos|windows [VAR=value ...]
#   make combine
#   make rename apple|android
# GN overrides: CONFIG=debug GN_ARGS='key=value key2=value'
#
# Layout: Chromium-style webrtc/src (this git checkout). Run make bootstrap
# once. Other verbs assume that layout.
# From the git root:  cd stream_build && make build ios
# From webrtc/:        make build ios  (bootstrap writes parent Makefile)
# SKIP_DEPS=1 skips gclient sync only; gn/ninja still run.
# SKIP_LICENSES=1 skips license generation only; lipo/zip still run.
# SKIP_MACCATALYST=1 drops catalyst-* from ios build+package only.
# package ios/macos write PRODUCTS/ios and PRODUCTS/macos.
# make combine merges whatever PRODUCTS/*/WebRTC.xcframework exist.
# make rename copies WebRTC.xcframework / libwebrtc.aar to PRODUCTS/renamed/.
# ANDROID_NAMESPACE=io.getstream.webrtc rewrites the Android package before build.
# make migrate plan|prepare|open
#   Extended-stable migration. No bootstrap. FORCE=1 retries an existing PR.

SHELL := /bin/bash
.SUFFIXES:

PIPELINE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS  := $(PIPELINE)scripts

CONFIG        ?= release
TARGET_OS     ?= ios
JOBS          ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)
SHALLOW            ?= 1
SKIP_DEPS          ?= 0
SKIP_LICENSES      ?= 0
SKIP_MACCATALYST   ?= 0
RUN_HOOKS     ?= 1
CONFIRM       ?= 0
GN_ARGS       ?=
EXTRA_GN_ARGS ?=
WEBRTC_REPO   ?= git@github.com:GetStream/webrtc.git
WEBRTC_ROOT   ?=
REPO_ROOT     := $(abspath $(PIPELINE)/..)
WEBRTC_SRC    ?= $(REPO_ROOT)
ifneq ($(WEBRTC_ROOT),)
DEPS_ROOT     ?= $(WEBRTC_ROOT)
endif
DEPS_ROOT     ?= $(abspath $(REPO_ROOT)/..)
OUT           ?= $(DEPS_ROOT)/out
PRODUCTS      ?= $(DEPS_ROOT)/products
GIT_CACHE_PATH ?= $(DEPS_ROOT)/.gclient-git-cache
TARGET        ?=
NINJA_TARGET  ?=
ARCHS         ?=
TEST_TARGETS  ?=
ZIP           ?= 0
XCFRAMEWORK   ?= $(PRODUCTS)/WebRTC.xcframework
AAR           ?= $(PRODUCTS)/libwebrtc.aar
RENAMED       ?= $(PRODUCTS)/renamed
ANDROID_NAMESPACE ?= org.webrtc
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
ANDROID_TEST_TARGETS ?= rtc_unittests
# Chromium's Android runner drops leading ".." from data-dep paths. That
# lands on resources/ only when the output directory is inside src.
# webrtc/out/android_tests pushes to src/resources/..., and tests open
# /sdcard/chromium_tests_root/resources/...
ANDROID_TEST_OUT := $(WEBRTC_SRC)/out/android_tests

ios_slices      = $(if $(filter 1,$(SKIP_MACCATALYST)),$(filter-out $(CATALYST_SLICES),$(IOS_SLICES)),$(IOS_SLICES))
android_slices  = $(if $(ARCHS),$(addprefix android-,$(ARCHS)),$(ANDROID_SLICES))
windows_slices  = $(if $(ARCHS),$(addprefix windows-,$(ARCHS)),$(WINDOWS_SLICES))

PLATFORMS := ios android macos windows
VERBS     := build test package
PLATFORM  := $(firstword $(filter $(PLATFORMS),$(MAKECMDGOALS)))

export DEPS_ROOT WEBRTC_SRC WEBRTC_ROOT WEBRTC_REPO WEBRTC_REVISION WEBRTC_REF
export TARGET_OS JOBS SHALLOW RUN_HOOKS CONFIG OUT PRODUCTS ARCHS SKIP_LICENSES
export GN_ARGS EXTRA_GN_ARGS ALL_GN_ARGS GIT_CACHE_PATH CONFIRM BOOTSTRAP_SRC

.DEFAULT_GOAL := help

.PHONY: help check bootstrap deps runhooks gen ninja slice clean print-gn-args \
	announce require-layout require-gclient require-src require-darwin \
	require-linux require-windows maybe-deps \
	combine apple rename rename-apple rename-android rewrite-android-namespace \
	migrate plan prepare open issue \
	$(PLATFORMS) $(VERBS) \
	build-ios build-macos build-android build-windows \
	compile-tests-ios compile-tests-macos compile-tests-android \
	test-ios test-macos test-android test-windows \
	package-ios package-macos package-android package-windows \
	$(addprefix build-slice-,$(IOS_SLICES) $(MACOS_SLICES) $(ANDROID_SLICES) $(WINDOWS_SLICES))

ifneq ($(filter build,$(MAKECMDGOALS)),)
  ifneq ($(filter package,$(MAKECMDGOALS)),)
    package: build
  endif
endif

help:
	@echo "make bootstrap"
	@echo "make build|test|package ios|android|macos|windows [VAR=value ...]"
	@echo "make combine"
	@echo "make rename apple|android"
	@echo "make migrate plan|prepare|open"
	@echo
	@echo "  bootstrap  wrap this checkout as webrtc/src (CONFIRM=1 in CI)"
	@echo "  build    gn gen + ninja"
	@echo "  test     build and run tests"
	@echo "  package  assemble artifacts (xcframework, aar, zip)"
	@echo "  combine  merge PRODUCTS/*/WebRTC.xcframework into one xcframework"
	@echo "  rename   copy+rebrand for wrapper SDKs (original untouched)"
	@echo "  migrate plan      print whether extended stable is ahead of the fork"
	@echo "  migrate prepare   fetch that milestone; then run the migrate skill"
	@echo "  migrate open      check the merge and open the pull request"
	@echo "  FORCE=1           plan again when a pull request for this milestone exists"
	@echo
	@echo "  CONFIG=release (default, is_debug=false) or CONFIG=debug"
	@echo "  tests always gn-gen with debug, ignoring CONFIG"
	@echo "  SHALLOW=1 (default) gclient --no-history --shallow; SHALLOW=0 full history"
	@echo "  SKIP_DEPS=1 skips gclient sync only; build/test/package still run"
	@echo "  SKIP_LICENSES=1 skips license generation only; lipo/zip still run"
	@echo "  SKIP_MACCATALYST=1 drops catalyst-arm64 catalyst-x64 from ios"
	@echo "  Apple package commands create XCFramework ZIPs by default (ZIP=0 opts out)"
	@echo
	@echo "  make package ios"
	@echo "  make package macos"
	@echo "  from webrtc/: make build ios"
	@echo "  make combine          # merges whatever platform dirs exist under PRODUCTS"
	@echo "  make rename apple XCFRAMEWORK=path/to/WebRTC.xcframework"
	@echo "  make rename android AAR=path/to/libwebrtc.aar"
	@echo "  make build package ios     compile then pack"
	@echo "  make build android ARCHS=arm64-v8a"
	@echo "  ANDROID_NAMESPACE=org.webrtc (default) or io.getstream.webrtc"
	@echo "  make build ios GN_ARGS='rtc_use_h264=false' CONFIG=debug"
	@echo "  make bootstrap CONFIRM=1"
	@echo "  make build ios SKIP_MACCATALYST=1"
	@echo
	@echo "Also: deps runhooks check clean print-gn-args TARGET=slice"
	@echo "Vars: DEPS_ROOT WEBRTC_SRC OUT PRODUCTS GIT_CACHE_PATH CONFIG GN_ARGS JOBS SHALLOW ARCHS ZIP XCFRAMEWORK AAR RENAMED ANDROID_NAMESPACE SKIP_DEPS SKIP_LICENSES SKIP_MACCATALYST CONFIRM"
	@echo "OUT defaults to DEPS_ROOT/out (sibling of src)."

check:
	@$(SCRIPTS)/check.sh

migrate:
	@action="$(firstword $(filter plan prepare open issue,$(MAKECMDGOALS)))"; \
	 test -n "$$action" || { echo "usage: make migrate plan|prepare|open|issue"; exit 1; }; \
	 FORCE='$(FORCE)' FORK_SHA='$(FORK_SHA)' $(SCRIPTS)/migrate.sh $$action

plan prepare open issue:
	@:

bootstrap:
	@$(SCRIPTS)/bootstrap.sh

deps: require-gclient
	@$(SCRIPTS)/deps.sh sync

runhooks: require-gclient
	@$(SCRIPTS)/deps.sh runhooks

print-gn-args: require-layout
	@test -n "$(TARGET)" || { echo "TARGET is required (slice name)"; exit 1; }
	@$(SCRIPTS)/gn-gen.sh --print --slice "$(TARGET)" --config "$(CONFIG)" --extra "$(ALL_GN_ARGS)"

require-layout:
	@$(SCRIPTS)/bootstrap.sh --check

require-gclient:
	@$(SCRIPTS)/bootstrap.sh --check --gclient

require-src: require-layout
	@test -n "$(WEBRTC_SRC)" || { echo "run: make bootstrap"; exit 1; }
	@test ! -L "$(WEBRTC_SRC)" || { echo "run: make bootstrap"; exit 1; }
	@test -f "$(WEBRTC_SRC)/DEPS" || { echo "run: make bootstrap"; exit 1; }

require-darwin:
	@test "$$(uname -s)" = Darwin || { echo "Apple targets require macOS"; exit 1; }

require-linux:
	@test "$$(uname -s)" = Linux || { echo "Android builds require Linux"; exit 1; }

require-windows:
	@case "$$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exit 0 ;; esac; \
	 test "$${OS}" = Windows_NT || { echo "Windows targets require Windows"; exit 1; }

maybe-deps: require-gclient
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
	 echo "    shallow:    $(SHALLOW)"; \
	 echo "    skip_deps:  $(SKIP_DEPS)"; \
	 echo "    skip_licenses: $(SKIP_LICENSES)"; \
	 echo "    skip_maccatalyst: $(SKIP_MACCATALYST)"; \
	 if [[ -n "$(ALL_GN_ARGS)" ]]; then echo "    gn_args:    $(ALL_GN_ARGS)"; fi; \
	 case "$(PLATFORM)" in \
	   ios) echo "    slices:     $(ios_slices)" ;; \
	   macos) echo "    slices:     $(MACOS_SLICES)" ;; \
	   android) \
	     if [[ "$(VERB)" != rename ]]; then \
	       echo "    slices:     $(android_slices)"; \
	       echo "    namespace:  $(ANDROID_NAMESPACE)"; \
	     fi ;; \
	   windows) echo "    slices:     $(windows_slices)" ;; \
	 esac; \
	 if [[ "$(VERB)" == test ]]; then \
	   case "$(PLATFORM)" in \
	     ios) echo "    tests:      $(if $(TEST_TARGETS),$(TEST_TARGETS),$(IOS_TEST_TARGETS))" ;; \
	     macos) echo "    tests:      $(if $(TEST_TARGETS),$(TEST_TARGETS),$(MACOS_TEST_TARGETS))" ;; \
	     android) echo "    tests:      $(if $(TEST_TARGETS),$(TEST_TARGETS),$(ANDROID_TEST_TARGETS))" ;; \
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

build test package: require-gclient
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

rename: require-layout
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

rewrite-android-namespace: require-src
	@case "$(ANDROID_NAMESPACE)" in \
	  org.webrtc) ;; \
	  io.getstream.webrtc) \
	    $(SCRIPTS)/rewrite-android-namespace.sh --src "$(WEBRTC_SRC)" --no-backup ;; \
	  *) echo "ANDROID_NAMESPACE must be org.webrtc or io.getstream.webrtc (got '$(ANDROID_NAMESPACE)')"; exit 1 ;; \
	esac

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
	 if [[ "$(ANDROID_NAMESPACE)" == io.getstream.webrtc ]]; then \
	   ninja_target="$${ninja_target//libjingle_peerconnection_so/libstream_jingle_peerconnection_so}"; \
	 fi; \
	 echo "$$ninja_bin -C $(OUT)/$(TARGET) $$ninja_target"; \
	 "$$ninja_bin" -C "$(OUT)/$(TARGET)" $$ninja_target -j"$(JOBS)"

slice: gen ninja

$(addprefix build-slice-,$(IOS_SLICES) $(MACOS_SLICES) $(ANDROID_SLICES) $(WINDOWS_SLICES)): build-slice-%: require-src
	@$(MAKE) --no-print-directory slice TARGET=$*

build-ios: require-darwin maybe-deps require-src $(addprefix build-slice-,$(ios_slices))
build-macos: require-darwin maybe-deps require-src $(addprefix build-slice-,$(MACOS_SLICES))
$(addprefix build-slice-,$(ANDROID_SLICES)): rewrite-android-namespace
build-android: require-linux maybe-deps require-src rewrite-android-namespace $(addprefix build-slice-,$(android_slices))
build-windows: require-windows maybe-deps require-src $(addprefix build-slice-,$(windows_slices))

package-ios package-macos: ZIP = 1

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
		--slices "$(android_slices)" \
		--namespace "$(ANDROID_NAMESPACE)"

package-windows: require-windows require-src
	@$(SCRIPTS)/package-windows.sh \
		--out "$(OUT)" \
		--products "$(PRODUCTS)" \
		--slices "$(windows_slices)" \
		$(if $(filter 1,$(ZIP)),--zip,)

# Compile the debug test binaries. make test runs these, then the tests.
compile-tests-ios: require-darwin maybe-deps require-src
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

test-ios: compile-tests-ios
	@$(SCRIPTS)/run-ios-tests.sh \
		--build-dir "$(OUT)/ios_tests" \
		--targets "$(if $(TEST_TARGETS),$(TEST_TARGETS),$(IOS_TEST_TARGETS))" \
		$(if $(SIMULATOR_PLATFORM),--platform "$(SIMULATOR_PLATFORM)",) \
		$(if $(SIMULATOR_VERSION),--version "$(SIMULATOR_VERSION)",) \
		$(if $(EXTRA_ARGS),--extra "$(EXTRA_ARGS)",)

compile-tests-macos: require-darwin maybe-deps require-src
	@$(SCRIPTS)/gn-gen.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(OUT)/webrtc_tests" \
		--config debug \
		--overlay macos-test \
		--extra "$(ALL_GN_ARGS)"
	@ninja_bin="$$($(SCRIPTS)/common.sh ninja "$(WEBRTC_SRC)")"; \
	 targets="$(if $(TEST_TARGETS),$(TEST_TARGETS),$(MACOS_TEST_TARGETS))"; \
	 echo "$$ninja_bin -C $(OUT)/webrtc_tests $$targets"; \
	 "$$ninja_bin" -C "$(OUT)/webrtc_tests" $$targets -j"$(JOBS)"

test-macos: compile-tests-macos
	@targets="$(if $(TEST_TARGETS),$(TEST_TARGETS),$(MACOS_TEST_TARGETS))"; \
	 filter="$$(tr -d '\n' < "$(SCRIPTS)/macos-gtest-filter.txt")"; \
	 for target in $$targets; do \
	   echo "$(OUT)/webrtc_tests/$$target"; \
	   "$(OUT)/webrtc_tests/$$target" --gtest_filter="-$$filter" $(EXTRA_ARGS); \
	 done

compile-tests-android: require-linux maybe-deps require-src
	@$(SCRIPTS)/gn-gen.sh \
		--src "$(WEBRTC_SRC)" \
		--out "$(ANDROID_TEST_OUT)" \
		--config debug \
		--overlay android-test \
		--extra "$(ALL_GN_ARGS)"
	@ninja_bin="$$($(SCRIPTS)/common.sh ninja "$(WEBRTC_SRC)")"; \
	 targets="$(if $(TEST_TARGETS),$(TEST_TARGETS),$(ANDROID_TEST_TARGETS))"; \
	 echo "$$ninja_bin -C $(ANDROID_TEST_OUT) $$targets"; \
	 "$$ninja_bin" -C "$(ANDROID_TEST_OUT)" $$targets -j"$(JOBS)"

test-android: compile-tests-android
	@$(SCRIPTS)/run-android-tests.sh \
		--build-dir "$(ANDROID_TEST_OUT)" \
		--targets "$(if $(TEST_TARGETS),$(TEST_TARGETS),$(ANDROID_TEST_TARGETS))" \
		$(if $(EXTRA_ARGS),--extra "$(EXTRA_ARGS)",)

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

clean: require-layout
	rm -rf "$(OUT)" "$(PRODUCTS)"
