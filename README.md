# ocaml-bench-service

This repo contains the infrastructure for a benchmarking service for the OCaml compiler.
It works by processing comments in pull requests or requesting a benchmark run via CLI.

Users may write a comment in the PR, or send requests via CLI indicating for instance: which benchmarks to use,
which runtimes to compare, how many invocations or parameters to sweep. The results
can then be tracked in a webview/dashboard and are reported back to the user in the same PR.

This service adds a request-and-scheduling layer around three existing pieces: the
[running-ng](https://github.com/udesou/running-ng) benchmark orchestrator, the
[macro-benches](https://github.com/ocaml-bench/macro-benches) suites, and the
[ocaml-bench-dashboard](https://github.com/udesou/ocaml-bench-dashboard), which contains
the data contract (e.g, what metrics are output) and a dashboard to visualize the results.

## What using it looks like

Comment on a pull request (or use `bench-cli` from a terminal):

```
/bench tag=small invocations=3
```

The bot then replies with an acknowledgement: which compilers
resolved, how many programs and invocations the command defines, a time estimate, and a
link to the run's live page. When the run finishes, a second comment carries
the results, for instance:

> **Candidate `ocaml-5.5.0` vs baseline `ocaml-5.4.1`** (deltas relative
> to the baseline; negative = `ocaml-5.5.0` is better)
>
> | benchmark | wall | instructions | max RSS |
> |---|---|---|---|
> | `irmin_mem_rw` | +0.5% | +3.6% ⬆ | -32.8% ⬇ |

Every run can be tracked in a **live page** and **dashboard** containing graphs to visualize the results.

## The comment grammar

```
/bench                      # default set, 3 invocations (~1h)
/bench vs=trunk             # choose the baseline
/bench vs=5.4.1,trunk       # compare more than two compilers
/bench vs=5.5.0,5.5.0+fp    # build flavors: +fp (frame pointers), +flambda;
                            #   combine them: 5.5.0+fp+flambda
/bench tag=small            # small | default | large | huge | legacy | all
/bench tag=small,large      # several sets: their union
/bench invocations=5        # fresh-process repetitions, up to 10
/bench sweep=s:262144,524288;o:80,120
/bench machine=<name>       # when more than one is registered
/bench force=true           # run despite the cost limit (admin-only)
/bench priority=top         # jump the queue (admin-only)
/bench cancel <run-id>      # the id is in the run's acknowledgement
/bench continue <run-id>    # finish a terminal run's missing cells: keeps
                            #   completed results, retries failed builds
/bench rerun                # clean slate: rebuild everything
/bench help                 # help about the commands.
```

When commenting in a PR, the baseline defaults to the PR's merge base. 
Sweep parameters may take either the `OCAMLRUNPARAM` letter (`o`) or the 
parameter's name (`space_overhead`). 

## Who can trigger a run

We maintain an allowlist of GitHub logins. Contact @tmcgilchrist or @udesou to
be added to it.

## How it is put together

One server, one agent, and static pages:

- **`bench-serve`** owns the request side: grammar, allowlist, request
  validation, and constructing a run spec. Access is a [**capability file**](https://capnproto.org): the
  daemon writes one per configured login, and handing someone their file is
  granting access.
- **`bench-agent`** lives on the bench machine and dials out. It claims work,
  checks out the exact pinned sources, runs the orchestrator under a timeout in
  its own process group, heartbeats every 30 seconds (a cancellation arrives as
  the reply), and uploads the artifacts.
- **The webview** is static pages over the store's files: a runs index, a
  per-run page, and one dashboard per finished run.
- **The bot** posts whatever markdown the server renders, verbatim: the
  acknowledgement, refusals, and the completion with its result tables.

## Running your own

Server host (Linux or macOS):

```sh
scripts/server-setup.sh              # checks prerequisites, clones, builds
cp service.example.json service.json # allowlist, admins, machines
cp server.env.example server.env     # addresses, Pages repo
scripts/start_server.sh              # server + webview + bot + dashboards
                                     # + pages, in one screen session
```

Bench machine:

```sh
scripts/agent-setup.sh               # checks prerequisites, seeds clones
scp server:~/.ocaml-bench-service/caps/agent-<machine>.cap .
until BENCH_AGENT_CAP=agent-<machine>.cap \
  ./_build/default/bin/bench_agent.exe; do sleep 5; done
```

The whole recipe, including wiring the fork's GitHub Action and moving the
service between hosts, is in [docs/DEPLOY.md](docs/DEPLOY.md).

## Build and test

Self-contained: `make switch` creates a local switch in `./_opam` pinned to
ocaml-base-compiler 5.4.1. `make distclean`
removes it.

```sh
make switch          # once; refuses to run while a benchmark is in progress
make build
make test            # table tests
make live            # generate against running-ng and validate through it
make check           # all three
```

You also need `python3` with PyYAML, a checkout of running-ng, and the
`capnp` schema compiler.

`make test` runs against snapshots, so it fails only when this repo changes;
`make live` pushes generated configs through running-ng's real validators, so
it fails when the benchmark definitions move. If live fails and test passes,
run `make fixtures`.

## Repository layout

| path | contents |
|---|---|
| `lib/api.ml` | the Request API: the types and module signature every requester speaks |
| `lib/server.ml` | the request server: queue, execution protocol, completion notices |
| `lib/resolver.ml` | user input to pinned compilers: releases, branches, PR heads, merge bases (plain git) |
| `lib/request.ml` | the comment grammar |
| `lib/gen.ml` | request + suite definitions to a running-ng config |
| `lib/report.ml` | contract to report.md: per-metric verdicts with noise gates |
| `lib/runspec.ml` | the run spec, specified in [docs/RUNSPEC.md](docs/RUNSPEC.md) |
| `lib/run_key.ml` | the content identity of a measurement (result reuse) |
| `lib/cost.ml` | the estimate and the budget limit |
| `lib/authz.ml`, `lib/service_config.ml` | allowlist, roles, bot identity, machine registry |
| `lib/facts.ml`, `lib/help.ml`, `lib/tag_alias.ml` | the live view of running-ng's suites and tags, and the generated `/bench help` |
| `lib/bridge.ml`, `scripts/rng_helper.py` | the only path to running-ng's own logic |
| `rpc/` | the Cap'n Proto adapter: schema and service/client glue |
| `bin/bench_serve.ml` | the server daemon; writes the capability files |
| `bin/bench_agent.ml` | the bench machine daemon |
| `bin/bench_cli.ml` | the thin client |
| `bin/main.ml` | `bench-gen`, a developer tool |
| `bot/` | the `/bench` PR bot, Action and polling flavours |
| `webview/`, `scripts/` | the static pages and the operational scripts |
| `test/`, `scripts/live_check.sh` | table tests and the live check |

## Licence

ISC.
