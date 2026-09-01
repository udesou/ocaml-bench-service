# ocaml-bench-service

Benchmarking for OCaml compiler pull requests, triggered from a comment.
Someone writes `/bench` on a PR; the service works out what to measure, runs
it on a dedicated machine, and reports back with a results table and a link
to a per-run dashboard.

It is the request-and-scheduling layer around three existing pieces: the
[running-ng](https://github.com/udesou/running-ng) benchmark runner, the
[macro-benches](https://github.com/ocaml-bench/macro-benches) suites, and the
[ocaml-bench-dashboard](https://github.com/udesou/ocaml-bench-dashboard) data
contract and viewer.

## What using it looks like

Comment on a pull request (or use `bench-cli` from a terminal):

```
/bench tag=small invocations=3
```

Within seconds the bot replies with an acknowledgement: which compilers
resolved (the PR head against its merge base, pinned to exact commits), how
many programs, configs and invocations that selects, a time estimate, and a
link to the run's live page. When the run finishes, a second comment carries
the results:

> **Candidate `ocaml-5.5.0` vs baseline `ocaml-5.4.1`** (deltas relative
> to the baseline; negative = `ocaml-5.5.0` is better)
>
> | benchmark | wall | instructions | max RSS |
> |---|---|---|---|
> | `irmin_mem_rw` | +0.5% | +3.6% ⬆ | -32.8% ⬇ |

Every run also gets:

- a **live page**: queued, then running with a phase timeline, then the
  measurements, report, console log and raw artifacts;
- a full **dashboard** built from its measurements: overview, absolute
  values, parameter sweeps, curves, space against time with Pareto
  frontiers;
- a public copy of all of it on **GitHub Pages**, where the results repo
  doubles as the archive. (provisionally)

## The `/bench` grammar

```
/bench                      # default set, 3 invocations (~1h)
/bench vs=trunk             # choose the baseline
/bench vs=5.4.1,trunk       # compare more than two compilers
/bench tag=small            # small | default | large | huge | legacy | all
/bench tag=small,large      # several sets: their union
/bench invocations=5        # fresh-process repetitions, up to 10
/bench sweep=s:262144,524288;o:80,120
/bench machine=<name>       # when more than one is registered
/bench force=true           # run despite the cost limit (admin-only)
/bench priority=top         # jump the queue (admin-only)
/bench cancel <run-id>      # the id is in the run's acknowledgement
/bench rerun                # clean slate: rebuild everything
/bench help                 # help about the commands.
```

The baseline defaults to the PR's merge base, so a bare `/bench` answers the
question *does this change performance?* using the default benchmarks and 3 
invocations to minimize noise. Sweep parameters take either the `OCAMLRUNPARAM` letter (`o`)
or the contract's canonical name (`space_overhead`).

## Who can trigger a run

We maintain an allowlist of GitHub logins. Please contact 
@tmcgilchrist or @udesou to be added to the allowlist.

## How it is put together

One server, one agent, and static pages:

- **`bench-serve`** owns the request side: grammar, allowlist, request validation,
  and construction a run spec. Access is a **capability file**: the daemon 
  writes one per configured login, and handing someone their file is granting 
  access. There are no passwords or tokens anywhere else.
- **`bench-agent`** lives on the bench machine and dials out. It claims work, checks out the
  exact pinned sources, runs the orchestrator under a timeout in its own process
  group, heartbeats every 30 seconds (a cancellation arrives as the reply),
  and uploads the artifacts on failure as well as success. If an agent
  dies, its lease expires and the run becomes claimable again.
- **The webview** is static pages over the store's files: a runs index, a
  per-run page, and one dashboard per finished run, provisionally published to
  a GitHub Pages repo so results have a public home.
- **The bot** posts whatever markdown the server renders, verbatim: the
  acknowledgement, refusals, and the completion with its result tables.

## Running your own

Server host (any Linux or macOS box; a laptop works):

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
ocaml-base-compiler 5.4.1; nothing depends on a switch that happens to exist
on the machine, and your active switch is never touched. `make distclean`
removes it.

```sh
make switch          # once; refuses to run while a benchmark is in progress
make build
make test            # table tests: no python, no network, no machine
make live            # generate against running-ng and validate through it
make check           # all three
```

You also need `python3` with PyYAML, a checkout of running-ng, and the
`capnp` schema compiler.

`make test` runs against snapshots, so it fails only when this repo changes;
`make live` pushes generated configs through running-ng's real validators, so
it fails when the benchmark definitions move. If live fails and test passes,
run `make fixtures`.

There is also `bench-gen` (`bin/main.ml`), a developer tool that generates
and checks a run spec without a server; CLAUDE.md documents it.

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
| `lib/bridge.ml`, `scripts/rng_helper.py` | the only path to running-ng's own logic |
| `rpc/` | the Cap'n Proto adapter: schema and service/client glue |
| `bin/bench_serve.ml` | the server daemon; writes the capability files |
| `bin/bench_agent.ml` | the bench machine daemon |
| `bin/bench_cli.ml` | the thin client |
| `bin/main.ml` | `bench-gen`, a developer tool |
| `bot/` | the `/bench` PR bot, Action and polling flavours |
| `webview/`, `scripts/` | the static pages and the operational scripts |
| `test/`, `scripts/live_check.sh` | table tests and the live check |

## Status

The loop is closed and running: comment, queue, agent, running-ng, contract,
result tables back on the PR, dashboard, public pages. Not there yet:

- **result reuse**: answering a repeat request from the store needs run keys,
  which need machine facts the agent does not report yet;
- **cache hygiene on the bench machine**: switch provenance is recorded but
  not yet enforced, and admin-triggered eviction is designed but not wired;
- **per-benchmark live progress**: a small orchestrator plugin, so the run
  page can show benchmarks ticking by instead of one long "measuring" phase;
- **a verdict chip in the runs index**: waiting on repeat-run noise data, so
  it can mean "moved beyond this machine's measured noise" instead of a
  guess. (To be done per benchmarking machine)

## Licence

ISC.
