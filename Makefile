# Self-contained build.
#
# `make switch` creates a LOCAL switch in ./_opam, so the service never depends
# on a switch that happens to exist on the machine, and never touches the
# active one.  Removing it is `rm -rf _opam` (or `make distclean`).
#
# Deliberately a local switch rather than a named one: the bench machine's opam
# root is shared with running-ng, whose switches are its compiler cache, and
# adding named switches to someone else's root is how that gets confusing.
#
# NOTE: `make switch` builds a compiler and takes opam's root lock. Don't run it
# while a benchmark is running -- opam would serialise against running-ng's own
# provisioning. `make check-idle` tells you whether it is safe.

# The capnp schema compiler is a system tool (schema codegen in rpc/); on
# machines without sudo it is built from source into ~/.local/bin.
export PATH := $(HOME)/.local/bin:$(PATH)

OCAML_VERSION ?= 5.4.1
OPAM          ?= opam
SWITCH        ?= .
OPAMRUN        = $(OPAM) exec --switch=$(SWITCH) --
DUNE           = $(OPAMRUN) dune

# Sibling repos we read (never write): the runner and the data contract.
RUNNING_NG_SRC  ?= $(HOME)/running-ng/src
RUNNING_NG_REPO ?= $(HOME)/running-ng
RUNNING_NG_REF  ?= origin/adding-ocaml-support
VOCAB           ?= $(HOME)/ocaml-bench-dashboard/schema/json/vocab.json

.PHONY: all switch deps build test live check fixtures clean distclean check-idle help

all: build

## switch: create the local ./_opam switch and install dependencies
# --repositories=default pins the switch to the stock opam repo: machines
# that run running-ng accumulate overlay repos (relocatable, oxcaml) in the
# opam root, and if one sits in the root's default selection a plain switch
# create silently builds a patched compiler.  Bitten on two machines.
switch: check-idle
	$(OPAM) switch create $(SWITCH) ocaml-base-compiler.$(OCAML_VERSION) \
	  --repositories=default --no-install --yes
	$(MAKE) deps

## deps: install/refresh dependencies into the local switch
deps:
	$(OPAM) install --switch=$(SWITCH) --yes --deps-only --with-test .

## build: build the library and bench-gen
build:
	$(DUNE) build

## test: table tests against test/fixtures (no python, no network, no machine)
test:
	$(DUNE) test --force

## live: generate from the LIVE sibling repos and validate through running-ng
live: build
	VOCAB=$(VOCAB) SWITCH=$(SWITCH) RUNNING_NG_REPO=$(RUNNING_NG_REPO) \
	  RUNNING_NG_REF=$(RUNNING_NG_REF) ./scripts/live_check.sh

## check: everything that must pass before a commit
check: build test live

## fixtures: refresh the test snapshots from a pinned running-ng ref
# From a REF, not the working copy: the checkout moves between feature branches,
# and a fixture captured from one of them silently changes what the tests mean.
fixtures:
	git -C $(RUNNING_NG_REPO) show \
	  $(RUNNING_NG_REF):src/running/config/base/ocaml/macro_base.yml \
	  > $(CURDIR)/_fixture_base.yml
	python3 scripts/rng_helper.py facts --config $(CURDIR)/_fixture_base.yml \
	  > test/fixtures/facts_macro_base.json
	rm -f $(CURDIR)/_fixture_base.yml
	cp $(VOCAB) test/fixtures/vocab.json
	@git -C $(RUNNING_NG_REPO) rev-parse --short $(RUNNING_NG_REF)
	@echo "Fixtures refreshed. Update test/fixtures/PROVENANCE with the"
	@echo "running-ng commit and branch they came from, then re-run 'make test'."

## check-idle: refuse to disturb a benchmark in progress
# The bracket in "[p]ython3" stops pgrep matching the shell that runs this
# recipe -- its own command line contains the pattern otherwise.
check-idle:
	@if pgrep -f "[p]ython3 -m running" >/dev/null 2>&1; then \
	  echo "A running-ng run is in progress -- wait for it to finish."; exit 1; \
	fi
	@echo "no benchmark running"

clean:
	$(DUNE) clean

distclean: clean
	rm -rf _opam

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
