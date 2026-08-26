#!/usr/bin/env bash
# Run the request server with one deployment's settings.
#
#   scripts/serve.sh [server.env]
#
# Everything machine-specific lives in the env file, so moving the service to
# a different host is: copy the state dir (it holds the queue AND the server's
# secret key, i.e. its identity), run this script there.  If
# BENCH_PUBLIC_ADDRESS is a DNS name that moves with the service, the
# capability files people already hold stay valid -- nothing to redistribute.

set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ENV_FILE="${1:-$ROOT/server.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

: "${BENCH_STATE_DIR:=$HOME/.ocaml-bench-service}"   # queue + keys + caps
: "${BENCH_LISTEN:=tcp:0.0.0.0:7000}"
: "${BENCH_PUBLIC_ADDRESS:=}"                        # tcp:bench.example.org:7000
: "${BENCH_SERVICE_CONFIG:=$ROOT/service.json}"
: "${BENCH_RESOLVER:=github}"                        # offline for hermetic use
: "${BENCH_BASE_URL:=http://localhost}"              # links in acknowledgements
: "${RUNNING_NG_REPO:=$HOME/running-ng}"
: "${RUNNING_NG_REF:=origin/adding-ocaml-support}"
: "${VOCAB:=$HOME/ocaml-bench-dashboard/schema/json/vocab.json}"

[ -f "$BENCH_SERVICE_CONFIG" ] \
  || { echo "no $BENCH_SERVICE_CONFIG -- cp service.example.json service.json and edit"; exit 1; }

mkdir -p "$BENCH_STATE_DIR"

# The base config AND running-ng's python come from the PINNED ref, never the
# working copy: that checkout moves between feature branches (same rule as
# make live).  The extracted tree lives in the state dir and is refreshed on
# every start.
BASE="$BENCH_STATE_DIR/macro_base.yml"
git -C "$RUNNING_NG_REPO" show \
  "$RUNNING_NG_REF:src/running/config/base/ocaml/macro_base.yml" > "$BASE" \
  || { echo "cannot read $RUNNING_NG_REF from $RUNNING_NG_REPO (git fetch first?)"; exit 1; }
RNG_SRC_DIR="$BENCH_STATE_DIR/running-ng-src"
rm -rf "$RNG_SRC_DIR" && mkdir -p "$RNG_SRC_DIR"
git -C "$RUNNING_NG_REPO" archive "$RUNNING_NG_REF" src | tar -x -C "$RNG_SRC_DIR"

args=(
  --service-config "$BENCH_SERVICE_CONFIG"
  --state-dir "$BENCH_STATE_DIR"
  --listen "$BENCH_LISTEN"
  --resolver "$BENCH_RESOLVER"
  --base-url "$BENCH_BASE_URL"
  --base-config "$BASE"
  --vocab "$VOCAB"
  --running-ng-src "$RNG_SRC_DIR/src"
  --running-ng-dir "$RUNNING_NG_REPO"
  --running-ng-ref "$RUNNING_NG_REF"
  --helper "$ROOT/scripts/rng_helper.py"
)
[ -n "$BENCH_PUBLIC_ADDRESS" ] && args+=( --public-address "$BENCH_PUBLIC_ADDRESS" )

cd "$ROOT"
exec opam exec --switch=. -- dune exec bin/bench_serve.exe -- "${args[@]}"
