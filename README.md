# ocaml-bench-service

A comment-triggered benchmarking service for OCaml compiler PRs. Someone writes
`/bench` on a pull request; the service schedules a run on a bench machine,
publishes contract artifacts, and reports back with a summary and a dashboard
link.

The full design — architecture, resolved concerns, staged plan — is
`~/benchmarking-service-design.md`. **Read that first.**

## What exists today (stage S0)

The **request generator**: a `/bench` comment plus already-pinned runtimes in,
a validated running-ng run spec out. Nothing runs benchmarks yet.

```
bench-gen parse --comment "/bench tag=small iterations=1"
bench-gen help  --service-config service.json
bench-gen authz --service-config service.json --login someone
bench-gen spec  --comment "/bench" \
                --variant version:base:5.5.0 \
                --variant commit:pr-1234:c0f8c8ceef751fb3a99652d3d52399db3d1c2aae \
                --out /tmp --check
```

`spec` prints the generated config, the environment to run it with, and a cost
estimate; `--check` additionally pushes the config through running-ng's real
`validate()` + `validate_tags()`.

## The pieces this sits between

| Repo | Owns |
|---|---|
| `~/running-ng` | the runner: builds compilers and benchmarks, measures, emits contract artifacts |
| `~/macro-benches` | the benchmark suites and their input-size ladders |
| `~/ocaml-bench-dashboard` | the **data contract**, the ingestor, the dashboard |
| this repo | the request grammar, scheduling, and reporting around them |

We deliberately reimplement none of their semantics. `scripts/rng_helper.py` is
the only bridge to running-ng, and it exists so that config merge rules, tag
filtering and validation have exactly one implementation — theirs.

## The comment grammar

```
/bench                      # default set, 3 iterations
/bench vs=trunk             # choose the baseline
/bench vs=5.4.1,trunk       # compare more than two runtimes
/bench tag=small            # small | default | large | huge | legacy | all
/bench iterations=5         # up to 10
/bench sweep=s:262144,524288;o:80,120
/bench cancel
/bench help
```

The baseline defaults to the PR's merge base, so a bare `/bench` answers "does
this PR change performance?". `/bench help` is generated from the live base
config and the contract's `vocab.json`, so it cannot go stale.

Deliberately **not** in the prototype: tool selection (`perf_grp1` is always
attached, which is also what collects olly metrics) and explicit benchmark
lists. Both are additive later; removing them once people rely on them would
not be.

## Build and test

Self-contained: `make switch` creates a repo-local `./_opam` switch pinned to
ocaml-base-compiler 5.4.1 and installs deps from the committed
`ocaml-bench-service.opam`. Nothing depends on a switch that happens to exist on
the machine, and the active switch is never touched. `make distclean` removes it.

```sh
make switch          # once (refuses to run while a benchmark is in progress)
make build
make test            # 85 checks, fixtures only: no python, network, or machine
make live            # generate against running-ng and validate through it
make check           # all three
```

`make test` runs against snapshots in `test/fixtures/`, so it fails only when the
generator changes. `make live` generates from `origin/adding-ocaml-support` and
pushes each config through running-ng's real `validate()`, so it fails when the
base config moves. If live fails and test passes, `make fixtures` — see
`test/fixtures/PROVENANCE`.

Both read running-ng from a **pinned ref**, not the working copy, which may sit
on any of a dozen feature branches. Override with `RUNNING_NG_REF=` or
`BASE_CONFIG=` to develop against an unmerged change.

## Configuration

Copy `service.example.json` to `service.json` (gitignored) and edit. It holds
the bot account and the name of the env var carrying its token (never the token),
the trigger allowlist, and the machine registry. All three are config so that
swapping the bot account, extending the allowlist, or adding a machine is an
edit rather than a deploy.
