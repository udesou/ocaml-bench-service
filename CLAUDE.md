# CLAUDE.md -- working notes for agents & contributors on `ocaml-bench-service`

Auto-loaded context for Claude Code (and orientation for humans). `README.md` is
the human-facing overview; this file holds the internals and the hard-won
details. Everything needed to work on this repo is in the repo -- no external
document is required reading.

## What this is

- The **request/scheduling/reporting** layer of the benchmarking service: a
  `/bench` PR comment becomes a validated running-ng run, whose contract
  artifacts become a report and a dashboard page.
- Sibling repos own everything else and are treated as fixed contracts:
  **running-ng** (runner), **macro-benches** (suites), **ocaml-bench-dashboard**
  (data contract + ingestor + dashboard). Paths to their checkouts are
  configuration (`RUNNING_NG_REPO`, `VOCAB`, the machine registry), never
  assumptions.
- The loop is closed: comment → run spec → queue → claimed by `bench-agent`
  over capnp → running-ng measures → contract → report tables on the PR →
  per-run dashboard → public pages. Nothing ever ssh's (the agent dials
  out). `README.md` has the status list of what is still missing.

## Hard rules (do not violate)

- **Do not comment on PRs, or add to PRs, unless explicitly asked to.**
- **No em-dashes anywhere but this file.** Every other file (READMEs, docs,
  reports, generated markdown, code comments) uses commas, colons, parens,
  or "--" instead.
- **No "Claude"/Anthropic/`Co-Authored-By: Claude` in commit messages.**
- **Commit only when asked.**
- **Never reimplement running-ng or contract semantics.** Config merge, tag
  filtering, and validation go through `scripts/rng_helper.py`; sweep dimension
  names come from the contract's generated `vocab.json`. A second
  implementation of an implicit schema is the exact drift
  `DATA_CONTRACT.md` was written to kill.
- **Build only in the repo-local `./_opam` switch** (`make switch`, pinned to
  ocaml-base-compiler 5.4.1). The service must not depend on a switch that
  happens to exist on a machine, and must never change the active one. A local
  switch rather than a named one because this machine's opam root is shared with
  running-ng, where switches *are* the compiler cache.
- **`service.json` is gitignored** and stays that way: it carries the real
  allowlist and bot account.
- Keep `README.md`, this file, and `docs/RUNSPEC.md` consistent with every
  change. Each pushed increment must stand on its own: no pointing at documents
  that live outside the repository.

## Where things live

- `lib/api.ml` -- **the Request API (API A)**: the types and module signature
  every requester (PR bot, CLI, future web form) speaks. Types the architecture
  document defines are transcribed verbatim; types it references without
  defining are marked PROVISIONAL in place. A change starts in the document,
  not here.
- `lib/server.ml` -- the request server: `Api.REQUEST_API` over the existing
  pipeline, with a **file-backed queue** (`<state>/runs/<run_id>/` holding
  meta.json + request.json + runspec.json + config.yml; that directory IS the
  queue row the agent claims), plus the EXECUTION side (`Api.EXECUTION_API`,
  §6.2): claim/heartbeat/post_events/upload/finish/report_caches, keyed by the
  transport-proven machine name, with `execution.json` per run as the lease
  record. Transports wrap this module; do not fork a second submit path.
- `bin/bench_agent.ml` -- the bench machine daemon (API B). Dials the server
  with `agent-<machine>.cap`, claims, heartbeats every 30s while a child runs
  (the reply is the cancel channel; SIGTERM group -> grace -> SIGKILL), posts
  events, uploads the §8 bundle, finishes. The REAL executor is the default
  (`--stub` keeps the protocol-only one): private clones under ~/.bench-agent
  checked out to the spec's shas, the config materialized after an md5 check
  with `${RUNNING_NG_ROOT}` substituted, then the pinned tree's own
  run_ocaml_bench_gc_sweep.sh under setsid. Exit 0 is NOT success: an empty
  contract (no configs in manifest.json) finishes as failed -- running-ng
  skips failed benchmark builds and exits cleanly. Exits on a broken
  connection; a supervisor loop restarts it. `scripts/agent-setup.sh` is the
  bench-machine bootstrap (prereq checks, donor-seeded clones, build).
