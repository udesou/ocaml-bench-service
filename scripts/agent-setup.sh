#!/usr/bin/env bash
# One-time setup on a (new) BENCH machine -- the host bench-agent runs on.
#
# Installs nothing system-wide: it CHECKS the prerequisites and errors with
# instructions.  For a truly bare machine, running-ng's own
# install_deps_linux.sh is the installer for the heavy things (opam itself,
# C libraries, perf); run it first, then this.
#
# What this script does:
#   1. prerequisite checks (git, opam >= 2.2, python3 + PyYAML, make, rsync,
#      setsid, capnp -- the last only to BUILD bench-agent from this repo)
#   2. seeds the agent's PRIVATE clones under $BENCH_AGENT_STATE/git --
#      the agent never touches anyone's personal checkouts.  A local donor
#      checkout is preferred when present (hardlinked clone, fast, and the
#      gitignored vendored trees are copied so the first run skips the big
#      re-pull); a bare machine falls back to the canonical URLs.
#   3. builds this repo's local switch (guarded: refuses while a benchmark
#      is running, because `make switch` takes the opam root lock)
#
# What it deliberately does NOT do: macro-benches' `make setup` (vendoring).
# The agent runs that itself, supervised and cancellable, on its first claim
# and again whenever a bump moves the benches pin -- one code path for the
# fresh machine and the bump.
#
# Environment:
#   BENCH_AGENT_STATE      agent state dir (default ~/.bench-agent)
#   RUNNING_NG_DONOR       local checkout to seed from (default ~/running-ng)
#   MACRO_BENCHES_DONOR    (default ~/macro-benches)
#   OLLY_DONOR             (default ~/runtime_events_tools)

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${BENCH_AGENT_STATE:-$HOME/.bench-agent}"

missing=0
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "MISSING: $1  ($2)"; missing=1; }
}
need git "apt install git"
need opam "running-ng/install_deps_linux.sh installs it, or https://opam.ocaml.org"
need python3 "apt install python3"
need make "apt install make"
need rsync "apt install rsync"
need setsid "util-linux (present on any normal Linux)"
need capnp "apt install capnproto, or build into ~/.local (see README)"
python3 -c 'import yaml' 2>/dev/null \
  || { echo "MISSING: PyYAML  (pip3 install pyyaml)"; missing=1; }
[ "$missing" -eq 0 ] || exit 1

# The opam root format needs >= 2.2 (running-ng shares the same root).
opam_ver=$(opam --version 2>/dev/null || echo 0)
case "$opam_ver" in
  2.[2-9]*|3.*) ;;
  *) echo "WARNING: opam $opam_ver found; >= 2.2 is required by the opam root."
     echo "         running-ng/install_deps_linux.sh upgrades it." ;;
esac

mkdir -p "$STATE/git"

# Seed one clone: donor checkout if present, canonical URL otherwise.  The
# clone's origin always ends up at the canonical remote so later fetches
# (bump adoption) reach upstream, not the donor.
seed() {
  local name="$1" donor="$2" url="$3" dir="$STATE/git/$1"
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "exists    $dir"
  elif git -C "$donor" rev-parse --git-dir >/dev/null 2>&1; then
    git clone --quiet "$donor" "$dir"
    local origin
    origin=$(git -C "$donor" remote get-url origin 2>/dev/null || echo "$url")
    git -C "$dir" remote set-url origin "$origin"
    echo "seeded    $dir  (from $donor, origin -> $origin)"
  else
    echo "cloning   $url -> $dir (no local donor; may take a while)"
    git clone --quiet "$url" "$dir"
  fi
}
seed running-ng "${RUNNING_NG_DONOR:-$HOME/running-ng}" \
  https://github.com/udesou/running-ng
seed macro-benches "${MACRO_BENCHES_DONOR:-$HOME/macro-benches}" \
  https://github.com/ocaml-bench/macro-benches
seed olly "${OLLY_DONOR:-$HOME/runtime_events_tools}" \
  https://github.com/tarides/runtime_events_tools

# The monorepo's vendored trees are gitignored products of its `make setup`,
# so a clone lacks them.  Copy them from the donor when it has them: the
# agent's supervised `make setup` then only patches and test-builds instead
# of re-pulling everything.
DONOR="${MACRO_BENCHES_DONOR:-$HOME/macro-benches}"
if [ -d "$DONOR/duniverse" ]; then
  for d in duniverse vendor _rocq_prefix; do
    [ -e "$DONOR/$d" ] && rsync -a "$DONOR/$d" "$STATE/git/macro-benches/"
  done
  echo "seeded    vendored trees from $DONOR"
fi

cd "$ROOT"
[ -d _opam ] || make switch
make deps build

echo
echo "Setup complete. Next:"
echo "  1. copy the machine's capability from the server:"
echo "       scp server:~/.ocaml-bench-service/caps/agent-<machine>.cap ."
echo "  2. run the agent (a supervisor loop restarts it on broken connections):"
echo "       until BENCH_AGENT_CAP=agent-<machine>.cap \\"
echo "         ./_build/default/bin/bench_agent.exe; do sleep 5; done"
echo "The first claim finishes macro-benches' own setup (vendoring),"
echo "supervised; with no donor checkout that can take a long while."
