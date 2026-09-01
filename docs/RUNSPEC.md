# The run spec

The normative description of what the server hands to the bench agent for one
benchmark run (§6.1 of the architecture document). `lib/runspec.ml` is the
implementation; this file is the prose. Change both together.

A run spec is a single JSON object. It is produced by the request server at
submission, executed by the agent, and archived beside the results as the
run's provenance record.

## Design rules

**It describes WHAT to measure -- nothing else.** Everything machine-side is
deliberately absent, derived by the agent from its own configuration plus this
spec: checkout paths, log dir, opam root, the process environment (the agent
sets `RUNNING_TAG` from `selection.tags`, comma-joined), and the command line
(running-ng's entry script and how to supervise it are agent knowledge).
Execution-scoped directives -- cache bypass for `rerun`, the timeout -- travel
in the *assignment* the agent receives at claim time, never in the spec.

**Everything is resolved before dispatch.** Every source and runtime carries a
git sha, never a ref, so the spec is executable and archivable as-is. The
server pins sources from the checkouts it already reads
(`Resolver.local_source`: `rev-parse` the pinned ref, clone URL from the
checkout's `origin`).

**No credentials, no transport, ever.** The bench machine executes PR compiler
code and is treated as compromisable; the server never connects to it.

**Versioned.** `spec_version` is bumped on any incompatible change; a consumer
must refuse a major version it does not know. The service has never shipped,
so the current aligned shape **is version 1**.

## Fields

### `spec_version` -- string
Currently `"1"`.

### `run_id` -- string
The run's identity everywhere: the queue row, the store bundle, the webview
row. (Not the contract's `run_id`: running-ng names its run directory itself.)

### `run_key` -- string or null
The content identity of the measurement, used to answer repeat requests
from the store. Computed by the server (`lib/run_key.ml`); **null until agent
reports supply the machine facts it hashes** (tool versions, environment
fingerprint) -- a partial key would be a wrong one.

### `family` -- string
`"macro"` today; `"micro"` reserved. Names which benchmark collection
the run draws from, so micro becomes a data change rather than a schema change.

### `sources` -- list of `{name, repo, commit}`
One entry per repo the run needs: `running-ng`, `macro-benches` (or
`benches`, when micro lands), and `olly` (runtime_events_tools). `repo` is
the clone URL; `commit` is the sha the server resolved -- a snapshot of the
server's pins (`pins.json`, changed only by the admin `bump` op) at
submission time. The macro-benches commit is part of the
run's identity: benchmark binaries are cached as `<benchmark>-<runtime>` and
the runtime name encodes only the *compiler* sha, so a benchmark-source change
does not invalidate a cached binary -- without this pin, a run silently
measures old benchmark code against a new compiler.

### `baseline`, `candidates`
The compilers, already pinned -- a ref like `trunk` never reaches here.
`baseline` is exactly one runtime (the merge base by default); every delta is
reported relative to it, so which side is the baseline decides the sign of the
whole report. `candidates` is everything measured against it (may be empty:
absolute numbers).

| field | meaning |
|---|---|
| `name` | the running-ng runtime name, e.g. `ocaml-pr-1234-c0f8c8c`. **The compiler cache key**: running-ng provisions the switch `running-ng-<name>` |
| `commit` (or `version`) | server-resolved pins always carry the sha; `version` survives only in bench-gen's offline path (a raised doc question) |
| `configure_args` | e.g. `--enable-flambda`; part of run identity and switch provenance |

### `selection`
`tags` is a list of `{name, requested}` -- the resolved running-ng tag and the
spelling the user typed. Several tags select their **union** (running-ng's own
comma-separated `RUNNING_TAG` semantics; the agent sets that variable from
this field). `programs` is how many programs the selection resolves to, per
running-ng's own tag filter.

### `measurement`
`invocations` (fresh-process repetitions, running-ng's `invocations:`), the
expanded `configs` list, `config_count` (configs × sweep points), and `sweeps`
as `{parameter: [values]}`.

### `config`
`filename`, `md5`, `contents` -- the generated running-ng config travels
**inline**, so a spec can be archived, diffed, or replayed with no shared
filesystem. The contents are machine-independent: the `includes:` line names
the base config under the `${RUNNING_NG_ROOT}` placeholder, and the agent
substitutes its own running-ng checkout path when it materializes the file
(`Runspec.base_include_placeholder`). The agent writes the result wherever
its own layout dictates and must never trust a file already on disk; `md5`
is of the contents as transported (placeholder included) and only detects
drift, it is not a security boundary.

### `artifacts`
`fetch`: the globs the agent brings back -- contract artifacts, logs, per-tool
sidecars, the merged `runbms.yml`. `exclude` keeps raw memtrace traces on the
machine: they are large, and the store holds the small canonical artifacts.
Artifacts must be fetched **even when the run fails**: the contract degrades
gracefully, so a run that dies at 45 minutes still has usable data.

### `warnings`
Advisory strings surfaced in the acknowledgement. None blocks a run.

## What is deliberately NOT here

- **Machine-side anything**: paths, env, command line, ssh (the agent's
  concern). The agent discovers the run directory under its own
  `LOG_DIR` (running-ng names it), runs the entry script in its own process
  group (`setsid`, so cancellation can SIGTERM the group before SIGKILL), and
  reuses switches per its provenance records.
- **The timeout**: execution-scoped, carried by the assignment at claim
  time. The shared formula (`max(90 min, 2.5 × estimate)`) lives in
  `Runspec.timeout_seconds`.
- **The audit trail**: who asked, from where, the verbatim command -- that is
  `request.json` in the bundle, written by the server beside the spec.
- **Credentials and results destinations**: the agent uploads; the server
  publishes.
- **Retry policy**: a spec describes one run; re-running is the queue's
  decision, and `rerun` reaches the agent as the assignment's cache-bypass
  flag, not as spec content.