- **macro-benches cannot build from a bare clone**: its vendored trees
  (duniverse/, vendor/, _rocq_prefix/) are gitignored PRODUCTS of its own
  `make setup`. The agent runs that setup supervised on first claim and
  whenever the benches pin moves (marker: `<state>/benches-setup.json` with
  commit + lock-file md5), dropping the vendored trees first when the LOCK
  changed -- setup-monorepo.sh deliberately skips re-pulling a populated
  duniverse/. agent-setup.sh seeds the trees from a donor checkout to skip
  the first big pull.
- `lib/resolver.ml` -- user input → pinned runtimes. `Resolver.github` is the
  server's whole GitHub dependency and it is only `git`: ls-remote for tags,
  branches and `refs/pull/N/head`, plus a bare cache repo for the merge base.
  No API, no token. `Resolver.offline` (versions + shas only) keeps tests and
  the live check hermetic.
- `rpc/` -- the Cap'n Proto adapter (Q15): `bench_api.capnp` (one method per
  REQUEST_API function) and `rpc.ml` (service + typed client). v1 wire
  encoding: record payloads travel as the lib/api.ml JSON, errors as the
  envelope JSON in the exception reason; promoting payloads to capnp structs
  is additive later. Building it needs the `capnp` system binary
  (~/.local/bin on this machine; the Makefile exports the PATH).
- `bin/bench_serve.ml` -- the daemon. Writes `<caps>/<login>.cap` per
  configured login + `bot.cap` at startup: the capability file IS the access
  (and the identity -- there is no --login anywhere).
- `bot/` -- the fork's GitHub Action: bot.cap + a prebuilt bench-cli, posts
  back whatever markdown the server returns. `bot/poll.sh` (the LAN twin)
  additionally posts COMPLETION notices: the server renders
  `<run>/completion.md` at every terminal state (finish, dead-agent
  close-out) and the bot posts it once per run to its PR
  (`completion.posted` is the marker; requeue clears both for a fresh
  cycle). The bot still renders nothing itself.
- `scripts/publish_pages.sh` -- syncs the webview root (index, run pages,
  bundles, dashboards) into a GitHub Pages repo and pushes: the shareable
  face and the git-backed store PoC (Q2). Gated on BENCH_PAGES_REPO; fifth
  start_server window. Pages needs `.nojekyll` (Jekyll drops _observablehq/)
  and lags a CDN cache by minutes -- the LAN webview stays the live view.
- `lib/request.ml` -- the comment grammar. Pure: no network, no knowledge of
  which tags exist, no cost decision, no roles (admin-only keys parse for
  everyone and are refused in Authz). Rejection messages are the product (they
  get posted to PRs verbatim), so they are asserted on in tests.
- `lib/tag_alias.ml` -- `small` → `small_run` etc. Unaliased names fall through,
  keeping feature tags (`bigarrays`, `effects`, …) reachable but undocumented.
- `lib/facts.ml` -- base-config facts, read from the bridge's JSON. Never parses
  YAML.
- `lib/vocab.ml` -- sweepable dimensions from `vocab.json`, minus a policy
  exclusion list (measurement infrastructure `re`/`md`, MMTk-only
  `plan`/`threads`).
- `lib/variant.ml` -- one side of the comparison. **`runtime_name` is the
  compiler cache key** (running-ng provisions `running-ng-<runtime name>`), so it
  encodes the sha. Refuses an unresolved ref.
- `lib/cost.ml` -- the estimate and the 2 h cap. Calibrated at 30 s per
  cell-iteration; replace with historical per-program timings when we have them.
- `lib/gen.ml` -- the generator. Emits config + env + cost + warnings.
- `lib/service_config.ml` / `lib/authz.ml` -- bot identity, allowlist + admins
  (roles), machine registry (no ssh: the agent dials out, the server never
  connects to a machine). `Authz.vet_request` is where `force=`/`priority=`
  are refused for non-admins.
- `lib/report.ml` -- contract artifacts -> report.md, rendered by the SERVER
  at finish and embedded verbatim in completion.md (no separate summary
  vocabulary: the tables ARE the summary). Policy: wall / instructions /
  max RSS reported INDIVIDUALLY, never composed into one verdict (no metric
  is authoritative -- fp changes regress instructions while wall shrugs);
  per-benchmark medians, the dashboard's 1%/3% bands, wall verdicts gated on
  >= wall_min_invocations, RSS verdicts on >= rss_floor_kib moved.
  Thresholds come from service.json `report` (provisional until Q12).
