# swarmcli-charts — contributor & maintainer task runner.
#
# Every target shells out to scripts/, and `make test` runs exactly what the
# charts.yml workflow runs, so "green locally" means "green in CI".

SHELL := bash
.DEFAULT_GOAL := help

SWARMCLI_BIN := $(CURDIR)/.swarmcli-bin/swarmcli
RELEASE ?= ci

## help: show this help
help:
	@echo "swarmcli-charts make targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed -E 's/^## ([a-z-]+): /  \1\t/' \
		| awk -F'\t' '{printf "  %-14s %s\n", $$1, $$2}'

## install-tools: build the swarmcli renderer and check for helper tools
install-tools: $(SWARMCLI_BIN)
	@command -v yamllint        >/dev/null 2>&1 || echo "note: yamllint not found    (pip install yamllint)"
	@command -v shellcheck      >/dev/null 2>&1 || echo "note: shellcheck not found"
	@command -v actionlint      >/dev/null 2>&1 || echo "note: actionlint not found  (optional, used by ci.yml)"
	@docker compose version     >/dev/null 2>&1 || echo "note: docker compose v2 not found (required by 'make test')"
	@echo "swarmcli renderer: $(SWARMCLI_BIN)"

$(SWARMCLI_BIN):
	@scripts/install-swarmcli.sh $(CURDIR)/.swarmcli-bin >/dev/null

## lint: chart structure + YAML lint (no rendering)
lint:
	@scripts/lint.sh

## render: render one chart to stdout (CHART=name [VALUES=file])
render: $(SWARMCLI_BIN)
	@test -n "$(CHART)" || { echo "usage: make render CHART=<name> [VALUES=<file>]"; exit 2; }
	@"$(SWARMCLI_BIN)" charts template $(RELEASE) ./charts/$(CHART) \
		$(if $(VALUES),-f $(VALUES),-f charts/$(CHART)/ci/default-values.yaml)

## test: render + validate every chart against its ci/ fixtures (== CI). CHART= limits to one
test: $(SWARMCLI_BIN)
	@SWARMCLI="$(SWARMCLI_BIN)" RELEASE="$(RELEASE)" scripts/test-charts.sh $(CHART)

## new-chart: scaffold a new chart (NAME=foo)
new-chart:
	@test -n "$(NAME)" || { echo "usage: make new-chart NAME=<name>"; exit 2; }
	@scripts/new-chart.sh $(NAME)

## package: build a local .tgz for a chart (CHART=foo)
package:
	@test -n "$(CHART)" || { echo "usage: make package CHART=<name>"; exit 2; }
	@ver=$$(sed -n 's/^version:[[:space:]]*//p' charts/$(CHART)/Chart.yaml | head -1); \
		tar -czf $(CHART)-v$$ver.tgz -C charts $(CHART); \
		echo "wrote $(CHART)-v$$ver.tgz"

.PHONY: help install-tools lint render test new-chart package
