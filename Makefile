.DEFAULT_GOAL := help
PREFIX ?= $(HOME)/.local
RELEASE_ARCHIVE := build/release/gantry-$(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m).tar.gz

.PHONY: help
help:
	@printf '%s\n' 'make check        Format, build, tests and Loom lint' \
	  'make fmt          Format Gantry sources' \
	  'make dashboard    Rebuild the dashboard files gantryd serves (needs the network once)' \
	  'make e2e          Exercise three voters, Docker and a bare Git remote' \
	  'make model-check  Check the TLA+ queue model (set TLA2TOOLS)' \
	  'make release      Bundle the controller and worker with their BEAM runtime' \
	  'make install      Build and install the release (set PREFIX)' \
	  'make update       Build and select a new release (set PREFIX)' \
	  'make gen-sql      Regenerate the worker journal SQL bindings'

.PHONY: release install update gen-sql dashboard
dashboard:
	bash scripts/dashboard_assets.sh

release:
	bash scripts/release.sh "$(RELEASE_ARCHIVE)"

install: release
	PREFIX="$(PREFIX)" bash scripts/install.sh "$(RELEASE_ARCHIVE)"

update: install

gen-sql:
	bash scripts/gen-sql.sh

.PHONY: check
check:
	cd packages/core && gleam format --check src test && gleam build --warnings-as-errors && gleam test && gleam test --target javascript
	cd packages/server && gleam format --check src test && gleam build --warnings-as-errors && gleam test
	cd packages/dashboard && gleam format --check src test && gleam build --warnings-as-errors && gleam test
	bash scripts/dashboard_assets.sh --check
	bash scripts/dashboard_assets.sh --self-test
	$(MAKE) lint

.PHONY: fmt
fmt:
	cd packages/core && gleam format src test
	cd packages/server && gleam format src test
	cd packages/dashboard && gleam format src test

.PHONY: lint
lint:
	@bash scripts/lint.sh

.PHONY: e2e
e2e:
	bash scripts/e2e.sh

.PHONY: model-check
model-check:
	bash scripts/model-check.sh
