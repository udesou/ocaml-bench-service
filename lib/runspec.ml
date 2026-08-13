(* The run spec: the complete, serialised description of one benchmark run.

   This is the S0 -> S1 interface.  The server produces it; the runner consumes
   it; a copy is archived next to the results as the request's provenance record.
   docs/RUNSPEC.md is the normative description -- keep the two in step.

   Three properties are deliberate:

   * **Self-contained.** The generated config travels inline, not as a path. A
     spec can be archived, replayed, or diffed on its own, and the runner does
     not need a shared filesystem with the server.
   * **Explicit about sources.** running-ng and macro-benches are pinned by ref,
     and the runner records the commit it actually checked out. The design doc
     requires the macro-benches commit in the run's identity: a change to
     benchmark source does NOT invalidate a cached binary (binaries are keyed
     `<benchmark>-<runtime>`, and the runtime name encodes only the compiler
     sha), so without this a run silently measures old benchmark code against a
     new compiler.
   * **No credentials, ever.** The bench machine executes PR compiler code and is
     treated as compromisable. The spec carries paths and refs, never tokens, and
     the runner returns results rather than publishing them. *)

let version = "1"

type source = {
  name : string;
  dir : string;  (** checkout on the bench machine *)
  git_ref : string;
  commit : string option;
      (** null from the server; the runner fills in what it checked out *)
}

let source ?commit ~name ~dir ~git_ref () = { name; dir; git_ref; commit }

(* A run that has overshot its estimate by this much is not going to finish:
   something is wedged (a build waiting on input, a benchmark spinning). Killing
   it frees the slot, and the queue re-runs deliberately rather than a lease
   expiring silently.  The floor covers cold compiler builds, which the estimate
   deliberately excludes because they are cached and highly variable. *)
let timeout_seconds ~(cost : Cost.t) =
  let floor_s = 90 * 60 in
  let scaled = int_of_float (cost.seconds *. 2.5) in
  max floor_s scaled

let str s = `String s
let opt_str = function None -> `Null | Some s -> `String s

let json_of_variant (v : Variant.t) =
  `Assoc
    ([
       ("name", str (Variant.runtime_name v));
       ("role", str (Variant.role_string v.role));
     ]
    @ List.map (fun (k, value) -> (k, str value)) (Variant.yaml_fields v))

let json_of_source s =
  `Assoc
    [
      ("name", str s.name);
      ("dir", str s.dir);
      ("ref", str s.git_ref);
      ("commit", opt_str s.commit);
    ]

let json_of_sweep (sw : Request.sweep) =
  (sw.dimension, `List (List.map str sw.values))

let action_string (r : Request.t) =
  match r.action with
  | Request.Run -> "run"
  | Request.Rerun -> "rerun"
  | Request.Cancel -> "cancel"
  | Request.Help -> "help"

(* The command the runner executes.  `run_ocaml_bench_gc_sweep.sh` is
   running-ng's build+run entry point; it finds or creates the tools switch,
   builds and verifies olly, puts both on PATH, then calls `python3 -m running
   runbms`.  Invoking runbms directly would skip that setup. *)
let entry_script = "run_ocaml_bench_gc_sweep.sh"

let to_json ~(ctx : Gen.context) ~(request : Request.t) ~(spec : Gen.t)
    ~variants ~sources ~ssh ~slot =
  let cost = spec.cost in
  `Assoc
    [
      ("runspec_version", str version);
      ( "request",
        `Assoc
          [
            ("id", str ctx.request_id);
            ("action", str (action_string request));
            ("command", str (Util.trim request.raw));
            ("requested_by", opt_str ctx.requested_by);
            ("pr_url", opt_str ctx.pr_url);
          ] );
      ( "placement",
        `Assoc
          [
            ("machine", str ctx.machine);
            ("slot", str slot);
            ("ssh", str ssh);
            ("opamroot", opt_str ctx.opamroot);
            ("macro_bench_dir", str ctx.macro_bench_dir);
            ("log_dir", str ctx.log_dir);
          ] );
      ("sources", `List (List.map json_of_source sources));
      ("runtimes", `List (List.map json_of_variant variants));
      ( "selection",
        `Assoc
          [
            ("tag", str spec.tag);
            ("tag_requested", str (Request.requested_tag request));
            ("programs", `Int cost.programs);
          ] );
      ( "measurement",
        `Assoc
          [
            ("iterations", `Int cost.iterations);
            ("configs", `List (List.map str spec.configs));
            ("config_count", `Int cost.configs);
            ("sweeps", `Assoc (List.map json_of_sweep request.sweeps));
          ] );
      ( "config",
        `Assoc
          [
            ("filename", str (Filename.basename ctx.config_path));
            ("path", str ctx.config_path);
            (* MD5 only to detect drift between the spec and a config on disk;
               nothing here is a security boundary.  Same digest the contract
               uses for config_id. *)
            ("md5", str (Digest.to_hex (Digest.string spec.config_yaml)));
            ("contents", str spec.config_yaml);
          ] );
      ("env", `Assoc (List.map (fun (k, v) -> (k, str v)) spec.env));
      ( "command",
        `Assoc
          [
            ("cwd", str (match sources with s :: _ -> s.dir | [] -> "."));
            ("argv", `List [ str "bash"; str entry_script ]);
          ] );
      ( "artifacts",
        `Assoc
          [
            (* running-ng names the run directory itself
               (<host>-<timestamp>) under LOG_DIR, so the runner discovers it
               rather than being told: the server cannot predict the name. *)
            ("run_dir_parent", str ctx.log_dir);
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
            (* Raw traces stay on the machine: they are large, and the results
               repo is not an artifact store (design doc section 10). *)
            ("exclude", `List (List.map str [ "memtrace_*.trace" ]));
          ] );
      ( "limits",
        `Assoc
          [
            ("estimated_seconds", `Int (int_of_float cost.seconds));
            ("timeout_seconds", `Int (timeout_seconds ~cost));
            ("cap_seconds", `Int (int_of_float ctx.cap_seconds));
          ] );
      ("warnings", `List (List.map str spec.warnings));
    ]

let to_string ~ctx ~request ~spec ~variants ~sources ~ssh ~slot =
  Yojson.Safe.pretty_to_string
    (to_json ~ctx ~request ~spec ~variants ~sources ~ssh ~slot)
  ^ "\n"
