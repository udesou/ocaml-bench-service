# CLAUDE.md — working notes for agents & contributors on `ocaml-bench-service`

Auto-loaded context for Claude Code (and orientation for humans). `README.md` is
the human-facing overview. The authoritative design is
`~/benchmarking-service-design.md`; this file holds the internals and the
hard-won details.

## What this is

- The **request/scheduling/reporting** layer of the benchmarking service: a
  `/bench` PR comment becomes a validated running-ng run, whose contract
  artifacts become a report and a dashboard page.
- Sibling repos own everything else and are treated as fixed contracts:
  `~/running-ng` (runner), `~/macro-benches` (suites),
  `~/ocaml-bench-dashboard` (data contract + ingestor + dashboard).
- **Stage S0 only** so far: `bench-gen`, the comment → run-spec generator.
  Nothing schedules, ssh's, or measures yet.

## Hard rules (do not violate)

- **Do not comment on PRs, or add to PRs, unless explicitly asked to.**
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
- Keep `README.md`, this file, and `~/benchmarking-service-design.md` consistent
  with every change.

## Where things live

- `lib/request.ml` — the comment grammar. Pure: no network, no knowledge of
  which tags exist, no cost decision. Rejection messages are the product (they
  get posted to PRs verbatim), so they are asserted on in tests.
- `lib/tag_alias.ml` — `small` → `small_run` etc. Unaliased names fall through,
  keeping feature tags (`bigarrays`, `effects`, …) reachable but undocumented.
- `lib/facts.ml` — base-config facts, read from the bridge's JSON. Never parses
  YAML.
- `lib/vocab.ml` — sweepable dimensions from `vocab.json`, minus a policy
  exclusion list (measurement infrastructure `re`/`md`, MMTk-only
  `plan`/`threads`).
- `lib/variant.ml` — one side of the comparison. **`runtime_name` is the
  compiler cache key** (running-ng provisions `running-ng-<runtime name>`), so it
  encodes the sha. Refuses an unresolved ref.
- `lib/cost.ml` — the estimate and the 2 h cap. Calibrated at 30 s per
  cell-iteration; replace with historical per-program timings when we have them.
- `lib/gen.ml` — the generator. Emits config + env + cost + warnings.
- `lib/service_config.ml` / `lib/authz.ml` — bot identity, allowlist, machine
  registry.
- `lib/help.ml` — `/bench help`, generated from facts + vocab.
- `lib/bridge.ml` — the only caller of python.
- `scripts/rng_helper.py` — `facts` | `validate` | `tagfilter`.
- `test/` — table tests against `test/fixtures/` snapshots.
- `scripts/live_check.sh` — the same generation against a pinned running-ng ref
  (`origin/adding-ocaml-support`), validated through running-ng's own checks.

## Gotchas (hard-won — don't rediscover)

- **`comparisons:` in a running-ng config is `label`/`a`/`b` (+ `mode`), NOT the
  contract's `kind`/`over`/`baseline`/`variants`.** `contract/native.py::
  _map_comparisons` translates a/b → contract comparisons on emission. Emitting
  the contract shape produces a config `validate()` rejects. Do not "standardise"
  this: comparisons are visualization metadata only (what *varies* is declared by
  `config_sweep:`), the a/b → contract translation is already lossless, and the
  dashboard consumes only `inter`, treating a missing `kind` as inter. See the
  design doc, "Decided: do NOT standardise the input comparison grammar".
- **`a` is the BASELINE — the merge base, not the PR head.** `b` is
  `[PR head, …extras]`. `bench.js::sweepDeltaRows` reports "the % change of the
  variant relative to the baseline. Negative = variant is better (green)", so
  swapping the sides inverts every delta and makes green mean regression. In this
  repo that is carried by `Variant.role`: the `Baseline` variant becomes `a:`.
- **`validate()` requires every runtime in `configs:` to be referenced by a
  comparison and vice versa.** So a single-runtime run must emit **no**
  `comparisons:` block at all — not a self-comparison.
- **A sweep must define its modifier.** `s`/`o`/`M`/`m` are absent from
  `macro_base.yml`'s `modifiers:`; emitting only `config_sweep:` fails on an
  undefined modifier.
- **`invocations` goes through `overrides:`.** Redefining a base top-level
  scalar at top level is a `combine()` `TypeError`. The base default is
  **3**, not 1, so the value is always emitted explicitly.
- **`tag=` is not a config field.** It becomes `RUNNING_TAG`, consumed by
  `apply_tag_filter()`. The generator's output is therefore a *triple* (config,
  env, args), not a YAML file.
- **The measurement modifier chain is derived, not hardcoded** (`Gen.modifier_chain`).
  running-ng #15 (`fb9751c`, on `adding-ocaml-support`) moved the sequential
  `re`/`md` onto the benchmarks as a suite/program `ocamlrunparam:` field — five
  macro suites declare `e=25,d=2` — so a generated config must **not** carry
  `re-N|md-M`: a config-string value is merged *under* the benchmark's, and
  emitting one reintroduces a global setting for every other suite. We detect
  this with `Facts.uses_ocamlrunparam` and emit `re`/`md` only for older
  branches. The **parallel** triple `re_par-22|md_par-8|pin_lavyek` did *not*
  move — `macro_base.yml` still says a config enabling a lavyek suite MUST add
  it, and without it olly drops events and `wall_time` goes negative — so it is
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
  — check file content, not ancestry.
- **`make switch` builds a compiler and takes opam's root lock.** Never run it
  while a benchmark is running; `make check-idle` is the guard (and uses
  `[p]ython3` so pgrep does not match its own shell).

## Per-session workflow

1. Read `~/benchmarking-service-design.md`, then `README.md`, then this file.
2. `make switch` once, then `make build test`.
3. `make live` before trusting anything against the real configs (it reads
   `origin/adding-ocaml-support`; `git -C ~/running-ng fetch origin` first).
4. Commit only when asked. No `Co-Authored-By: Claude`.
