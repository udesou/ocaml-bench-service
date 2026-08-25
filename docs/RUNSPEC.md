# The run spec

The normative description of what the server hands to a bench machine for one
benchmark run. `lib/runspec.ml` is the implementation; this file is the spec.
Change both together.

A run spec is a single JSON object. It is produced by the request server
(`bench-gen spec`), consumed by the agent that executes it on a bench machine,
and archived beside the results as the run's provenance record.

```sh
bench-gen spec --comment "/bench tag=small" \
  --variant version:base:5.5.0 \
  --variant commit:pr-1234:c0f8c8ce… \
  --format json --out /runs
# -> /runs/<request_id>.runspec.json  (+ <request_id>.yml)
```

## Why it exists at all

Before this, the generator produced a YAML file and printed shell `export` lines.
That is enough for a human reading a terminal and useless as an interface: it is
not machine-readable, it cannot be archived or replayed, and it omitted three
things the machine actually needs — which commits of running-ng and macro-benches
to use, what command to run, and when to give up.

## Design rules

**Self-contained.** The generated config travels **inline** (`config.contents`),
not as a path. A spec can be archived, diffed, or replayed on its own, and server
and agent need no shared filesystem.

**Explicit about sources.** running-ng and macro-benches are pinned by ref, and
the agent records the commit it checked out. This is not bookkeeping: benchmark
binaries are cached as `<benchmark>-<runtime>` and the runtime name encodes only
the *compiler* sha, so a change to benchmark source does **not** invalidate a
cached binary. Without the macro-benches commit in the run's identity, a run can
silently measure old benchmark code against a new compiler.

**No credentials, ever.** The bench machine executes arbitrary compiler code from
a pull request and is treated as compromisable. A spec carries paths and refs,
never tokens. The agent *uploads* results; the server publishes them.

**No transport, ever.** The server never connects to a bench machine (the agent
dials out — Q1 in the architecture document), so nothing in a spec names ssh
targets or any other way to reach a host. A machine is a registry name.

**Versioned.** `spec_version` is bumped on any incompatible change. A consumer
must refuse a major version it does not know rather than guess.

## Version 2

