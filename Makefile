#! /usr/bin/make -f

.DEFAULT_GOAL := help

COVERAGE_ROOT     ?= $(CURDIR)/test-coverage
SERVER_LOCAL_PATH ?=
CLIENT_LOCAL_PATH ?=
SERVER_REF        ?= main
CLIENT_REF        ?= main

export SERVER_LOCAL_PATH
export CLIENT_LOCAL_PATH
export SERVER_REF
export CLIENT_REF

COVERAGE_ENABLED := 1
export COVERAGE_ENABLED
export COVERAGE_ROOT

SERVER_SRC_DIR := $(if $(SERVER_LOCAL_PATH),$(SERVER_LOCAL_PATH),$(CURDIR)/src/server)
CLIENT_SRC_DIR := $(if $(CLIENT_LOCAL_PATH),$(CLIENT_LOCAL_PATH),$(CURDIR)/src/client)

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  test-coverage - run the e2e testbed with coverage instrumentation enabled and merge results"
	@echo "  clean         - remove test-coverage/, src/, and workdir/"

.PHONY: clean
clean:
	rm -rf "$(COVERAGE_ROOT)"
	rm -rf "$(CURDIR)/src"
	rm -rf "$(CURDIR)/workdir"
	rm -rf "$(CURDIR)/test/ci/src" "$(CURDIR)/test/ci/workdir"
	rm -rf "$(CURDIR)/test/container/src" "$(CURDIR)/test/container/workdir"

.PHONY: test-coverage
test-coverage:
	mkdir -p "$(COVERAGE_ROOT)/raw/server" "$(COVERAGE_ROOT)/raw/client"
	rc=0; \
	for t in test/ci/test-*.sh test/container/test-*.sh; do \
		echo "=== RUNNING: $$t ==="; \
		bash "$$t" || rc=1; \
	done; \
	test/coverage/merge.sh server "$(COVERAGE_ROOT)/raw/server" "$(SERVER_SRC_DIR)" "$(COVERAGE_ROOT)"; \
	test/coverage/merge.sh client "$(COVERAGE_ROOT)/raw/client" "$(CLIENT_SRC_DIR)" "$(COVERAGE_ROOT)"; \
	exit $$rc
