#!/usr/bin/env bash
# One-time setup on a bench machine (the host bench-agent runs on).  Checks
# prerequisites (running-ng's install_deps_linux.sh installs the heavy ones),
# seeds the agent's private clones under $BENCH_AGENT_STATE/git, and builds
# this repo's local switch.  macro-benches' `make setup` (vendoring) is left to
# the agent, which runs it supervised on its first claim and after every bump.
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

# The clone's origin always ends up at the canonical remote so later fetches
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

# The vendored trees are gitignored products of `make setup`; copying them from
# the donor lets the agent's supervised setup skip the big re-pull.
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
