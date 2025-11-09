SHELL := bash

# Scripts to manage (override with FILES=...)
SCRIPTS := backup.sh restore.sh
FILES ?= $(SCRIPTS)

# Tools and flags
SHFMT ?= shfmt
SHFMT_FLAGS ?= -i 2 -ci -bn
SHELLCHECK ?= shellcheck
SHELLCHECK_FLAGS ?= -s bash

.PHONY: help fmt fmt-check lint check ci

help:
	@echo "Available targets:"
	@echo "  fmt        Format scripts in-place with shfmt (2 spaces)"
	@echo "  fmt-check  Show formatting diff without writing"
	@echo "  lint       Run shellcheck on scripts"
	@echo "  check      Bash syntax check (bash -n)"
	@echo "  ci         Run fmt-check, lint, and check"
	@echo "Variables: FILES (default: $(SCRIPTS))"

fmt:
	@command -v $(SHFMT) >/dev/null || { echo "shfmt not found; install it and retry."; exit 1; }
	@$(SHFMT) -w $(SHFMT_FLAGS) $(FILES)

fmt-check:
	@command -v $(SHFMT) >/dev/null || { echo "shfmt not found; install it and retry."; exit 1; }
	@$(SHFMT) -d $(SHFMT_FLAGS) $(FILES)

lint:
	@command -v $(SHELLCHECK) >/dev/null || { echo "shellcheck not found; install it and retry."; exit 1; }
	@$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(FILES)

check:
	@bash -n $(FILES)

ci: fmt-check lint check

