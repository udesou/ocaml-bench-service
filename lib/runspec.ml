(* The run spec: the complete, serialised description of one benchmark run,
   produced by the server at submission, executed by the agent and archived
   beside the results.  docs/RUNSPEC.md is the normative prose; keep the two in
   step.  Everything is resolved before dispatch (shas, never refs); machine-side
   paths, environment and command line are the agent's and absent here. *)

let version = "1"

type source = {
  name : string;
  repo : string;  (** clone URL (a local path in dev setups) *)
  commit : string;  (** resolved by the server before dispatch; never a ref *)
}

let source ~name ~repo ~commit () = { name; repo; commit }

(* The config travels machine-independent: its `includes:` line names the base
   config under this placeholder and the agent substitutes its own running-ng
   path.  The md5 is of the contents as transported, placeholder included. *)
let running_ng_root_var = "${RUNNING_NG_ROOT}"

let base_include_placeholder =
  running_ng_root_var ^ "/src/running/config/base/ocaml/macro_base.yml"

(* The execution timeout: a safety net against wedged runs, not a scheduler.
   Disabled by default (multiplier 0 -> timeout 0) because the formula's inputs
   are guesses until a machine has an established result set; opt in with
   service.json `timeout`: max(floor_seconds, multiplier * estimate). *)
type timeout_policy = { floor_seconds : int; multiplier : float }

let default_timeout = { floor_seconds = 90 * 60; multiplier = 0.0 }

let timeout_of_estimate ?(policy = default_timeout) ~seconds () =
  if policy.multiplier <= 0.0 then 0
  else
    max policy.floor_seconds
      (int_of_float (float_of_int seconds *. policy.multiplier))

let timeout_seconds ~(cost : Cost.t) =
  timeout_of_estimate ~seconds:(int_of_float cost.seconds) ()

let str s = `String s
let opt_str = function None -> `Null | Some s -> `String s

(* The runtime_pin, with one deviation: a released compiler (vs=5.4.1) is
   provisioned by running-ng's `version:` field, so bench-gen's offline path
   keeps the version spelling; server-resolved pins always carry the sha. *)
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
            (* Several tags select their union (the agent sets RUNNING_TAG from this
               field); `requested` keeps the spelling the user typed. *)
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
            (* MD5 only to detect drift between the spec and a config on disk; same
               digest the contract uses for config_id. *)
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
