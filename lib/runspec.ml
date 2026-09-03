(* The run spec: the complete, serialised description of one benchmark run.

   The interface between the request server and the bench agent: the server
   produces it at submission; the agent executes it; a copy is archived next
   to the results as the run's provenance record (§6.1).  docs/RUNSPEC.md is
   the normative prose -- keep the two in step.

   The spec describes only WHAT to measure, and everything in it is resolved
   before dispatch -- every source and runtime carries a sha, never a ref --
   so it is executable and archivable as-is.  Deliberately ABSENT, because
   they are the agent's concern derived from its own configuration plus this
   spec: machine-side paths (checkout dirs, log dir, opam root), the process
   environment (the agent sets RUNNING_TAG from `selection.tags`), the
   command line, and any transport or credential.  Execution-scoped
   directives -- cache bypass for `rerun`, the timeout -- travel in the §6.2
   assignment at claim time, never in the spec.

   The service has never shipped, so this aligned shape IS version 1.  It
   carries the decided points: no ssh anywhere (Q1), `invocations` (Q17),
   `family` (§5.3), `run_key` (Q16, null until the server has agent-reported
   machine facts to hash), and baseline/candidates split as in §5.3's
   `resolved`, because which side is the baseline decides the sign of every
   delta.

   The macro-benches commit is in `sources` because it is part of the run's
   identity: benchmark binaries are cached as `<benchmark>-<runtime>` and the
   runtime name encodes only the COMPILER sha, so a benchmark-source change
   does not invalidate a cached binary -- without the pin, a run silently
   measures old benchmark code against a new compiler. *)

let version = "1"

type source = {
  name : string;
  repo : string;  (** clone URL (a local path in dev setups) *)
  commit : string;  (** resolved by the server before dispatch; never a ref *)
}

let source ~name ~repo ~commit () = { name; repo; commit }

(* NOT part of the spec: the timeout is execution-scoped (§6.2, the
   assignment), derived at claim time.  The formula lives here so the server
   and bench-gen's preview share one definition.  A run that has overshot its
   estimate by this much is wedged; the floor covers cold compiler builds,
   which the estimate deliberately excludes because they are cached and highly
   variable. *)
(* The config travels machine-independent (§6.1): its `includes:` line names
   the base config under this placeholder, and the AGENT substitutes its own
   running-ng checkout path when it materializes the file.  The md5 in the
   spec is of the contents as transported, placeholder included. *)
let running_ng_root_var = "${RUNNING_NG_ROOT}"

let base_include_placeholder =
  running_ng_root_var ^ "/src/running/config/base/ocaml/macro_base.yml"

(* The execution timeout the assignment carries: a safety net against wedged
   runs, not a scheduler.  floor covers cold compiler builds (excluded from
   the estimate: cached and highly variable); the multiplier absorbs estimate
   error.  Both are service.json `timeout` policy -- the estimate's
   cell_seconds is calibrated per deployment, and a slower machine can raise
   these or disable the net entirely (multiplier 0 -> timeout 0 -> the agent
   enforces no deadline). *)
type timeout_policy = { floor_seconds : int; multiplier : float }

let default_timeout = { floor_seconds = 90 * 60; multiplier = 2.5 }

let timeout_of_estimate ?(policy = default_timeout) ~seconds () =
  if policy.multiplier <= 0.0 then 0
  else
    max policy.floor_seconds
      (int_of_float (float_of_int seconds *. policy.multiplier))

let timeout_seconds ~(cost : Cost.t) =
  timeout_of_estimate ~seconds:(int_of_float cost.seconds) ()

let str s = `String s
let opt_str = function None -> `Null | Some s -> `String s

(* The §5.3 runtime_pin, with one deviation raised on the document: a released
   compiler (vs=5.4.1) is provisioned by running-ng's `version:` field, which a
   commit-only pin cannot express, so bench-gen's OFFLINE path keeps the
   version spelling; server-resolved pins always carry the sha. *)
let json_of_pin (v : Variant.t) =
  `Assoc
    ((("name", str (Variant.runtime_name v))
     :: List.map (fun (k, value) -> (k, str value)) (Variant.yaml_fields v))
    @ [
        ( "repo",
          str
            (Option.value v.Variant.repo
               ~default:"https://github.com/ocaml/ocaml") );
        ("configure_args", str v.Variant.configure_args);
      ])

let json_of_source s =
  `Assoc
    [ ("name", str s.name); ("repo", str s.repo); ("commit", str s.commit) ]

let json_of_sweep (sw : Request.sweep) =
  (sw.dimension, `List (List.map str sw.values))

let to_json ~(ctx : Gen.context) ~(request : Request.t) ~(spec : Gen.t)
    ~variants ~sources ~run_key =
  let cost = spec.Gen.cost in
  let baseline =
    match
      List.find_opt (fun v -> v.Variant.role = Variant.Baseline) variants
    with
    | Some v -> v
    | None -> List.hd variants
  in
  let candidates =
    List.filter
      (fun v -> Variant.runtime_name v <> Variant.runtime_name baseline)
      variants
  in
  `Assoc
    [
      ("spec_version", str version);
      ("run_id", str ctx.Gen.request_id);
      ("run_key", opt_str run_key);
      ("family", str (Api.string_of_family request.Request.family));
      ("sources", `List (List.map json_of_source sources));
      ("baseline", json_of_pin baseline);
      ("candidates", `List (List.map json_of_pin candidates));
      ( "selection",
        `Assoc
          [
            (* Several tags select their union (running-ng's comma-separated
               RUNNING_TAG, which the AGENT sets from this field);
               `requested` keeps the spelling the user typed. *)
            ( "tags",
              `List
                (List.map
                   (fun (requested, name) ->
                     `Assoc
                       [ ("name", str name); ("requested", str requested) ])
                   (Request.tag_pairs request)) );
            ("programs", `Int cost.Cost.programs);
          ] );
      ( "measurement",
        `Assoc
          [
            ("invocations", `Int cost.Cost.invocations);
            ("configs", `List (List.map str spec.Gen.configs));
            ("config_count", `Int cost.Cost.configs);
            ("sweeps", `Assoc (List.map json_of_sweep request.Request.sweeps));
          ] );
      ( "config",
        `Assoc
          [
            ("filename", str (ctx.Gen.request_id ^ ".yml"));
            (* MD5 only to detect drift between the spec and a config on disk;
               nothing here is a security boundary.  Same digest the contract
               uses for config_id. *)
            ("md5", str (Digest.to_hex (Digest.string spec.Gen.config_yaml)));
            ("contents", str spec.Gen.config_yaml);
          ] );
      ( "artifacts",
        `Assoc
          [
            ( "fetch",
              `List
                (List.map str
                   [
                     "contract/**";
                     "*.log";
                     "olly_*.json";
                     "perf_*.json";
                     "runbms.yml";
                     "runbms_args.yml";
                   ]) );
            (* Raw traces stay on the machine: they are large, and the store
               holds the small canonical artifacts, not bulk data. *)
            ("exclude", `List (List.map str [ "memtrace_*.trace" ]));
          ] );
      ("warnings", `List (List.map str spec.Gen.warnings));
    ]

let to_string ~ctx ~request ~spec ~variants ~sources ~run_key =
  Yojson.Safe.pretty_to_string
    (to_json ~ctx ~request ~spec ~variants ~sources ~run_key)
  ^ "\n"