- `lib/help.ml` -- `/bench help`, generated from facts + vocab.
- `lib/run_key.ml` -- the content identity of a measurement, for result reuse.
  Computed by the server at submission; bench-gen emits `run_key: null` because
  it resolves no refs and knows no machine fingerprint.
- `lib/runspec.ml` -- the generator → agent interface, specified in
  `docs/RUNSPEC.md`. **Change both together.** Version 1 (nothing ever
  shipped): describes only WHAT to measure -- config inline, sources and
  runtimes pinned to SHAS by the server before dispatch
  (`Resolver.local_source`), and **nothing machine-side**: no paths, no env,
  no command line, no transport, no credentials. The agent derives all of
  that from its own config plus the spec (e.g. `RUNNING_TAG` from
  `selection.tags`); execution-scoped directives (rerun's cache bypass, the
  timeout) travel in the §6.2 assignment at claim time.
- `lib/bridge.ml` -- the only caller of python.
- `webview/` -- the public pages: `index.html` (runs table over runs.json) and
  `run.html#<id>` (per-run page over the bundle, symlinked into the webview
  root by scripts/webview.sh). `scripts/dashboard_builder.sh` builds a static
  ocaml-bench-dashboard per finished run (BENCH_RUN_DIR=<bundle> npm run
  build) into webview/dashboards/<id>/; a failed build leaves <id>.failed and
  is not retried until it is removed. It builds from the WORKING dashboard
  checkout and records the dashboard pin in .built.json -- rebuild-on-bump is
  future work.
- `scripts/rng_helper.py` -- `facts` | `validate` | `tagfilter`.
- `bin/main.ml` -- `bench-gen`, the developer tool (generation without a
  server; the README deliberately only mentions it). The commands:
  `bench-gen help | vocab | parse --comment "..." | authz --service-config
  service.json --login X | spec --comment "..." --variant version:base:5.5.0
  --variant commit:pr-1234:<sha> --out /tmp --check`. `spec` writes
  `<id>.yml` (the running-ng config) and `<id>.runspec.json`; `--format
  json` prints the spec; `--check` pushes the config through running-ng's
  own validate() and validate_tags(). Its --macro-bench-dir/--log-dir/
  --opamroot flags are dev-local conveniences, not service paths.
- `test/` -- table tests against `test/fixtures/` snapshots.
- `scripts/live_check.sh` -- the same generation against a pinned running-ng ref
  (`origin/adding-ocaml-support`), validated through running-ng's own checks.

## Gotchas (hard-won -- don't rediscover)

- **Build flavors are config, not code.** A vs= entry is `<compiler>[+flavor...]`;
  the table (name -> configure args) is service.json `flavors`, defaulting to
  fp/flambda (Variant.default_flavors). List order is canonical: `+flambda+fp`
  and `+fp+flambda` produce one runtime name (`ocaml-X-fp-flambda`, matching
  the pre-existing switch convention). Validation keeps names and args unique
  so runtime names stay injective; `Variant.flavor` (the name suffix) and
  `configure_args` travel together -- whoever sets one owns the other.
  Consequence: `+` always parses as a flavor separator, so a git branch with
  a literal `+` in its name cannot be requested via vs=.
- **The user-facing repetition key is `invocations=`, never `iterations`.**
  It maps 1:1 onto running-ng's `invocations:` (fresh-process repetitions).
  The old spelling is a special-cased rejection that points at the new key --
  not a "did you mean" (three edits away, the suggester will not fire).
- **Admin-only keys parse for everyone and are refused in Authz.** The grammar
  stays pure and role-free; `Authz.vet_request` refuses `force=true` and
  `priority=` for non-admins with a Forbidden envelope. Do not push role checks
  into `Request.parse`.
- **The server never trusts the caller's `auth.role`.** The transport proves
  the LOGIN; the ROLE is re-derived from service.json's `admins` on every call
  (`Server.effective_auth`). A client self-declaring Admin gets what the
  config says.
- **The agent capability is a MACHINE, and only that.** `agent-<name>.cap`
  can claim/report its own machine's work and nothing else -- never submit,
  never admin. Every per-execution call is guarded by (machine, execution)
  against `execution.json`; a superseded agent gets `Cancel` from heartbeat
  and `Forbidden` from writes. run_id/execution inside event payloads are
  ignored -- the authenticated ones are used (the bench machine is treated as
  compromisable).
