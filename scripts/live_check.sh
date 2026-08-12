#!/usr/bin/env bash
# Live check: generate configs from the *working copies* of running-ng and
# ocaml-bench-dashboard, and push each one through running-ng's real validate()
# + validate_tags().
#
# The table tests in test/ run against snapshots so they only fail when the
# generator changes.  This script is the other half: it fails when the base
# config or the contract vocabulary moves under us.  If this fails while
# `dune test` passes, refresh test/fixtures (see test/fixtures/PROVENANCE).
#
# Nothing here provisions a switch, builds a compiler, or takes the opam lock:
# validate() never calls resolve_class().  Safe to run while a benchmark is
# running on the same machine.
#
# Usage: scripts/live_check.sh [--switch OPAM_SWITCH]

set -uo pipefail

# Default to the repo-local switch created by `make switch`.
SWITCH="${SWITCH:-.}"
[ "${1:-}" = "--switch" ] && SWITCH="$2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Read the base config from a PINNED REF, not from whatever branch the working
# copy happens to be on.  running-ng has a dozen feature branches; testing
# against the checked-out one makes this script fail for reasons that have
# nothing to do with the service (a branch that predates the ladder tags has no
# `small_run`, for instance).
#
# Override with BASE_CONFIG=<path> to test a working copy on purpose -- useful
# when developing against an unmerged running-ng change.
RUNNING_NG_REPO="${RUNNING_NG_REPO:-$HOME/running-ng}"
RUNNING_NG_REF="${RUNNING_NG_REF:-origin/adding-ocaml-support}"
BASE_IN_REPO="src/running/config/base/ocaml/macro_base.yml"

if [ -n "${BASE_CONFIG:-}" ]; then
  BASE="$BASE_CONFIG"
  echo "base config: $BASE (explicit)"
else
  BASE="$OUT/macro_base.yml"
  if ! git -C "$RUNNING_NG_REPO" show "$RUNNING_NG_REF:$BASE_IN_REPO" > "$BASE" 2>/dev/null
  then
    echo "cannot read $RUNNING_NG_REF:$BASE_IN_REPO from $RUNNING_NG_REPO"
    echo "(try: git -C $RUNNING_NG_REPO fetch origin)"
    exit 1
  fi
  echo "base config: $RUNNING_NG_REF:$BASE_IN_REPO"
fi
VOCAB="${VOCAB:-$HOME/ocaml-bench-dashboard/schema/json/vocab.json}"

BASE_V="version:base:5.5.0"
HEAD_V="commit:pr-1234:c0f8c8ceef751fb3a99652d3d52399db3d1c2aae"

run() { opam exec --switch="$SWITCH" -- dune exec --no-build bin/main.exe -- "$@"; }

echo "vocab:       $VOCAB"
opam exec --switch="$SWITCH" -- dune build 2>&1 || { echo "BUILD FAILED"; exit 1; }

fails=0
n=0

# Each case must generate AND pass running-ng's validators.
check() {
  local name="$1"; shift
  n=$((n + 1))
  local out
  out=$(run spec --comment "$1" --base-config "$BASE" --vocab "$VOCAB" \
          --variant "$BASE_V" --variant "$HEAD_V" \
          --request-id "live-$n" --out "$OUT" --check 2>&1)
  if grep -q '^# validate(): OK' <<<"$out"; then
    echo "  ok    $name"
  else
    echo "  FAIL  $name"
    sed 's/^/          /' <<<"$out" | tail -12
    fails=$((fails + 1))
  fi
}

# Same, but only one runtime: exercises the no-comparisons path, which
# validate() would reject if we emitted an unreferenced runtime.
check_single() {
  local name="$1"; shift
  n=$((n + 1))
  local out
  out=$(run spec --comment "$1" --base-config "$BASE" --vocab "$VOCAB" \
          --variant "$HEAD_V" --request-id "live-$n" --out "$OUT" --check 2>&1)
  if grep -q '^# validate(): OK' <<<"$out"; then
    echo "  ok    $name"
  else
    echo "  FAIL  $name"
    sed 's/^/          /' <<<"$out" | tail -12
    fails=$((fails + 1))
  fi
}

# A case that must be REFUSED, with the reason we expect.
check_rejects() {
  local name="$1" comment="$2" needle="$3"
  n=$((n + 1))
  local out
  out=$(run spec --comment "$comment" --base-config "$BASE" --vocab "$VOCAB" \
          --variant "$BASE_V" --variant "$HEAD_V" \
          --request-id "live-$n" --out "$OUT" 2>&1)
  if grep -qF "$needle" <<<"$out"; then
    echo "  ok    $name (refused)"
  else
    echo "  FAIL  $name: expected refusal containing '$needle'"
    sed 's/^/          /' <<<"$out" | tail -6
    fails=$((fails + 1))
  fi
}

echo
echo "generate + validate():"
check        "bare /bench"           "/bench"
check        "tag=small"             "/bench tag=small"
check        "tag=large iterations=1" "/bench tag=large iterations=1"
check        "tag=legacy"            "/bench tag=legacy iterations=1"
check        "sweep s and o"         "/bench iterations=1 sweep=s:262144,524288;o:80,120 force=true"
check        "tag=all forced"        "/bench tag=all iterations=1 force=true"
check_single "single runtime"        "/bench iterations=1"

echo
echo "refusals:"
check_rejects "unknown tag"     "/bench tag=nosuchtag"      "Unknown benchmark set"
check_rejects "coverage gap"    "/bench tag=ephemerons"     "coverage gap"
check_rejects "over the cap"    "/bench tag=all"            "over the"
check_rejects "unsweepable"     "/bench sweep=nonsense:1"   "Cannot sweep"

echo
if [ "$fails" -eq 0 ]; then
  echo "$n live cases, all passed"
else
  echo "$n live cases, $fails FAILED"
  exit 1
fi