Version 2 aligned the spec with the decided parts of the architecture document
(its §14.1): `runspec_version` became **`spec_version`** and is now `"2"`;
`placement.ssh` was **removed** (Q1: agent pull, no server-to-machine
connections); `measurement.iterations` became **`invocations`** (Q17); top-level
**`family`**, **`run_key`** and **`run_id`** were added; the flat `runtimes`
list with `role` markers became **`baseline`** (exactly one, by construction)
plus **`candidates`**, matching the request API's `resolved` payload; runtime
pins gained **`configure_args`**; `selection` carries a **list of tags**
(their union, running-ng's own multi-tag semantics).

## Fields

### `spec_version` — string
Currently `"2"`.

### `run_id` — string
The run's identity everywhere: the queue row, the store bundle, the webview row.
Ties the spec, the config, the results and the PR comment together. (This is
*not* the contract's `run_id`: running-ng names its run directory itself.)

### `run_key` — string or null
The §8.1 content identity of the measurement: a hash over everything that could
change the numbers (runtimes, selection, sweeps, benches commit, running-ng X.Y,
contract version, tool versions, machine + environment fingerprint). Computed by
the server at submission — `lib/run_key.ml` is the implementation — and used to
answer repeat requests from the store. **Null when produced by `bench-gen`**: it
resolves no refs and knows no machine fingerprint, and a partial key would be a
wrong one.

### `family` — string
`"macro"` today; `"micro"` is reserved. Names which benchmark collection the run
draws from, so micro becomes a data change rather than a schema change.

### `request`
| field | meaning |
|---|---|
| `action` | `run` \| `rerun` \| `cancel` \| `help`. `rerun` means clean slate: bypass every cache and any stored result |
| `command` | the `/bench …` line verbatim, for the audit trail |
| `requested_by` | GitHub login, already checked against the allowlist |
| `pr_url` | may be null for a locally-triggered run |

### `placement`
| field | meaning |
|---|---|
| `machine` | registry name |
| `slot` | the unit of exclusion: `(host, OPAMROOT, benches dir)`. One slot = one concurrent run, because running-ng locks the opam root |
| `opamroot` | `$OPAMROOT` override, or null for the default. Two concurrent campaigns need separate roots |
| `macro_bench_dir` | becomes `RUNNING_MACRO_BENCH_DIR` |
| `log_dir` | becomes `LOG_DIR`; running-ng creates the run directory **inside** it |

No ssh: see the design rules. (Open question against the architecture document:
its §6.1 draft moves this whole block, plus `env` and `command`, into the
agent's own configuration. That section is not agreed yet, so the spec keeps
them for now.)

### `sources` — list
One entry per repo the run needs, in the order the agent should prepare them.
The first entry's `dir` is the working directory for the command.

| field | meaning |
|---|---|
| `name` | `running-ng` \| `macro-benches` |
| `dir` | checkout path **on the bench machine** |
| `ref` | what to check out, e.g. `origin/adding-ocaml-support` |
| `commit` | **null from the server.** The agent resolves the ref and writes back the sha it used |

### `baseline`, `candidates`
The compilers to measure, already pinned — a ref like `trunk` never reaches
here, because two runs labelled "trunk" must be the same commit. `baseline` is
exactly one runtime, the merge base by default; every delta is reported relative
to it, so which side is the baseline decides the sign of the whole report.
`candidates` is everything measured against it (may be empty: absolute numbers).

| field | meaning |
|---|---|
| `name` | the running-ng runtime name, e.g. `ocaml-pr-1234-c0f8c8c`. **This is the compiler cache key**: running-ng provisions the switch `running-ng-<name>` and treats it as the cache, which is why the name encodes the sha |
| `version` or `commit` | exactly one; both resolve to a git ref in running-ng. (The document's `runtime_pin` carries only `commit`; keeping `version` for released compilers is an open question raised against it) |
| `configure_args` | e.g. `--enable-flambda`. Part of run identity and of switch provenance; how it reaches running-ng's provisioning is an open question, so today it is carried, not acted on |

### `selection`
`tags` is a list — several tags select their **union**, exactly running-ng's
comma-separated `RUNNING_TAG` semantics. Each entry carries `name` (the
running-ng tag, `small_run`) and `requested` (what the user typed, `small`),
so acknowledgements can echo the user's own words. `programs` is how many
programs the whole selection resolves to, per running-ng's own tag filter
(union across tags, intersection with the enabled benchmarks).

### `measurement`
`invocations` — how many times each (benchmark, config) cell is run, each in a
fresh process; maps 1:1 onto running-ng's `invocations:`. Plus the expanded
`configs` list, its `config_count`, and `sweeps` as `{parameter: [values]}` —
the parameter being the OCAMLRUNPARAM letter that appears in the config.

### `config`
`filename`, `path` (where the agent should write it — it is also `CONFIG_FILE`
in `env`), `md5`, and `contents`. The digest only detects drift between the spec
and a file on disk; it is not a security boundary. The agent must write
`contents` to `path` rather than trusting anything already there.

### `env`
The exact environment for the command. Notable members:

- `RUNNING_TAG` — the benchmark selection. **Not a config field**: running-ng's
  `apply_tag_filter()` reads it from the environment, which is why a run spec
  cannot be just a YAML file.
- `RUNNING_REUSE_SWITCHES=1` — service policy. A switch is the compiler cache and
  a rebuild costs 10–20 min per runtime; correctness comes from the switch
  provenance check, not from rebuilding. Reuse takes a *shared* opam lock.
- `CONFIG_FILE`, `LOG_DIR`, `RUNNING_MACRO_BENCH_DIR`, and `OPAMROOT` when set.

### `command`
`cwd` and `argv`. `argv` is `["bash", "run_ocaml_bench_gc_sweep.sh"]` —
running-ng's build+run entry point, which finds or creates the tools switch,
builds and verifies olly, and puts both on `PATH` before calling
`python3 -m running runbms`. Invoking `runbms` directly would skip that setup.

The agent must start it in its **own process group** (`setsid`): cancellation
sends `SIGTERM` to the group so running-ng's `finally` can restore the user's
active opam switch, then escalates to `SIGKILL`. A bare `SIGKILL` skips that
cleanup. (The opam flock is safe either way — the kernel drops it on exit.)

### `artifacts`
`run_dir_parent` is `LOG_DIR`; the agent **discovers** the run directory beneath
it (running-ng names it `<host>-<timestamp>`, so the server cannot predict it).
`fetch` are the globs to bring back — contract artifacts, logs, the per-tool
sidecars, and the merged `runbms.yml`. `exclude` keeps raw memtrace traces on the
machine: they are large, and the store holds the small canonical artifacts
rather than bulk data.

Artifacts must be fetched **even when the run fails**. A run that dies at 45
minutes still has usable data: the contract degrades gracefully and a comparison
never hard-references a `config_id`.

### `limits`
`estimated_seconds` from the cost model (30 s per cell-invocation, calibrated on
20 min/invocation for two runtimes over the 20 `default_run` programs);
`cap_seconds`, the budget a request must fit unless an admin forces it; and
`timeout_seconds` = `max(90 min, 2.5 × estimate)`. The multiplier catches a
wedged run — a build waiting on input, a benchmark spinning — while the floor
covers cold compiler builds, which the estimate deliberately excludes because
they are cached and highly variable.

### `warnings`
Advisory strings for the acknowledgement comment. None blocks a run.

## What is deliberately NOT here

- **Credentials, and any way to reach a machine.** See the design rules.
- **The results destination.** The agent uploads artifacts; the server decides
  where they go. That keeps every publishing token off the bench machine and
  makes the server the single writer to the store.
- **Retry policy.** A spec describes one attempt. Re-running is the queue's
  decision, and `rerun` is a distinct action with clean-slate semantics.
- **Switch provenance.** The agent owns `switch-provenance.json`
  (`{compiler_sha, configure_args, dune_version, opam_repo_commit}`) because only
  it can observe what a switch was built from. The spec says *which* compilers to
  measure, not what is currently cached.