- **Uploads cannot touch server records.** Artifact paths must be clean and
  relative (`Server.safe_rel_path`), and the `server_owned` list (meta.json,
  request.json, runspec.json, config.yml, execution.json, events.ndjson) is
  refused. The run directory doubles as the v1 store bundle (§8 layout);
  finish's `Ok` IS the store confirmation.
- **Cancelling a RUNNING run only signals it.** The server cannot reach the
  machine (Q1), so cancel sets `cancel_requested` and the order travels as
  the reply to the agent's next heartbeat; state stays Running until the
  agent finishes with `Exec_aborted`. A dead cancel-requested run is closed
  by the next claim sweep.
- **Leases, not locks.** One slot per machine: a live lease blocks further
  claims; no heartbeat for 15 min (`Server.lease_seconds`) makes the run
  claimable again as execution N+1. Events count as heartbeats.
- **`/bench continue <id>` is a new EXECUTION, not a new run.** Owner or
  admin; terminal runs only. It reissues the same run (same spec, same pins,
  same bundle) with `resume.requested` in the run dir; claim consumes the
  marker into the assignment's `resume` flag; the agent re-enters the
  previous run directory (`running-ng --resume`, tracked in
  `<agent-state>/resume/<run_id>`) and clears the `.build-failed` sentinels
  so failed builds retry. No surviving directory = runs afresh, honestly
  logged. Continue keeps the ORIGINAL pins: a fix that changes benchmark
  source is a new benches pin and a new run. The dashboard builder rebuilds
  a published dashboard when the bundle's manifest is newer than it.
- **Idempotency is checked against ACTIVE runs only.** `(origin id, normalized
  command)` deduplicates redeliveries while a run is queued/running; a repeat
  of a *completed* run is the run key's job (§8.1), which nothing computes yet.
  Widening the duplicate check to finished runs would make rerunning a command
  impossible.
- **Pins are the server's control file** (`<state>/pins.json`): seeded once
  from the configured checkouts, changed ONLY by the admin `bump` op (which
  validates the candidate first -- for running-ng it extracts and loads facts
  -- then writes pins and self-restarts to adopt). A restart never silently
  re-pins. Every run spec snapshots the pins at submission, so bumps affect
  future runs only. `versions` (admin) shows service build + pins.
- **Non-run commands are `Answered` outcomes (Q18).** `/bench help` and
  `/bench cancel <id>` through `submit` make the server act and reply with
  postable markdown; requesters never pre-parse (the grammar lives in the
  server, Q13). Do not route them to the error envelope.
- **The wire never carries a login for users.** The capability file is the
  identity; only `bot.cap` may assert one (the commenter GitHub verified).
  CLI idempotency ids are rewritten server-side to `cli:<login>` in rpc.ml --
  a client cannot dodge or forge the duplicate check.
