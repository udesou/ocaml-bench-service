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

# The bridge imports running-ng's PYTHON too, and it must come from the SAME
# pinned ref as the config -- validating a ref's config with another branch's
# code is exactly the drift this script exists to catch (bitten for real when
# running-ng #13 changed the benchmarks: entry shape and the working copy was
# elsewhere).  RUNNING_NG_SRC still overrides, for testing unmerged running-ng
# changes on purpose.
if [ -z "${RUNNING_NG_SRC:-}" ] && [ -z "${BASE_CONFIG:-}" ]; then
  git -C "$RUNNING_NG_REPO" archive "$RUNNING_NG_REF" src | tar -x -C "$OUT"
  RUNNING_NG_SRC="$OUT/src"
fi
SRC_ARGS=()
[ -n "${RUNNING_NG_SRC:-}" ] && SRC_ARGS=(--running-ng-src "$RUNNING_NG_SRC")

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
          "${SRC_ARGS[@]}" --variant "$BASE_V" --variant "$HEAD_V" \
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
          "${SRC_ARGS[@]}" --variant "$HEAD_V" --request-id "live-$n" --out "$OUT" --check 2>&1)
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
          "${SRC_ARGS[@]}" --variant "$BASE_V" --variant "$HEAD_V" \
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
check        "bare /bench"            "/bench"
check        "tag=small"              "/bench tag=small"
check        "tag=large invocations=1" "/bench tag=large invocations=1"
check        "tag=legacy"             "/bench tag=legacy invocations=1"
check        "tag union"              "/bench tag=small,legacy invocations=1"
check        "sweep s and o"          "/bench invocations=1 sweep=s:262144,524288;o:80,120 force=true"
check        "tag=all forced"         "/bench tag=all invocations=1 force=true"
check_single "single runtime"         "/bench invocations=1"

echo
echo "refusals:"
check_rejects "unknown tag"     "/bench tag=nosuchtag"      "Unknown benchmark set"
check_rejects "coverage gap"    "/bench tag=ephemerons"     "coverage gap"
check_rejects "over the cap"    "/bench tag=all"            "over the"
check_rejects "unsweepable"     "/bench sweep=nonsense:1"   "Cannot sweep"
check_rejects "old spelling"    "/bench iterations=1"       "invocations="

echo
echo "client -> server over Cap'n Proto (bench-serve + bench-cli):"
SVC="$OUT/service.json"
STATE="$OUT/state"
cat > "$SVC" <<EOF
{ "bot": {"account":"bot","token_env":"TOK"},
  "results_repo":"u/r",
  "allowlist":["tester"], "admins":["tester"],
  "machines":[{"name":"monolith","default":true,
               "macro_bench_dir":"$HOME/macro-benches","log_dir":"$OUT/logs"}] }
EOF
opam exec --switch="$SWITCH" -- dune exec --no-build bin/bench_serve.exe -- \
  --service-config "$SVC" --state-dir "$STATE" --resolver offline \
  --base-config "$BASE" --vocab "$VOCAB" "${SRC_ARGS[@]}" \
  --listen "unix:$OUT/server.sock" > "$OUT/serve.log" 2>&1 &
SERVE_PID=$!
trap 'kill "$SERVE_PID" 2>/dev/null; rm -rf "$OUT"' EXIT
for _ in $(seq 1 100); do
  [ -f "$STATE/caps/tester.cap" ] && break
  sleep 0.2
done
if [ ! -f "$STATE/caps/tester.cap" ]; then
  echo "  FAIL  bench-serve did not come up"
  sed 's/^/          /' "$OUT/serve.log" | tail -10
  fails=$((fails + 1))
else
  cli() {
    local sub="$1"; shift
    opam exec --switch="$SWITCH" -- dune exec --no-build bin/bench_cli.exe -- \
      "$sub" --cap "$STATE/caps/tester.cap" "$@"
  }
  n=$((n + 1))
  ack=$(cli submit "/bench tag=small invocations=1 vs=5.5.0,c0f8c8ceef751fb3a99652d3d52399db3d1c2aae" 2>&1)
  run_id=$(grep -oE 'run-[0-9]{8}-[0-9]{3}' <<<"$ack" | head -1)
  if [ -n "$run_id" ] \
     && cli status "$run_id" 2>&1 | grep -q '"state": "queued"' \
     && cli list 2>&1 | grep -q "$run_id" \
     && cli cancel "$run_id" 2>&1 | grep -q "cancelled $run_id" \
     && [ -f "$STATE/runs/$run_id/runspec.json" ]; then
    echo "  ok    submit -> status -> list -> cancel over the socket ($run_id)"
  else
    echo "  FAIL  bench-cli round trip"
    sed 's/^/          /' <<<"$ack" | tail -8
    sed 's/^/          /' "$OUT/serve.log" | tail -6
    fails=$((fails + 1))
  fi
  n=$((n + 1))
  # a refused command exits 1 on purpose; capture first (pipefail)
  refusal=$(cli submit "/bench iterations=1" 2>&1 || true)
  if grep -q "invocations=" <<<"$refusal"; then
    echo "  ok    refusals travel the wire verbatim"
  else
    echo "  FAIL  wire refusal"
    sed 's/^/          /' <<<"$refusal" | tail -4
    fails=$((fails + 1))
  fi
  kill "$SERVE_PID" 2>/dev/null
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "$n live cases, all passed"
else
  echo "$n live cases, $fails FAILED"
  exit 1
fi
