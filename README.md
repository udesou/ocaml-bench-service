# ocaml-bench-service

Benchmarking for OCaml compiler pull requests, triggered from a comment. Someone
writes `/bench` on a PR; the service works out what to measure, runs it on a
dedicated machine, and reports back with a summary and a link to a dashboard.

It is the request-and-scheduling layer around three existing pieces: the
[running-ng](https://github.com/udesou/running-ng) benchmark runner, the
[macro-benches](https://github.com/ocaml-bench/macro-benches) suites, and the
[ocaml-bench-dashboard](https://github.com/udesou/ocaml-bench-dashboard) data
contract and viewer. It deliberately reimplements none of them.

> **Status: nothing is measured yet.** What works today is the front half,
> end to end and over the wire: `bench-cli submit "/bench …"` reaches the
> `bench-serve` daemon over Cap'n Proto — allowlist and roles, grammar,
> validation, GitHub resolution (PR head, merge base, release tags), cost
> cap — and lands as a run-spec directory in a file-backed queue, with
> `status`/`list`/`cancel` working against it, plus a GitHub Action
> ([bot/](bot/)) that does the same from a `/bench` PR comment. Nothing
> drains that queue yet: the bench agent (API B) is the next piece of work.
> See [Roadmap](#roadmap).

## What works today

`bench-gen` turns a comment plus a pair of pinned compilers into a **run spec**:
everything a bench machine needs to carry out one measurement, checked before
anything expensive starts.

```sh
# shorten this to `bench-gen` for the examples below
opam exec --switch=. -- dune exec bin/main.exe --

bench-gen help                                    # the /bench reference, generated
bench-gen vocab                                   # machines/families/tags/sweeps as JSON
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

## The server and its clients

The transport is **Cap'n Proto** (Q15): the Request API stays an OCaml module
signature (`lib/api.ml`), `rpc/bench_api.capnp` is its wire schema, and a
token is a **capability file** — `bench-serve` writes `<login>.cap` for every
configured login (plus `bot.cap`) at startup, and handing someone their file
is how access is granted. There is no `--login` anywhere: the capability *is*
the identity, and the role (user/admin) is still derived server-side from
`service.json` on every call.

```sh
bench-serve --service-config service.json \
  --listen tcp:0.0.0.0:7000 --public-address tcp:bench.example.org:7000

bench-cli submit "/bench tag=small invocations=1 vs=5.4.1,trunk" --cap me.cap
bench-cli status run-20260825-001 --cap me.cap
bench-cli list
bench-cli cancel run-20260825-001
bench-cli help                # the /bench reference, served by the server
```

`bench-cli` is the thin client (Q13): it parses nothing of the grammar and
renders nothing — it sends the raw command and prints whatever markdown comes
back. `/bench help` and `/bench cancel <id>` come back as **Answered**
outcomes: the server acts and replies, so a bot can post the result verbatim
without understanding it. The PR bot ([bot/](bot/)) is the same client run
from a GitHub Action with `bot.cap`, asserting the commenter it verified.

The server resolves everything to shas at submission (`lib/resolver.ml`,
plain `git`, no API tokens): release tags and branches for `vs=`, the PR head
via `refs/pull/N/head`, and the merge-base baseline in a local git cache.
`--resolver offline` restricts to versions and commit shas for hermetic use.

Every accepted run becomes a directory under `<state-dir>/runs/<run_id>/` —
`meta.json` (the index record), `request.json` (who asked, when, verbatim),
`runspec.json` and the generated config. That directory *is* the queue row;
the future bench agent claims work by draining it. Submissions are
deduplicated by `(login, normalized command)` while a run is active, users
are capped to a few active runs, and machines can be drained by admins.

Still deliberately missing: run keys (so no result reuse yet) and anything
that executes — the queue's far side is API B, the agent.

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
  estimate and how to shrink it. Only an admin can force past the cap.

Rejection messages are treated as part of the product — they get posted to a pull
request verbatim — so the test suite asserts on their exact wording.

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
/bench family=macro         # the default; micro is reserved
/bench force=true           # run despite the cost limit (admin-only)
/bench priority=top         # jump the queue (admin-only)
/bench cancel <run-id>      # the id is in the run's acknowledgement
/bench rerun                # clean slate: rebuild everything
/bench help
```

The baseline defaults to the PR's merge base, so a bare `/bench` answers the
question people actually have: *does this change performance?*

The repetition key is `invocations=` — each one runs every benchmark in a fresh
process, which is what running-ng's `invocations:` means; "iterations" is not a
word this service uses, and the old spelling gets a pointer to the new one.

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

There are two roles. **Users** (the allowlist) submit, watch, and cancel their
own runs. **Admins** (the `admins` list) additionally operate the service; only
they may spend other people's time with `force=true` (past the cost cap) or
`priority=top` (front of the queue). Identity is a GitHub login everywhere —
the bot asserts the commenter it verified; the CLI will map bearer tokens to
logins — so the allowlist and the audit trail stay uniform.

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

You also need `python3` (with PyYAML), a checkout of running-ng, which
`make live` reads, and the `capnp` schema compiler (the `capnproto` system
package; on machines without sudo, build it from source into `~/.local` — the
Makefile puts `~/.local/bin` on PATH). Config merge rules, tag filtering and validation are answered
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
never the token itself — the trigger allowlist, the admins, and the machine
registry. All of it is configuration so that swapping the bot account, adding
someone to the allowlist, or registering a machine is an edit rather than a
deploy.

A machine entry is really a *slot*: `(host, OPAMROOT, benches directory)`. One
slot means one concurrent run, because running-ng locks the opam root — which
also happens to be the property that keeps measurements from overlapping. The
registry carries no ssh coordinates: the server never connects to a bench
machine — the agent on the machine dials out — so a machine is a name and
paths, not a transport.

## Repository layout

| path | contents |
|---|---|
| `lib/api.ml` | the Request API: the §5 types and module signature every requester speaks |
| `lib/server.ml` | the request server: API A over a file-backed queue |
| `lib/resolver.ml` | user input → pinned runtimes: releases, branches, PR heads, merge bases (plain git) |
| `rpc/` | the Cap'n Proto adapter: the schema and the service/client glue |
| `bin/bench_serve.ml` | the server daemon; writes the capability files |
| `bot/` | the GitHub Action for `/bench` PR comments, and its setup notes |
| `lib/request.ml` | the comment grammar |
| `lib/gen.ml` | request + suite definitions → a running-ng config |
| `lib/runspec.ml` | the run spec, specified in `docs/RUNSPEC.md` |
| `lib/run_key.ml` | the content identity of a measurement (result reuse) |
| `lib/cost.ml` | the estimate and the budget limit |
| `lib/authz.ml`, `lib/service_config.ml` | allowlist, roles, bot identity, machine registry |
| `lib/bridge.ml`, `scripts/rng_helper.py` | the only path to running-ng's own logic |
| `bin/bench_cli.ml` | `bench-cli`, the thin API A client |
| `bin/main.ml` | the `bench-gen` command line (a developer tool) |
| `test/`, `scripts/live_check.sh` | table tests and the live check |

## Roadmap

1. ~~Turn a `/bench` comment into a validated run spec.~~ **Done.**
2. ~~Fix the Request API: types, roles, vocabulary (`lib/api.ml`).~~ **Done.**
3. ~~Queue it: a server implementing `Api.REQUEST_API` behind a file-backed
   queue.~~ **Done.**
4. ~~Wire it: Cap'n Proto transport with capability-file auth, `bench-cli`,
   GitHub resolution (PR head, merge base, tags, branches), and the
   `/bench`-comment Action for the fork.~~ **Done** — still to come here:
   result reuse by run key (`lib/run_key.ml`), and the run-completion comment
   (needs step 5).
5. **Run it.** An agent on the bench machine that *dials out* to claim work
   from the queue (the server never connects to a machine): check out the
   pinned sources, provision or reuse compiler switches, run under a timeout
   in its own process group, and upload artifacts — on failure as well as
   success. Leases so a restart cannot lose an hour of work.
6. **Show it.** Results published as data-contract artifacts and rendered by the
   dashboard, with a regression judgement that accounts for machine noise, and
   the summary comment posted back to the PR.

## Licence

ISC.
