# ocaml-bench-service

Benchmarking for OCaml compiler pull requests, triggered from a comment. Someone
writes `/bench` on a PR; the service works out what to measure, runs it on a
dedicated machine, and reports back with a summary and a link to a dashboard.

It is the request-and-scheduling layer around three existing pieces: the
[running-ng](https://github.com/udesou/running-ng) benchmark runner, the
[macro-benches](https://github.com/ocaml-bench/macro-benches) suites, and the
[ocaml-bench-dashboard](https://github.com/udesou/ocaml-bench-dashboard) data
contract and viewer. It deliberately reimplements none of them.

> **Status: nothing is measured yet.** What works today is the front half — a
> `/bench` comment becomes a complete, validated description of a run. Executing
> that on a machine is the next piece of work. See [Roadmap](#roadmap).

## What works today

`bench-gen` turns a comment plus a pair of pinned compilers into a **run spec**:
everything a bench machine needs to carry out one measurement, checked before
anything expensive starts.

```sh
# shorten this to `bench-gen` for the examples below
opam exec --switch=. -- dune exec bin/main.exe --

bench-gen help                                    # the /bench reference, generated
bench-gen parse --comment "/bench tag=small"      # a comment as JSON
bench-gen authz --service-config service.json --login someone
bench-gen spec  --comment "/bench" \
                --variant version:base:5.5.0 \
                --variant commit:pr-1234:c0f8c8ceef751fb3a99652d3d52399db3d1c2aae \
                --out /tmp --check
```

`spec` writes two files into `--out`:

| file | what it is |
|---|---|
| `<id>.yml` | a running-ng config |
| `<id>.runspec.json` | the **run spec** — config inline, environment, pinned source refs, command, artifacts to fetch, limits |

The run spec is documented in [docs/RUNSPEC.md](docs/RUNSPEC.md); read that before
writing anything that consumes it. `--format json` prints it instead of the
config, and `--check` additionally pushes the generated config through
running-ng's own `validate()` and `validate_tags()`.

A config file alone would not be enough, which is the main reason a "run spec"
exists at all: the benchmark selection travels as the `RUNNING_TAG` *environment
variable*, because that is where running-ng's `apply_tag_filter()` reads it from.

## What a request has to get right

Most of the work here is not parsing. It is encoding the rules that otherwise
fail **silently**, so that a bad request is rejected in a second rather than
producing plausible, wrong numbers an hour later:

- **Compilers are pinned to commits.** A ref like `trunk` is refused outright —
  two runs labelled "trunk" must be the same commit or they are not comparable.
- **Runtime names carry the sha**, because running-ng provisions the switch
  `running-ng-<runtime name>` and treats it as the compiler cache. Naming decides
  whether a second request rebuilds a compiler for 10–20 minutes or reuses one.
- **The baseline is the merge base**, never the PR head. Every delta is reported
  relative to the baseline, so swapping the two inverts the sign of the whole
  report and makes an improvement look like a regression.
- **The benchmark-source commit is part of run identity.** Binaries are cached as
  `<benchmark>-<runtime>` and the runtime name encodes only the compiler sha, so
  changing benchmark source does *not* invalidate a cached binary.
- **Measurement modifiers are derived from the base config, not assumed**, since
  running-ng moves where the runtime_events settings live as it evolves.
- **Cost is estimated and capped.** One comment can ask for twenty hours on a
  machine that must run serially; a request over the limit is refused with the
  estimate and how to shrink it.

Rejection messages are treated as part of the product — they get posted to a pull
request verbatim — so the test suite asserts on their exact wording.

## The `/bench` grammar

```
/bench                      # default set, 3 iterations (~1h)
/bench vs=trunk             # choose the baseline
/bench vs=5.4.1,trunk       # compare more than two compilers
/bench tag=small            # small | default | large | huge | legacy | all
/bench iterations=5         # up to 10
/bench sweep=s:262144,524288;o:80,120
/bench machine=<name>       # when more than one is registered
/bench force=true           # run despite the cost limit
/bench cancel
/bench rerun                # clean slate: rebuild everything
/bench help
```

The baseline defaults to the PR's merge base, so a bare `/bench` answers the
question people actually have: *does this change performance?*

`/bench help` is generated at request time from the benchmark suite definitions
and the data contract's vocabulary, so it cannot drift from what is accepted.
Sweep parameters take either the `OCAMLRUNPARAM` letter (`o`) or the contract's
canonical name (`space_overhead`).

Not in the prototype, on purpose: choosing measurement tools (perf is always
attached, which is also what collects the GC metrics) and naming individual
benchmarks. Both are easy to add later; they would be hard to take away.

## Who can trigger a run

An explicit allowlist of GitHub logins, not GitHub's `author_association`. A run
costs about an hour of exclusive machine time and executes compiler code from a
pull request, so triggering one is a privilege rather than something to infer
from repository permissions.

## Build and test

Self-contained: `make switch` creates a switch in `./_opam` pinned to
ocaml-base-compiler 5.4.1 and installs dependencies from the committed
`ocaml-bench-service.opam`. Nothing depends on a switch that happens to exist on
the machine, and your active switch is never touched. `make distclean` removes it.

```sh
make switch          # once; refuses to run while a benchmark is in progress
make build
make test            # table tests: no python, no network, no machine
make live            # generate against running-ng and validate through it
make check           # all three
```

You also need `python3` (with PyYAML) and a checkout of running-ng, which
`make live` reads. Config merge rules, tag filtering and validation are answered
by running-ng itself through `scripts/rng_helper.py` — the single bridge to it —
rather than reimplemented here, because two implementations of the same implicit
schema is exactly how this kind of pipeline drifts.

`make test` runs against snapshots in `test/fixtures/`, so it fails only when
this repo changes. `make live` generates against a pinned running-ng ref and
pushes each config through running-ng's real validators, so it fails when the
benchmark definitions move. If live fails and test passes, run `make fixtures` —
see [test/fixtures/PROVENANCE](test/fixtures/PROVENANCE).

Both read running-ng from a **pinned ref** rather than whatever branch a checkout
happens to be on. Override with `RUNNING_NG_REF=` or `BASE_CONFIG=` to develop
against an unmerged change.

## Configuration

Copy `service.example.json` to `service.json` (gitignored) and edit it. It holds
the bot account and the *name of the environment variable* carrying its token —
never the token itself — the trigger allowlist, and the machine registry. All
three are configuration so that swapping the bot account, adding someone to the
allowlist, or registering a machine is an edit rather than a deploy.

A machine entry is really a *slot*: `(host, OPAMROOT, benches directory)`. One
slot means one concurrent run, because running-ng locks the opam root — which
also happens to be the property that keeps measurements from overlapping.

## Repository layout

| path | contents |
|---|---|
| `lib/request.ml` | the comment grammar |
| `lib/gen.ml` | request + suite definitions → a running-ng config |
| `lib/runspec.ml` | the run spec, specified in `docs/RUNSPEC.md` |
| `lib/cost.ml` | the estimate and the budget limit |
| `lib/authz.ml`, `lib/service_config.ml` | allowlist, bot identity, machine registry |
| `lib/bridge.ml`, `scripts/rng_helper.py` | the only path to running-ng's own logic |
| `bin/main.ml` | the `bench-gen` command line |
| `test/`, `scripts/live_check.sh` | table tests and the live check |

## Roadmap

1. ~~Turn a `/bench` comment into a validated run spec.~~ **Done.**
2. **Run it.** A machine registry and an ssh runner: check out the pinned
   sources, provision or reuse compiler switches, run under a timeout in its own
   process group, and fetch artifacts back — on failure as well as success.
3. **Queue it.** A durable queue with one run at a time per machine, leases so a
   restart cannot lose an hour of work, and honest queue positions and ETAs.
4. **Trigger it.** A GitHub workflow on `issue_comment`, an immediate
   acknowledgement, and a summary comment when the run finishes.
5. **Show it.** Results published as data-contract artifacts and rendered by the
   dashboard, with a regression judgement that accounts for machine noise.

## Licence

ISC.
