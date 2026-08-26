#!/usr/bin/env bash
# One-time setup on a (new) server host -- a laptop today, a VPS later.
#
# Installs nothing system-wide; it checks the prerequisites, clones the
# sibling repos the server reads (running-ng for the base config and its
# validators, ocaml-bench-dashboard for the contract vocabulary), and builds
# the repo-local opam switch.  Linux and macOS.
#
# Prerequisites:
#   git, opam, python3 with PyYAML  (macOS: Homebrew's python refuses pip --
#     put PyYAML in a venv and expose a python3 WRAPPER SCRIPT in
#     ~/.local/bin; a symlink loses the venv)
#   the capnp schema compiler       (apt: capnproto / brew: capnp)
#     -- no sudo? build it from source into ~/.local (see README), this
#        script and the Makefile look in ~/.local/bin.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

missing=0
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "MISSING: $1  ($2)"; missing=1; }
}
need git "apt/brew install git"
need opam "https://opam.ocaml.org/doc/Install.html"
need python3 "apt/brew install python3"
need capnp "apt install capnproto / brew install capnp, or build into ~/.local"
python3 -c 'import yaml' 2>/dev/null \
  || { echo "MISSING: PyYAML  (pip3 install pyyaml)"; missing=1; }
[ "$missing" -eq 0 ] || exit 1

clone() {
  local dir="$1" url="$2"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch origin --quiet && echo "fetched   $dir"
  else
    git clone --quiet "$url" "$dir" && echo "cloned    $dir"
  fi
}
clone "${RUNNING_NG_REPO:-$HOME/running-ng}" https://github.com/udesou/running-ng
clone "${DASHBOARD_REPO:-$HOME/ocaml-bench-dashboard}" https://github.com/udesou/ocaml-bench-dashboard
# the server pins macro-benches to a sha per run spec, so it needs the checkout
clone "${MACRO_BENCHES_REPO:-$HOME/macro-benches}" https://github.com/ocaml-bench/macro-benches

cd "$ROOT"
[ -d _opam ] || make switch
# An existing switch may predate a dependency change (bitten on macOS when
# the capnp packages arrived): deps is idempotent, so always refresh.
make deps build test

echo
echo "Setup complete. Next:"
echo "  1. cp service.example.json service.json   # allowlist, admins, machines"
echo "  2. edit server.env                        # public address (see docs/DEPLOY.md)"
echo "  3. scripts/serve.sh                       # writes the .cap files and serves"
