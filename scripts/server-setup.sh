#!/usr/bin/env bash
# One-time setup on a server host: checks prerequisites, clones the sibling
# repos the server reads into the server's own state dir (never $HOME/<repo>
# working checkouts), and builds the repo-local opam switch.
#
# Env: BENCH_STATE_DIR (default ~/.ocaml-bench-service)
#      BENCH_GIT_DIR   (default <state>/git)
#      BENCH_OPAMROOT  (default: the ambient opam root; set it on a host that
#                       also runs a bench agent, so setup does not contend for
#                       the agent's opam root lock)
#
# macOS: Homebrew's python refuses pip; put PyYAML in a venv and expose a
# python3 wrapper script in ~/.local/bin (a symlink loses the venv).  capnp
# without sudo: build it into ~/.local (see README).

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# On a double-role host (server + bench agent), `make switch` must not take the
# opam root lock that running-ng's provisioning holds mid-run.
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
# node builds the per-run dashboards (scripts/dashboard_builder.sh)
need node "apt install nodejs npm / brew install node (>= 18)"
need npm "apt install npm / comes with node"
python3 -c 'import yaml' 2>/dev/null \
  || { echo "MISSING: PyYAML  (pip3 install pyyaml)"; missing=1; }
[ "$missing" -eq 0 ] || exit 1

# A donor is an optimisation only: an existing local clone seeds the first
# clone, then origin is repointed at upstream.  No --reference: alternates would
# make the server's objects depend on a tree it does not own.
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
# The server only needs git metadata from these two (rev-parse for pins,
# archive/fetch for bump), so a bare clone suffices.
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
# full clones: the daemon extracts running-ng's tree from its pin, and the
# dashboard checkout is where per-run dashboards are built
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
# deps is idempotent; an existing switch may predate a dependency change.
make deps build test

# scripts/dashboard_builder.sh runs `npm run build` in the dashboard checkout;
# that needs node_modules and the OCaml ingestor, built in our local switch.
dash="${DASHBOARD_REPO:-$GITDIR/ocaml-bench-dashboard}"
if [ ! -d "$dash/node_modules" ]; then
  echo "installing dashboard node modules..."
  (cd "$dash" && npm install --no-fund --no-audit)
fi
# The ingestor validates runs against the contract it was built from, and the
# dashboard repo gitignores bin/, so a checkout that moved past the binary makes
# every build fail with "Unable to load measurements.json"
# (ocaml-bench-dashboard#2).  Rebuild when the binary is older than the sources.
ingest_is_stale() {
  [ -x "$dash/bin/ingest" ] || return 0
  [ -n "$(find "$dash/lib" "$dash/ingest" "$dash/dune-project" \
            -newer "$dash/bin/ingest" -print -quit 2>/dev/null)" ]
}
if ingest_is_stale; then
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
