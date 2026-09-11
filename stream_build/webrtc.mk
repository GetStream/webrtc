# webrtc/Makefile — created by bootstrap if missing
# Catch-all forwarder. Recipes live in src/stream_build (cwd must be there).

MAKECMDGOALS ?=
STREAM_BUILD := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))src/stream_build
GOALS := $(filter-out all,$(MAKECMDGOALS))
FIRST := $(firstword $(or $(MAKECMDGOALS),all))
REST := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))

.DEFAULT_GOAL := all
.PHONY: all $(MAKECMDGOALS)

# One recursive make for `make build ios`; extra goals are no-ops.
$(FIRST):
	@$(MAKE) -C "$(STREAM_BUILD)" $(GOALS)

ifneq ($(REST),)
$(REST):
	@:
endif
