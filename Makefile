.DEFAULT_GOAL := help

.PHONY: help
help:
	@printf '%s\n' 'make check        Format, build, tests and Loom lint' \
	  'make fmt          Format Gantry sources' \
	  'make e2e          Exercise three voters, Docker and a bare Git remote' \
	  'make model-check  Check the TLA+ queue model (set TLA2TOOLS)'

.PHONY: check
check:
	cd packages/core && gleam format --check src test && gleam build --warnings-as-errors && gleam test && gleam test --target javascript
	cd packages/server && gleam format --check src && gleam build --warnings-as-errors
	$(MAKE) lint

.PHONY: fmt
fmt:
	cd packages/core && gleam format src test
	cd packages/server && gleam format src

.PHONY: lint
lint:
	@bash scripts/lint.sh

.PHONY: e2e
e2e:
	bash scripts/e2e.sh

.PHONY: model-check
model-check:
	bash scripts/model-check.sh
