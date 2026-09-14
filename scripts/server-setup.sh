#!/usr/bin/env bash
# One-time setup on a (new) server host -- a laptop today, a VPS later.
#
# Installs nothing system-wide; it checks the prerequisites, clones the
# sibling repos the server reads (running-ng for the base config and its
# validators, ocaml-bench-dashboard for the contract vocabulary) INTO THE
# SERVER'S OWN STATE DIR, and builds the repo-local opam switch.  Linux,
# macOS and FreeBSD; nothing here is GNU-specific.
#
# Hermetic by construction: the service reads and writes only <state>/ and
# this repo's ./_opam.  It never touches $HOME/<repo> working checkouts (it
# may READ one as a clone donor, see below) and never touches a bench agent's
# ~/.bench-agent.  On a host with a double role, also set BENCH_OPAMROOT so
# the service does not contend for the agent's opam root lock while a
# benchmark is running.
#
# Env: BENCH_STATE_DIR (default ~/.ocaml-bench-service)
#      BENCH_GIT_DIR   (default <state>/git)
#      BENCH_OPAMROOT  (default: the ambient opam root)
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

# A double-role host (server + bench agent) must not have `make switch` take
# the root lock that running-ng's switch provisioning is holding mid-run.
# Opt-in rather than the default: a private root re-downloads and rebuilds a
# compiler, which is a real cost for the common single-role case, and the
# service only touches opam at SETUP time.
if [ -n "${BENCH_OPAMROOT:-}" ]; then
  export OPAMROOT="$BENCH_OPAMROOT"
  echo "opam root: $OPAMROOT"
fi

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

# --- the server's own clones ------------------------------------------------
# Under the state dir, NOT $HOME/<repo>.  $HOME/<repo> is where a person
# develops these repos, and on a host with a double role it is also where the
# bench agent lives; the service must not fetch into, build in, or archive
# trees out of anyone else's working copy.  Everything here is overridable,
# so pointing the service at a working checkout stays possible -- but it is
# then a deliberate act, not the default.
#
# A DONOR is an optimisation only: an existing local clone of the same repo is
# used as the object source for the first clone (no cold pull), after which
# origin is repointed at upstream and the server fetches for itself.  No
# --reference: alternates would make the server's objects depend on a tree it
# does not own, which is the coupling this is removing.
STATE="${BENCH_STATE_DIR:-$HOME/.ocaml-bench-service}"
GITDIR="${BENCH_GIT_DIR:-$STATE/git}"
mkdir -p "$GITDIR"

seed_from() {   # echo a usable donor path for repo $1, or nothing
  local donor="$1"
  [ -n "$donor" ] && git -C "$donor" rev-parse --git-dir >/dev/null 2>&1 \
    && printf '%s' "$donor"
}

clone() {
  local dir="$1" url="$2" donor="${3:-}"
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$dir" fetch origin --quiet && echo "fetched   $dir"
    return
  fi
  local src="$url" via=""
  if [ -n "$(seed_from "$donor")" ]; then src="$donor"; via=" (seeded from $donor)"; fi
  git clone --quiet "$src" "$dir"
  git -C "$dir" remote set-url origin "$url"
  git -C "$dir" fetch origin --quiet
  echo "cloned    $dir$via"
}
# The server only needs GIT METADATA from these two (rev-parse for pins,
# archive/fetch for bump), so a bare clone with normal remote-tracking refs
# suffices.  A BENCH machine needs real working trees -- that is the agent's
# setup, not this one.
clone_bare() {
  local dir="$1" url="$2" donor="${3:-}"
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$dir" fetch origin --quiet && echo "fetched   $dir"
    return
  fi
  local src="$url" via=""
  if [ -n "$(seed_from "$donor")" ]; then src="$donor"; via=" (seeded from $donor)"; fi
  git clone --quiet --bare "$src" "$dir"
  git -C "$dir" remote set-url origin "$url"
  git -C "$dir" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$dir" fetch origin --quiet
  echo "cloned    $dir (bare)$via"
}
# full: the daemon extracts running-ng's tree from its pin, and the dashboard
# checkout serves vocab.json AND is where per-run dashboards are built
clone "${RUNNING_NG_REPO:-$GITDIR/running-ng}" \
      https://github.com/udesou/running-ng "$HOME/running-ng"
clone "${DASHBOARD_REPO:-$GITDIR/ocaml-bench-dashboard}" \
      https://github.com/udesou/ocaml-bench-dashboard "$HOME/ocaml-bench-dashboard"
# metadata-only on a server host: pinned into specs, never built here
clone_bare "${MACRO_BENCHES_REPO:-$GITDIR/macro-benches}" \
      https://github.com/ocaml-bench/macro-benches "$HOME/macro-benches"
clone_bare "${OLLY_REPO:-$GITDIR/runtime_events_tools}" \
      https://github.com/tarides/runtime_events_tools "$HOME/runtime_events_tools"

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
dash="${DASHBOARD_REPO:-$GITDIR/ocaml-bench-dashboard}"
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
