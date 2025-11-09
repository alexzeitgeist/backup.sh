SHELL := bash

FILES ?= backup.sh
SHFMT ?= shfmt
SHFMT_FLAGS ?= -i 2 -ci -bn
SHELLCHECK ?= shellcheck
SHELLCHECK_FLAGS ?= -x

.PHONY: help fmt fmt-check lint check ci

help:
	@echo "Prototype targets:"
	@echo "  fmt        Format backup.sh with shfmt (2 spaces)"
	@echo "  fmt-check  Show formatting diff without writing"
	@echo "  lint       Run shellcheck with -x"
	@echo "  check      Bash syntax check (bash -n)"
	@echo "  ci         Run fmt-check, lint, and check"
	@echo "Variables: FILES (default: $(FILES))"

fmt:
	@command -v $(SHFMT) >/dev/null || { echo "shfmt not found"; exit 1; }
	@$(SHFMT) -w $(SHFMT_FLAGS) $(FILES)

fmt-check:
	@command -v $(SHFMT) >/dev/null || { echo "shfmt not found"; exit 1; }
	@$(SHFMT) -d $(SHFMT_FLAGS) $(FILES)

lint:
	@command -v $(SHELLCHECK) >/dev/null || { echo "shellcheck not found"; exit 1; }
	@$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(FILES)

check:
	@bash -n $(FILES)

ci: fmt-check lint check