- **`comparisons:` in a running-ng config is `label`/`a`/`b` (+ `mode`), NOT the
  contract's `kind`/`over`/`baseline`/`variants`.** `contract/native.py::
  _map_comparisons` translates a/b → contract comparisons on emission. Emitting
  the contract shape produces a config `validate()` rejects. Do not "standardise"
  this: comparisons are visualization metadata only (what *varies* is declared by
  `config_sweep:`), the a/b → contract translation is already lossless, and the
  dashboard consumes only `inter`, treating a missing `kind` as inter -- it
  derives curves and heatmaps from which dimensions actually vary, and
  synthesises `inter` comparisons itself, so `intra`/`both` are unused rather
  than half-built. This was investigated and closed; do not reopen it without
  new evidence from the dashboard side.
- **`a` is the BASELINE -- the merge base, not the PR head.** `b` is
  `[PR head, …extras]`. `bench.js::sweepDeltaRows` reports "the % change of the
  variant relative to the baseline. Negative = variant is better (green)", so
  swapping the sides inverts every delta and makes green mean regression. In this
  repo that is carried by `Variant.role`: the `Baseline` variant becomes `a:`.
- **`validate()` requires every runtime in `configs:` to be referenced by a
  comparison and vice versa.** So a single-runtime run must emit **no**
  `comparisons:` block at all -- not a self-comparison.
- **A sweep must define its modifier.** `s`/`o`/`M`/`m` are absent from
  `macro_base.yml`'s `modifiers:`; emitting only `config_sweep:` fails on an
  undefined modifier.
- **`invocations` goes through `overrides:`.** Redefining a base top-level
  scalar at top level is a `combine()` `TypeError`. The base default is
  **3**, not 1, so the value is always emitted explicitly.
- **`tag=` is not a config field.** It becomes `RUNNING_TAG`, consumed by
  `apply_tag_filter()`. This is why the deliverable is a run spec and not a YAML
  file -- a config alone does not describe the run. Several tags are allowed
  (`tag=small,large`) and mean their **union**: that is apply_tag_filter's own
  comma-separated semantics, don't reimplement or second-guess it.
- **`/bench cancel` requires an explicit run id** (from the run's
  acknowledgement comment). "Cancel my latest" is ambiguous once two requests
  share a PR, and a wrong guess kills an hour of someone else's work.
- **The macro-benches commit is part of run identity.** Binaries are cached as
  `<benchmark>-<runtime>` and the runtime name encodes only the *compiler* sha, so
  changing benchmark source does not invalidate a cached binary. `sources` in the
  run spec carries both repos pinned to shas -- resolved by the SERVER before
  dispatch, never left as refs for the agent.
- **The measurement modifier chain is derived, not hardcoded** (`Gen.modifier_chain`).
  running-ng #15 (`fb9751c`, on `adding-ocaml-support`) moved the sequential
  `re`/`md` onto the benchmarks as a suite/program `ocamlrunparam:` field -- five
  macro suites declare `e=25,d=2` -- so a generated config must **not** carry
  `re-N|md-M`: a config-string value is merged *under* the benchmark's, and
  emitting one reintroduces a global setting for every other suite. We detect
  this with `Facts.uses_ocamlrunparam` and emit `re`/`md` only for older
  branches. The **parallel** triple `re_par-22|md_par-8|pin_lavyek` did *not*
  move -- `macro_base.yml` still says a config enabling a lavyek suite MUST add
  it, and without it olly drops events and `wall_time` goes negative -- so it is
  emitted only when a lavyek suite has enabled programs (`Facts.par_chain_suites`).
  Today lavyek is empty, so a macro config is a bare `<runtime>|perf_grp1`.
- **Modifier existence checks compare the NAME, not the token.** A config-string
  token is `re-25`; the base config declares `re`. `Gen.modifier_name` strips a
  trailing `-<digits>`.
- **Never validate with `-d`.** Dry run still provisions compilers:
  `_ensure_switch` runs from `OCaml.__init__`, which `resolve_class()` calls
  before any dry-run check. The bridge calls `validate()`/`validate_tags()`
  directly and never `resolve_class()`, which is why it is safe to run while a
  benchmark is in progress.
- **Check the tag before calling the bridge's `tagfilter`.** running-ng's own
  error lists raw tag names and cannot suggest an alias; ours is the better
  message for a user.
- **`machine=` in the comment must beat the `--machine` flag.** The flag is an
  operator default; the comment is the request. Getting this backwards silently
  runs on the wrong host and makes numbers unattributable.
- **Short words break "did you mean".** `wat` is within two edits of `tag`, so
  `Util.did_you_mean` gives words of ≤ 4 characters a budget of 1.
- **Fixtures are snapshots on purpose.** A test that fails because someone edited
  `macro_base.yml` is a test people learn to ignore. `live_check.sh` is the
  half that is *supposed* to break when the base config moves.
- **Read running-ng from a pinned REF, never the working copy.** That checkout
  moves between a dozen feature branches; one predating the input-size ladder
  has no `small_run` at all, so a working-copy read makes both `make fixtures`
  and `make live` fail for reasons unrelated to this repo. Both default to
  `RUNNING_NG_REF=origin/adding-ocaml-support`. Note #15 was **squash**-merged,
  so `git merge-base --is-ancestor` on the original commit reports "not merged"
  -- check file content, not ancestry.
- **`make switch` builds a compiler and takes opam's root lock.** Never run it
  while a benchmark is running; `make check-idle` is the guard (and uses
  `[p]ython3` so pgrep does not match its own shell).

## Per-session workflow

1. Read `README.md`, then this file, then `docs/RUNSPEC.md`.
2. `make switch` once, then `make build test`.
3. `make live` before trusting anything against the real configs (it reads
   `origin/adding-ocaml-support` from the running-ng checkout; fetch first).
4. Commit only when asked. No `Co-Authored-By: Claude`.
