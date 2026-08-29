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
# node drives the per-run dashboard builds (scripts/dashboard_builder.sh),
# which the webview links; a server without it is missing a deliverable.
need node "apt install nodejs npm / brew install node (>= 18)"
need npm "apt install npm / comes with node"
python3 -c 'import yaml' 2>/dev/null \
  || { echo "MISSING: PyYAML  (pip3 install pyyaml)"; missing=1; }
[ "$missing" -eq 0 ] || exit 1

clone() {
  local dir="$1" url="$2"
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$dir" fetch origin --quiet && echo "fetched   $dir"
  else
    git clone --quiet "$url" "$dir" && echo "cloned    $dir"
  fi
}
# The server only needs GIT METADATA from these two (rev-parse for pins,
# archive/fetch for bump), so a bare clone with normal remote-tracking refs
# suffices.  A BENCH machine needs real working trees -- that is the agent's
# setup, not this one.  (An existing full clone is left as it is.)
clone_bare() {
  local dir="$1" url="$2"
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$dir" fetch origin --quiet && echo "fetched   $dir"
  else
    git clone --quiet --bare "$url" "$dir"
    git -C "$dir" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C "$dir" fetch origin --quiet
    echo "cloned    $dir (bare)"
  fi
}
# full: the daemon extracts running-ng's tree from its pin, and dev flows
# (make live, bench-gen) read it; the dashboard checkout serves vocab.json
clone "${RUNNING_NG_REPO:-$HOME/running-ng}" https://github.com/udesou/running-ng
clone "${DASHBOARD_REPO:-$HOME/ocaml-bench-dashboard}" https://github.com/udesou/ocaml-bench-dashboard
# metadata-only on a server host: pinned into specs, never built here
clone_bare "${MACRO_BENCHES_REPO:-$HOME/macro-benches}" https://github.com/ocaml-bench/macro-benches
clone_bare "${OLLY_REPO:-$HOME/runtime_events_tools}" https://github.com/tarides/runtime_events_tools

cd "$ROOT"
[ -d _opam ] || make switch
# An existing switch may predate a dependency change (bitten on macOS when
# the capnp packages arrived): deps is idempotent, so always refresh.
make deps build test

# --- the dashboard build chain (per-run dashboards, §10) ---------------------
# scripts/dashboard_builder.sh runs `npm run build` in the dashboard checkout
# for every finished run; that needs node_modules and the OCaml ingestor.
# Both are one-time products of the checkout -- produce them here so a fresh
# server host works without following another repo's README.  The ingestor
# builds in OUR local switch (its deps land in ./_opam), so no extra switch
# appears in the opam root.
dash="${DASHBOARD_REPO:-$HOME/ocaml-bench-dashboard}"
if [ ! -d "$dash/node_modules" ]; then
  echo "installing dashboard node modules..."
  (cd "$dash" && npm install --no-fund --no-audit)
fi
if [ ! -x "$dash/bin/ingest" ]; then
  echo "building the dashboard ingestor..."
  opam install --switch="$ROOT" --yes --deps-only "$dash"
  (cd "$dash" && opam exec --switch="$ROOT" -- dune build ingest/ingest.exe)
  mkdir -p "$dash/bin"
  cp -f "$dash/_build/default/ingest/ingest.exe" "$dash/bin/ingest"
  echo "built     $dash/bin/ingest"
fi

echo
echo "Setup complete. Next:"
echo "  1. cp service.example.json service.json   # allowlist, admins, machines"
echo "  2. edit server.env                        # public address (see docs/DEPLOY.md)"
echo "  3. scripts/serve.sh                       # writes the .cap files and serves"
