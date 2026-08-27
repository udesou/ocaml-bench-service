(* Acceptance tests for request generation.

   Four groups:

   1. Comment parsing -- a table of inputs to expected outcomes.  Rejections are
      asserted on the *user-facing message*, because that message is the product:
      it gets posted back to a PR verbatim.
   2. Generation -- request + fixture facts -> exact YAML, plus the rules that
      are easy to regress silently (comparison shape, sweep modifier
      definitions, the lavyek modifier chain, invocations via overrides).
   3. Authorisation (roles, admin-only keys) and cost.
   4. The run spec and the run key.

   All of it runs against the fixtures, so no python, no network, no machine.
   scripts/live_check.sh covers the live configs and running-ng's real
   validate(). *)

open Bench_service

let failures = ref 0
let checks = ref 0

let fail fmt =
  Printf.ksprintf
    (fun s ->
      incr failures;
      print_string ("FAIL  " ^ s ^ "\n"))
    fmt

let ok name =
  incr checks;
  ignore name

let check_eq ~name ~expected ~actual =
  incr checks;
  if expected <> actual then
    fail "%s\n      expected: %S\n      actual:   %S" name expected actual

let check_true ~name cond = incr checks; if not cond then fail "%s" name

(* JSON accessors return options, so compare them without losing which side was
   absent -- "expected Some x, got None" is the failure that actually happens. *)
let show_opt = function None -> "<absent>" | Some s -> s

let check_eq_opt ~name ~expected ~actual =
  incr checks;
  if expected <> actual then
    fail "%s\n      expected: %S\n      actual:   %S" name (show_opt expected)
      (show_opt actual)

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let check_contains ~name ~needle actual =
  incr checks;
  if not (contains ~needle actual) then
    fail "%s\n      expected to contain: %S\n      actual: %S" name needle actual

(* --- fixtures ------------------------------------------------------------ *)

let facts =
  match Facts.of_file "fixtures/facts_macro_base.json" with
  | Ok f -> f
  | Error e -> failwith ("fixture facts: " ^ e)

let sweepable =
  match Vocab.of_file "fixtures/vocab.json" with
  | Ok d -> d
  | Error e -> failwith ("fixture vocab: " ^ e)

let base_v =
  {
    Variant.label = "base";
    spec = Variant.Version "5.5.0";
    role = Variant.Baseline;
    repo = None;
    configure_args = "";
  }

let head_v =
  {
    Variant.label = "pr-1234";
    spec = Variant.Commit "c0f8c8ceef751fb3a99652d3d52399db3d1c2aae";
    role = Variant.Candidate;
    repo = None;
    configure_args = "";
  }

let ctx ?(program_count = 20) ?(cap_seconds = Cost.default_cap_seconds) () =
  {
    Gen.request_id = "req-test";
    base_include = "/base/macro_base.yml";
    config_path = "/runs/req-test.yml";
    macro_bench_dir = "/macro-benches";
    log_dir = "/runs";
    opamroot = None;
    machine = "monolith";
    requested_by = Some "udesou";
    pr_url = Some "https://github.com/udesou/ocaml/pull/1";
    program_count;
    cell_seconds = Cost.default_cell_seconds;
    cap_seconds;
  }

(* Generation refusals are API A error envelopes; parse refusals are plain
   strings until the server wraps them.  For the table tests both collapse to
   the postable markdown. *)
let gen ?program_count ?cap_seconds ?(variants = [ base_v; head_v ]) comment =
  match Request.parse comment with
  | Error e -> Error { Api.code = Api.Bad_command; error_markdown = e }
  | Ok request ->
    Gen.generate ~ctx:(ctx ?program_count ?cap_seconds ()) ~request ~facts
      ~sweepable ~variants

let markdown (e : Api.error) = e.Api.error_markdown

(* --- 1. parsing ---------------------------------------------------------- *)

(* Each row: comment, and either the field we assert or the message fragment a
   rejection must contain. *)
let parse_accepts =
  [
    ("/bench", fun (r : Request.t) -> Request.invocations_or_default r = 3);
    ("/bench", fun r -> Request.resolved_tags r = [ "default_run" ]);
    ("/bench", fun r -> r.family = Api.Macro && r.priority = None);
    ("/bench tag=small", fun r -> Request.resolved_tags r = [ "small_run" ]);
    ("/bench tag=all", fun r -> Request.resolved_tags r = [ "all_benches" ]);
    ("/bench tag=legacy", fun r -> Request.resolved_tags r = [ "legacy" ]);
    (* Several tags select their union, running-ng's own semantics. *)
    ( "/bench tag=small,large",
      fun r -> Request.resolved_tags r = [ "small_run"; "large_run" ] );
    (* Unaliased names fall through, so feature tags stay reachable. *)
    ("/bench tag=bigarrays", fun r -> Request.resolved_tags r = [ "bigarrays" ]);
    ("/bench invocations=5", fun r -> Request.invocations_or_default r = 5);
    ("/bench vs=trunk", fun r -> r.vs = [ "trunk" ]);
    ("/bench vs=5.4.1,trunk", fun r -> r.vs = [ "5.4.1"; "trunk" ]);
    (* Cancellation is by explicit run id, from the acknowledgement comment. *)
    ("/bench cancel run-42", fun r -> r.action = Request.Cancel "run-42");
    ("/bench rerun", fun r -> r.action = Request.Rerun);
    ("/bench help", fun r -> r.action = Request.Help);
    ("/bench force=true", fun r -> r.force);
    ("/bench family=macro", fun r -> r.family = Api.Macro);
    ("/bench priority=top", fun r -> r.priority = Some Request.Top);
    ("/bench machine=monolith", fun r -> r.machine = Some "monolith");
    ( "/bench sweep=s:262144,524288;o:80,120",
      fun r ->
        List.map (fun (s : Request.sweep) -> (s.dimension, s.values)) r.sweeps
        = [ ("s", [ "262144"; "524288" ]); ("o", [ "80"; "120" ]) ] );
    (* Repeated sweep= is equivalent to the semicolon form. *)
    ( "/bench sweep=s:1 sweep=o:2",
      fun r -> List.length r.sweeps = 2 );
    (* Prose around the command, and CRLF from GitHub. *)
    ("Looks slow.\r\n/bench tag=small\r\nthanks!", fun r ->
       Request.resolved_tags r = [ "small_run" ]);
    (* Extra whitespace. *)
    ("/bench   invocations=2    tag=large", fun r ->
       Request.invocations_or_default r = 2
       && Request.resolved_tags r = [ "large_run" ]);
  ]

let parse_rejects =
  [
    ("/bench tags=small", "Did you mean `tag`?");
    ("/bench tag=", "empty value");
    ("/bench invocations=0", "at least 1");
    ("/bench invocations=99", "exceeds the limit of 10");
    ("/bench invocations=many", "not a positive whole number");
    (* The prototype's key.  Everyone migrating will type it, so the message
       must point at the replacement, not guess at a typo (Q17). *)
    ("/bench iterations=5", "use `invocations=5`");
    ("/bench sweep=s", "missing a value list");
    ("/bench sweep=:1,2", "empty parameter name");
    ("/bench sweep=s:1 sweep=s:2", "more than once");
    ("/bench tag=small tag=large", "more than once");
    ("/bench tag=small,small", "more than once");
    ("/bench force=maybe", "must be `true` or `false`");
    ("/bench cancel", "needs the id of the run");
    (* family is reserved space (§12): explicit macro works, micro is refused
       politely, anything else is an error. *)
    ("/bench family=micro", "reserved but not yet supported");
    ("/bench family=nano", "not a benchmark family");
    ("/bench priority=high", "the only priority is `top`");
    ("/bench wat", "Unrecognised argument `wat`");
    ("no command here", "No `/bench` command found");
    ("/benchmarks are slow", "No `/bench` command found");
  ]

let test_parsing () =
  List.iter
    (fun (comment, pred) ->
      match Request.parse comment with
      | Error e -> fail "parse %S rejected: %s" comment e
      | Ok r -> check_true ~name:(Printf.sprintf "parse %S" comment) (pred r))
    parse_accepts;
  List.iter
    (fun (comment, needle) ->
      match Request.parse comment with
      | Ok _ -> fail "parse %S should have been rejected" comment
      | Error e ->
        check_contains ~name:(Printf.sprintf "reject %S" comment) ~needle e)
    parse_rejects

(* --- 2. generation ------------------------------------------------------- *)

(* The golden config for a bare /bench.  Written out in full deliberately: this
   is the artifact that ends up in the store, and a diff here should be a
   conscious decision rather than something noticed later in a run directory. *)
let golden_default =
  {|# =============================================================================
# Generated by ocaml-bench-service -- do not edit by hand
# =============================================================================
# request_id:   req-test
# command:      /bench
# pull request: https://github.com/udesou/ocaml/pull/1
# requested by: udesou
# machine:      monolith
# benchmarks:   default (20 programs)
# estimate:     1h00m (20 programs x 2 configs x 3 invocations = 120 measurements)
#
# Runtimes:
#   ocaml-base-5.5.0         baseline       version 5.5.0
#   ocaml-pr-1234-c0f8c8c    candidate      commit c0f8c8ceef751fb3a99652d3d52399db3d1c2aae
# =============================================================================

includes:
  - "/base/macro_base.yml"

overrides:
  invocations: 3

# =============================================================================
# Runtimes
# =============================================================================
runtimes:
  ocaml-base-5.5.0:
    type: OCaml
    version: "5.5.0"
  ocaml-pr-1234-c0f8c8c:
    type: OCaml
    commit: "c0f8c8ceef751fb3a99652d3d52399db3d1c2aae"

# =============================================================================
# Configs
# =============================================================================
configs:
  - "ocaml-base-5.5.0|perf_grp1"
  - "ocaml-pr-1234-c0f8c8c|perf_grp1"

# =============================================================================
# Comparisons
# =============================================================================
comparisons:
  - label: "ocaml-base-5.5.0 -> ocaml-pr-1234-c0f8c8c"
    a: ocaml-base-5.5.0
    b: [ocaml-pr-1234-c0f8c8c]
|}

let test_golden () =
  match gen "/bench" with
  | Error e -> fail "golden: generation failed: %s" (markdown e)
  | Ok spec ->
    check_eq ~name:"golden default config" ~expected:golden_default
      ~actual:spec.config_yaml

let test_shape_rules () =
  (match gen "/bench" with
  | Error e -> fail "shape: %s" (markdown e)
  | Ok spec ->
    (* comparisons use running-ng's a/b form, not the contract's kind/over. *)
    check_contains ~name:"comparison uses a:" ~needle:"    a: ocaml-base-5.5.0"
      spec.config_yaml;
    check_true ~name:"comparison does not use the contract shape"
      (not (contains ~needle:"kind: inter" spec.config_yaml));
    (* invocations must go through overrides, never top level. *)
    check_contains ~name:"invocations under overrides"
      ~needle:"overrides:\n  invocations: 3" spec.config_yaml;
    (* Since running-ng #15 the ring/domain settings live on the benchmarks, so
       a generated config must carry NEITHER re/md nor the parallel triple (no
       lavyek suite is enabled).  Emitting re-25|md-2 here would reintroduce a
       global value under every benchmark's own. *)
    check_true ~name:"no re/md when the base uses ocamlrunparam"
      (not (contains ~needle:"re-25" spec.config_yaml)
      && not (contains ~needle:"md-2" spec.config_yaml));
    check_true ~name:"no lavyek triple when no lavyek suite is enabled"
      (not (contains ~needle:"pin_lavyek" spec.config_yaml));
    check_contains ~name:"bare perf modifier" ~needle:"|perf_grp1\"" spec.config_yaml;
    (* no Zulip plugin. *)
    check_true ~name:"no plugins block"
      (not (contains ~needle:"plugins:" spec.config_yaml));
    check_true ~name:"RUNNING_TAG is in the env, not the config"
      (List.assoc_opt "RUNNING_TAG" spec.env = Some "default_run"
      && not (contains ~needle:"tags:" spec.config_yaml));
    check_true ~name:"switch reuse is on"
      (List.assoc_opt "RUNNING_REUSE_SWITCHES" spec.env = Some "1"));
  (* A sweep must define its modifier: s/o/M/m are absent from macro_base. *)
  match gen "/bench invocations=1 sweep=o:80,120" with
  | Error e -> fail "sweep: %s" (markdown e)
  | Ok spec ->
    check_contains ~name:"sweep defines the modifier"
      ~needle:"modifiers:\n  o:\n    type: OCamlRunParam\n    val: \"o={0}\""
      spec.config_yaml;
    check_contains ~name:"sweep emits config_sweep"
      ~needle:"config_sweep:\n  o: [80, 120]" spec.config_yaml;
    check_true ~name:"sweep multiplies the config count"
      (List.length spec.configs = 2 && spec.cost.configs = 4)

(* Several tags are running-ng's own union semantics, driven through the
   comma-separated RUNNING_TAG it already parses. *)
let test_multi_tag () =
  match gen "/bench tag=small,large invocations=1" with
  | Error e -> fail "multi-tag: %s" (markdown e)
  | Ok spec ->
    check_true ~name:"RUNNING_TAG carries the comma-separated union"
      (List.assoc_opt "RUNNING_TAG" spec.env = Some "small_run,large_run");
    check_true ~name:"the generated spec records both tags"
      (spec.tags = [ "small_run"; "large_run" ])

let test_canonical_dimension_spelling () =
  (* `sweep=space_overhead:...` and `sweep=o:...` must produce the same run, so
     the contract's vocabulary and the shorthand cannot diverge.  The `# command:`
     line is excluded: it echoes what the user typed, and *should* differ. *)
  let without_command yaml =
    Util.split_on ~sep:'\n' yaml
    |> List.filter (fun l -> not (Util.starts_with ~prefix:"# command:" l))
    |> String.concat "\n"
  in
  match (gen "/bench sweep=o:80", gen "/bench sweep=space_overhead:80") with
  | Ok a, Ok b ->
    check_eq ~name:"short and canonical sweep spellings agree"
      ~expected:(without_command a.config_yaml)
      ~actual:(without_command b.config_yaml)
  | _ -> fail "canonical spelling: generation failed"

(* The modifier chain is derived from the base config, not hardcoded, because
   running-ng moved the ring settings onto benchmarks mid-project (#15) and could
   move the parallel ones next.  These two cases pin both directions. *)
let facts_variant ~uses_ocamlrunparam ~lavyek_enabled =
  let lavyek_progs = if lavyek_enabled then {|["lavyek_kv_1d"]|} else "[]" in
  let json =
    Printf.sprintf
      {|{ "ok": true, "invocations": 3, "schema_version": "1.0",
          "uses_ocamlrunparam": %b,
          "tags": [{"name":"default_run","programs":20,"gap":false}],
          "suites": [
            {"name":"macro-cpdf-monorepo","programs":["cpdf_merge"],
             "enabled":["cpdf_merge"],"ocamlrunparam":%s},
            {"name":"macro-lavyek-monorepo","programs":["lavyek_kv_1d"],
             "enabled":%s,"ocamlrunparam":null}],
          "modifiers": [{"name":"perf_grp1"},{"name":"re"},{"name":"md"},
                        {"name":"re_par"},{"name":"md_par"},{"name":"pin_lavyek"}] }|}
      uses_ocamlrunparam
      (if uses_ocamlrunparam then {|"e=25,d=2"|} else "null")
      lavyek_progs
  in
  match Facts.of_json_string json with
  | Ok f -> f
  | Error e -> failwith ("synthetic facts: " ^ e)

let gen_with ~facts comment =
  match Request.parse comment with
  | Error e -> Error { Api.code = Api.Bad_command; error_markdown = e }
  | Ok request ->
    Gen.generate ~ctx:(ctx ()) ~request ~facts ~sweepable
      ~variants:[ base_v; head_v ]

let test_modifier_chain () =
  (* Pre-#15 base: the ring settings must still travel in the config string. *)
  (match
     gen_with
       ~facts:(facts_variant ~uses_ocamlrunparam:false ~lavyek_enabled:false)
       "/bench"
   with
  | Error e -> fail "pre-#15 chain: %s" (markdown e)
  | Ok spec ->
    check_contains ~name:"pre-#15 emits re/md" ~needle:"|perf_grp1|re-25|md-2\""
      spec.config_yaml;
    check_true ~name:"pre-#15 warns that it is doing so"
      (List.exists (contains ~needle:"pre-#15") spec.warnings));
  (* A lavyek suite with enabled programs: the parallel triple is mandatory,
     because without it olly drops events and wall_time goes negative. *)
  match
    gen_with
      ~facts:(facts_variant ~uses_ocamlrunparam:true ~lavyek_enabled:true)
      "/bench"
  with
  | Error e -> fail "lavyek chain: %s" (markdown e)
  | Ok spec ->
    check_contains ~name:"lavyek enabled adds the parallel triple"
      ~needle:"|perf_grp1|re_par-22|md_par-8|pin_lavyek\"" spec.config_yaml;
    check_true ~name:"lavyek chain is explained in a warning"
      (List.exists (contains ~needle:"macro-lavyek-monorepo") spec.warnings)

(* `a:` is the baseline, and the baseline must be the merge base: the dashboard
   reports the variant's change *relative to* it, so swapping the sides inverts
   the sign of every delta and makes an improvement look like a regression. *)
let test_baseline_direction () =
  (match gen "/bench" with
  | Error e -> fail "baseline direction: %s" (markdown e)
  | Ok spec ->
    check_contains ~name:"merge base is a:" ~needle:"    a: ocaml-base-5.5.0"
      spec.config_yaml;
    check_contains ~name:"PR head is b:"
      ~needle:"    b: [ocaml-pr-1234-c0f8c8c]" spec.config_yaml);
  (* Moving the Baseline role must move which side is `a:`. *)
  match
    gen
      ~variants:
        [
          { base_v with role = Variant.Candidate };
          { head_v with role = Variant.Baseline };
        ]
      "/bench"
  with
  | Error e -> fail "baseline direction (swapped): %s" (markdown e)
  | Ok spec ->
    check_contains ~name:"role swap moves a:"
      ~needle:"    a: ocaml-pr-1234-c0f8c8c" spec.config_yaml;
    check_contains ~name:"role swap moves b:" ~needle:"    b: [ocaml-base-5.5.0]"
      spec.config_yaml

let test_single_runtime () =
  match gen ~variants:[ head_v ] "/bench" with
  | Error e -> fail "single runtime: %s" (markdown e)
  | Ok spec ->
    (* validate() rejects a runtime in configs that no comparison references,
       so a lone runtime must emit no comparisons block at all. *)
    check_true ~name:"no comparisons block for a single runtime"
      (not (contains ~needle:"comparisons:" spec.config_yaml));
    check_true ~name:"single runtime warns"
      (List.exists (contains ~needle:"no comparison will be declared") spec.warnings)

let gen_rejects =
  [
    ("/bench tag=smal", "Did you mean `small`?");
    ("/bench tag=ephemerons", "coverage gap");
    ("/bench tag=nonsense", "Unknown benchmark set");
    ("/bench sweep=nonsense:1,2", "Cannot sweep `nonsense`");
    ("/bench sweep=o:cheese", "expects whole numbers");
    ("/bench sweep=o:80;space_overhead:120", "same parameter twice");
  ]

let test_gen_rejects () =
  List.iter
    (fun (comment, needle) ->
      match gen comment with
      | Ok _ -> fail "generate %S should have been rejected" comment
      | Error e ->
        check_contains
          ~name:(Printf.sprintf "gen reject %S" comment)
          ~needle (markdown e))
    gen_rejects;
  (* Duplicate runtime names would silently share one opam switch. *)
  match gen ~variants:[ base_v; { base_v with role = Variant.Candidate } ] "/bench" with
  | Ok _ -> fail "duplicate runtime names should have been rejected"
  | Error e ->
    check_contains ~name:"duplicate runtimes" ~needle:"same name" (markdown e)

let test_variant_naming () =
  (* The runtime name is the compiler cache key, so it must carry the sha. *)
  check_eq ~name:"commit runtime name" ~expected:"ocaml-pr-1234-c0f8c8c"
    ~actual:(Variant.runtime_name head_v);
  check_eq ~name:"version runtime name" ~expected:"ocaml-base-5.5.0"
    ~actual:(Variant.runtime_name base_v);
  (* An unresolved ref must never reach a config: two runs labelled "trunk"
     would not be the same trunk. *)
  check_true ~name:"unresolved ref rejected"
    (Result.is_error
       (Variant.validate { base_v with spec = Variant.Commit "trunk" }));
  check_true ~name:"short sha rejected"
    (Result.is_error (Variant.validate { base_v with spec = Variant.Commit "abc" }));
  (* Switch names must survive being pasted into `running-ng-<name>`. *)
  check_eq ~name:"label sanitised" ~expected:"ocaml-feat-x-y-c0f8c8c"
    ~actual:(Variant.runtime_name { head_v with label = "feat/x y" });
  (* The optional configure-args tail, colons and all. *)
  (match Variant.of_cli_string "commit:fp:c0f8c8ceef751fb3a99652d3d52399db3d1c2aae:--enable-frame-pointers" with
  | Ok v ->
    check_eq ~name:"configure args parsed"
      ~expected:"--enable-frame-pointers" ~actual:v.configure_args;
    (* The name is the compiler cache key and must be injective in
       (sha, configure_args): running-ng trusts the config author -- us --
       for uniqueness, so two configurations of one commit must not share a
       switch. *)
    check_eq ~name:"configure args enter the runtime name"
      ~expected:("ocaml-fp-c0f8c8c-" ^ Variant.args_slug "--enable-frame-pointers")
      ~actual:(Variant.runtime_name v);
    check_true ~name:"different args, different name"
      (Variant.runtime_name v
      <> Variant.runtime_name { v with configure_args = "--enable-flambda" })
  | Error e -> fail "configure args variant rejected: %s" e);
  (* The generated config carries the list running-ng feeds to
     `opam compiler create --configure-command`. *)
  (let fp =
     {
       head_v with
       label = "fp";
       repo = Some "https://github.com/udesou/ocaml";
       configure_args = "--enable-frame-pointers --enable-flambda";
     }
   in
   match gen ~variants:[ base_v; fp ] "/bench" with
   | Error e -> fail "fp generation: %s" (markdown e)
   | Ok spec ->
     check_contains ~name:"config emits configure_args as a list"
       ~needle:
         "    configure_args: [\"--enable-frame-pointers\", \
          \"--enable-flambda\"]"
       spec.config_yaml;
     (* a fork PR's head builds from the fork, not the default repo *)
     check_contains ~name:"config emits the pin's repo"
       ~needle:"    repo: \"https://github.com/udesou/ocaml\""
       spec.config_yaml);
  match Variant.of_cli_string "version:base:5.5.0" with
  | Ok v -> check_eq ~name:"configure args default empty" ~expected:"" ~actual:v.configure_args
  | Error e -> fail "plain variant rejected: %s" e

(* --- 3. cost and authorisation ------------------------------------------- *)

let test_cost () =
  (* The calibration point: 20 min per invocation for 2 runtimes over the 20
     default_run programs.  If this drifts, every estimate is wrong. *)
  let c = Cost.estimate ~programs:20 ~configs:2 ~invocations:1 () in
  check_eq ~name:"calibration: 1 invocation is 20m" ~expected:"20m"
    ~actual:(Cost.human c.seconds);
  let c3 = Cost.estimate ~programs:20 ~configs:2 ~invocations:3 () in
  check_eq ~name:"calibration: 3 invocations is 1h" ~expected:"1h00m"
    ~actual:(Cost.human c3.seconds);
  check_true ~name:"default request is inside the cap" (not (Cost.over_cap c3));
  (* all_benches at 3 invocations must be refused. *)
  (match gen ~program_count:92 "/bench tag=all" with
  | Ok _ -> fail "tag=all should exceed the cap"
  | Error e ->
    check_true ~name:"cap refusal carries the over_budget code"
      (e.Api.code = Api.Over_budget);
    check_contains ~name:"cap refusal names the estimate" ~needle:"4h36m"
      (markdown e);
    check_contains ~name:"cap refusal says what to shrink" ~needle:"invocations="
      (markdown e);
    check_contains ~name:"cap refusal says force is admin-only" ~needle:"admin"
      (markdown e));
  (* force=true overrides, and says so.  (Whether the ASKER may say force= is
     Authz's decision, tested below; generation only honours it.) *)
  match gen ~program_count:92 "/bench tag=all force=true" with
  | Error e -> fail "force=true should be accepted: %s" (markdown e)
  | Ok spec ->
    check_true ~name:"forced run warns"
      (List.exists (contains ~needle:"force=true") spec.warnings)

let service_config =
  match
    Service_config.of_string
      {|{ "bot": {"account":"bot-acct","token_env":"TOK"},
          "results_repo":"u/r",
          "allowlist":["Udesou","watcher"],
          "admins":["Admin-Person"],
          "allow_associations":[],
          "machines":[{"name":"monolith","default":true,
                       "macro_bench_dir":"/mb","log_dir":"/logs"}] }|}
  with
  | Ok c -> c
  | Error e -> failwith ("service config fixture: " ^ e)

let test_authz () =
  let d = Authz.check service_config ~login:"udesou" ~association:None in
  check_true ~name:"allowlist is case-insensitive" (Authz.allowed d);
  check_true ~name:"allowlisted login is a user"
    (Authz.auth d = Some { Api.login = "udesou"; role = Api.User });
  let d = Authz.check service_config ~login:"ADMIN-person" ~association:None in
  check_true ~name:"admins get the admin role (case-insensitive)"
    (Authz.auth d = Some { Api.login = "admin-person"; role = Api.Admin });
  let d = Authz.check service_config ~login:"stranger" ~association:(Some "OWNER") in
  check_true ~name:"OWNER alone is not enough by default" (not (Authz.allowed d));
  check_contains ~name:"denial explains itself" ~needle:"allowlist"
    (Authz.message d);
  let d = Authz.check service_config ~login:"" ~association:None in
  check_true ~name:"empty login denied" (not (Authz.allowed d));
  (* The escape hatch works when explicitly configured. *)
  let with_assoc = { service_config with allow_associations = [ "OWNER" ] } in
  check_true ~name:"allow_associations opt-in works"
    (Authz.allowed (Authz.check with_assoc ~login:"stranger" ~association:(Some "OWNER")));
  (* A config nobody can use is a configuration error, not a silent lockout. *)
  check_true ~name:"empty allowlist rejected"
    (Result.is_error
       (Service_config.of_string
          {|{ "bot":{"account":"a"}, "results_repo":"u/r", "allowlist":[],
              "machines":[{"name":"m","macro_bench_dir":"/mb","log_dir":"/l"}] }|}));
  check_true ~name:"no machines rejected"
    (Result.is_error
       (Service_config.of_string
          {|{ "bot":{"account":"a"}, "results_repo":"u/r",
              "allowlist":["x"], "machines":[] }|}));
  (* The bot account is config, never a constant. *)
  check_eq ~name:"bot account is configurable" ~expected:"bot-acct"
    ~actual:service_config.bot.account;
  check_true ~name:"unknown machine rejected with the list"
    (match Service_config.resolve_machine service_config (Some "nope") with
    | Error e -> contains ~needle:"Registered machines: monolith" e
    | Ok _ -> false)

(* The admin-only grammar keys (Q4: force, Q10: priority).  Parsed for
   everyone, refused per-role before any generation work. *)
let test_admin_keys () =
  let user = { Api.login = "udesou"; role = Api.User } in
  let admin = { Api.login = "admin-person"; role = Api.Admin } in
  let req comment =
    match Request.parse comment with Ok r -> r | Error e -> failwith e
  in
  (match Authz.vet_request user (req "/bench force=true") with
  | Ok () -> fail "force=true by a user should be forbidden"
  | Error e ->
    check_true ~name:"force refusal is Forbidden" (e.Api.code = Api.Forbidden);
    check_contains ~name:"force refusal explains the alternative"
      ~needle:"admin-only" e.Api.error_markdown);
  (match Authz.vet_request user (req "/bench priority=top") with
  | Ok () -> fail "priority=top by a user should be forbidden"
  | Error e ->
    check_true ~name:"priority refusal is Forbidden" (e.Api.code = Api.Forbidden));
  check_true ~name:"a plain request passes vetting"
    (Authz.vet_request user (req "/bench tag=small") = Ok ());
  check_true ~name:"admins may force"
    (Authz.vet_request admin (req "/bench force=true priority=top") = Ok ())

(* --- 4. the run spec (docs/RUNSPEC.md) and the run key -------------------- *)

let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let jstr j = match j with `String x -> Some x | _ -> None
let jint j = match j with `Int i -> Some i | _ -> None

let test_runspec () =
  match gen "/bench tag=small invocations=1" with
  | Error e -> fail "runspec: generation failed: %s" (markdown e)
  | Ok spec ->
    let rng_sha = "1111111111111111111111111111111111111111" in
    let mb_sha = "2222222222222222222222222222222222222222" in
    let sources =
      [
        Runspec.source ~name:"running-ng"
          ~repo:"https://github.com/udesou/running-ng" ~commit:rng_sha ();
        Runspec.source ~name:"macro-benches"
          ~repo:"https://github.com/ocaml-bench/macro-benches" ~commit:mb_sha
          ();
      ]
    in
    let request =
      match Request.parse "/bench tag=small invocations=1" with
      | Ok r -> r
      | Error e -> failwith e
    in
    let j =
      Runspec.to_json ~ctx:(ctx ()) ~request ~spec
        ~variants:[ base_v; head_v ] ~sources ~run_key:None
    in
    check_eq_opt ~name:"runspec is versioned" ~expected:(Some "1")
      ~actual:(jstr (member "spec_version" j));
    check_eq_opt ~name:"runspec carries the run id" ~expected:(Some "req-test")
      ~actual:(jstr (member "run_id" j));
    (* family reserves the micro space (§5.3): a data change, not a schema
       change, when the time comes. *)
    check_eq_opt ~name:"family is explicit" ~expected:(Some "macro")
      ~actual:(jstr (member "family" j));
    (* bench-gen resolves nothing and knows no machine fingerprint, so it must
       not invent a run key: null until the server computes one (§8.1). *)
    check_true ~name:"run_key is null from bench-gen"
      (member "run_key" j = `Null);
    (* Self-contained: the config travels inline, so a spec can be archived,
       replayed or diffed without a shared filesystem. *)
    let cfg = member "config" j in
    check_eq_opt ~name:"config travels inline" ~expected:(Some spec.config_yaml)
      ~actual:(jstr (member "contents" cfg));
    check_eq_opt ~name:"config md5 matches its contents"
      ~expected:(Some (Digest.to_hex (Digest.string spec.config_yaml)))
      ~actual:(jstr (member "md5" cfg));
    (* The selection keeps both spellings: the resolved tag and what the user
       typed, so the ack can echo the user's own words.  (The AGENT derives
       RUNNING_TAG from this field: no env block travels in a spec.) *)
    (match member "tags" (member "selection" j) with
    | `List [ t ] ->
      check_eq_opt ~name:"selection resolves the tag"
        ~expected:(Some "small_run") ~actual:(jstr (member "name" t));
      check_eq_opt ~name:"selection keeps the user's spelling"
        ~expected:(Some "small") ~actual:(jstr (member "requested" t))
    | _ -> fail "runspec: expected exactly one selection tag");
    (* Both repos pinned to SHAS by the server before dispatch (§6.1) -- the
       macro-benches commit is part of run identity because a benchmark-source
       change does not invalidate a cached binary. *)
    (match member "sources" j with
    | `List [ a; b ] ->
      check_eq_opt ~name:"first source is running-ng"
        ~expected:(Some "running-ng") ~actual:(jstr (member "name" a));
      check_eq_opt ~name:"sources carry the clone URL"
        ~expected:(Some "https://github.com/udesou/running-ng")
        ~actual:(jstr (member "repo" a));
      check_eq_opt ~name:"running-ng is pinned to a sha" ~expected:(Some rng_sha)
        ~actual:(jstr (member "commit" a));
      check_eq_opt ~name:"macro-benches is pinned to a sha too"
        ~expected:(Some mb_sha) ~actual:(jstr (member "commit" b))
    | _ -> fail "runspec: expected exactly two sources");
    (* §6.1: the spec describes WHAT to measure; where things live on the
       machine, the env and the command line are the agent's, and must not
       appear at all. *)
    check_true ~name:"no machine-side blocks in the spec"
      (List.for_all
         (fun k -> member k j = `Null)
         [ "placement"; "env"; "command"; "limits"; "request" ]);
    (* Exactly one baseline, by construction (§5.3): it is the merge base, and
       every delta is relative to it. *)
    check_eq_opt ~name:"the baseline is the merge base"
      ~expected:(Some "ocaml-base-5.5.0")
      ~actual:(jstr (member "name" (member "baseline" j)));
    (match member "candidates" j with
    | `List [ c ] ->
      check_eq_opt ~name:"the PR head is the candidate"
        ~expected:(Some "ocaml-pr-1234-c0f8c8c") ~actual:(jstr (member "name" c))
    | _ -> fail "runspec: expected exactly one candidate");
    (* The repetition count is `invocations` everywhere (Q17). *)
    check_true ~name:"measurement says invocations"
      (jint (member "invocations" (member "measurement" j)) = Some 1);
    (* The timeout is execution-scoped (§6.2, the assignment), not spec
       content -- but its formula must exceed the estimate and respect the
       cold-build floor, or a slot gets freed while the run was still fine. *)
    let tmo = Runspec.timeout_seconds ~cost:spec.Gen.cost in
    check_true ~name:"timeout exceeds the estimate"
      (float_of_int tmo > spec.Gen.cost.Cost.seconds);
    check_true ~name:"timeout respects the 90m cold-build floor"
      (tmo >= 90 * 60);
    let dumped = Yojson.Safe.to_string j in
    (* The server never connects to a bench machine (Q1): no ssh coordinates
       may appear anywhere in a spec. *)
    check_true ~name:"no ssh anywhere in the spec"
      (not (contains ~needle:"ssh" dumped));
    (* Nothing resembling a credential may reach the bench machine. *)
    check_true ~name:"no token field anywhere in the spec"
      (not (contains ~needle:"token" dumped)
      && not (contains ~needle:"results_repo" dumped))

let test_run_key () =
  let base =
    {
      Run_key.runtimes =
        [
          { Run_key.name = "ocaml-base-5.5.0"; pin = "5.5.0"; configure_args = "" };
          {
            Run_key.name = "ocaml-pr-1234-c0f8c8c";
            pin = "c0f8c8ceef751fb3a99652d3d52399db3d1c2aae";
            configure_args = "";
          };
        ];
      family = Api.Macro;
      tags = [ "small_run"; "large_run" ];
      invocations = 3;
      sweeps = [ ("o", [ "80"; "120" ]) ];
      benches_commit = "1111111111111111111111111111111111111111";
      running_ng_xy = "v0.0.1";
      contract_version = "1.0";
      tool_versions = [ ("olly", "0.4.0"); ("perf", "6.5") ];
      machine = "monolith";
      env_fingerprint = "abcd1234";
    }
  in
  let k = Run_key.compute base in
  check_true ~name:"run key is prefixed and hex"
    (Util.starts_with ~prefix:"rk_" k && String.length k = 3 + 32);
  check_eq ~name:"run key is deterministic" ~expected:k
    ~actual:(Run_key.compute base);
  (* Order must not matter: the same measurement asked with the runtimes or
     tags listed differently is the same measurement. *)
  check_eq ~name:"runtime order does not change the key" ~expected:k
    ~actual:(Run_key.compute { base with runtimes = List.rev base.runtimes });
  check_eq ~name:"tag order does not change the key" ~expected:k
    ~actual:(Run_key.compute { base with tags = List.rev base.tags });
  (* Everything that could change the numbers must change the key. *)
  let differs name t =
    check_true ~name (Run_key.compute t <> k)
  in
  differs "invocations change the key" { base with invocations = 5 };
  differs "the benches commit changes the key"
    { base with benches_commit = "2222222222222222222222222222222222222222" };
  differs "the machine changes the key" { base with machine = "other" };
  differs "the environment fingerprint changes the key"
    { base with env_fingerprint = "ffff0000" };
  differs "an X.Y running-ng bump changes the key"
    { base with running_ng_xy = "v0.1.0" };
  (* ...but a Z-only running-ng release promises not to (§8.1): reuse holds. *)
  check_eq ~name:"a Z-only running-ng bump keeps the key" ~expected:k
    ~actual:(Run_key.compute { base with running_ng_xy = "v0.0.9" })

(* --- 5. the API A payloads (lib/api.ml) ----------------------------------- *)

let test_api_json () =
  (match Api.error Api.Over_budget "too big" with
  | Ok _ -> fail "Api.error should construct an Error"
  | Error e ->
    let j = Api.json_of_error e in
    check_eq_opt ~name:"error codes use the wire spelling"
      ~expected:(Some "over_budget") ~actual:(jstr (member "code" j));
    check_eq_opt ~name:"error carries postable markdown" ~expected:(Some "too big")
      ~actual:(jstr (member "error_markdown" j)));
  check_eq ~name:"states use the wire spelling" ~expected:"timed_out"
    ~actual:(Api.string_of_run_state Api.Timed_out);
  check_true ~name:"the internal code round-trips"
    (Api.error_code_of_string (Api.string_of_error_code Api.Internal)
    = Some Api.Internal);
  (* Internal errors: the detail goes to the log, the user gets a generic
     message carrying only the greppable incident id. *)
  (match Api.internal ~detail:"secret-traceback" "The service failed." with
  | Error e ->
    check_true ~name:"internal failures carry the Internal code"
      (e.Api.code = Api.Internal);
    check_contains ~name:"internal message names the incident id" ~needle:"i-"
      e.Api.error_markdown;
    check_true ~name:"the detail never reaches the user"
      (not (contains ~needle:"secret-traceback" e.Api.error_markdown))
  | Ok _ -> fail "Api.internal should construct an Error");
  let vocab =
    {
      Api.machines = [ "monolith" ];
      families = [ Api.Macro ];
      tags = [ "default"; "small" ];
      sweepable = [ { Api.param = "o"; dimension = "space_overhead"; unit_ = "pct" } ];
      max_invocations = 10;
    }
  in
  let j = Api.json_of_vocab vocab in
  check_true ~name:"vocab lists machines"
    (member "machines" j = `List [ `String "monolith" ]);
  check_true ~name:"vocab reserves only macro"
    (member "families" j = `List [ `String "macro" ]);
  check_true ~name:"vocab caps invocations"
    (jint (member "max_invocations" j) = Some 10);
  let outcome =
    Api.Duplicate
      { run_id = "run-1"; links = { Api.status = "s"; webview = "w" } }
  in
  let j = Api.json_of_submit_outcome outcome in
  check_eq_opt ~name:"outcomes are tagged" ~expected:(Some "duplicate")
    ~actual:(jstr (member "outcome" j))

(* --- 5b. the GitHub resolver (lib/resolver.ml) ----------------------------- *)

(* Exercised against a scratch git repository, not github.com: everything the
   resolver does is plain git (ls-remote, fetch, merge-base), so a local repo
   with a tag, a moving trunk and a refs/pull/N/head covers it offline. *)
let run_out cmd =
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 256 in
  (try
     while true do
       Buffer.add_channel buf ic 1
     done
   with End_of_file -> ());
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> String.trim (Buffer.contents buf)
  | _ -> failwith ("command failed: " ^ cmd)

let scratch_compiler_repo root =
  let repo = Filename.concat root "compiler" in
  let sh fmt =
    Printf.ksprintf
      (fun c ->
        if Sys.command (c ^ " >/dev/null 2>&1") <> 0 then failwith c)
      fmt
  in
  let git fmt =
    Printf.ksprintf
      (fun args ->
        sh "git -C %s -c user.email=t@t -c user.name=t %s"
          (Filename.quote repo) args)
      fmt
  in
  sh "mkdir -p %s" (Filename.quote repo);
  git "init -q -b trunk .";
  git "commit -q --allow-empty -m base";
  let rev r =
    run_out (Printf.sprintf "git -C %s rev-parse %s" (Filename.quote repo) r)
  in
  let base_sha = rev "HEAD" in
  git "tag -a 5.99.0 -m release";
  (* the PR: one commit on a branch off the base, advertised as a pull head *)
  git "checkout -q -b feature";
  git "commit -q --allow-empty -m change";
  let head_sha = rev "HEAD" in
  git "update-ref refs/pull/7/head refs/heads/feature";
  (* trunk moves on, so the merge base is neither branch tip *)
  git "checkout -q trunk";
  git "commit -q --allow-empty -m more";
  let trunk_sha = rev "trunk" in
  (repo, base_sha, head_sha, trunk_sha)

let test_github_resolver () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "bench-resolver-test-%d" (Unix.getpid ()))
  in
  let repo, base_sha, head_sha, trunk_sha = scratch_compiler_repo root in
  let resolver =
    Resolver.github
      {
        (Resolver.github_defaults ~cache_dir:(Filename.concat root "cache"))
        with
        compiler_repo = repo;
        url_of_repo = (fun _ -> repo);
      }
  in
  let cli = { Api.kind = Api.Cli; id = "cli" } in
  let short sha = String.sub sha 0 7 in
  (match resolver.Resolver.variants ~origin:cli ~vs:[ "5.99.0"; "trunk" ] with
  | Ok [ b; c ] ->
    check_true ~name:"a release tag pins its tagged commit"
      (b.Variant.spec = Variant.Commit base_sha
      && b.Variant.role = Variant.Baseline);
    check_eq ~name:"the runtime name carries meaning AND the sha"
      ~expected:("ocaml-5.99.0-" ^ short base_sha)
      ~actual:(Variant.runtime_name b);
    check_true ~name:"a branch resolves to its tip"
      (c.Variant.spec = Variant.Commit trunk_sha)
  | Ok _ -> fail "resolver: expected two variants"
  | Error e -> fail "resolver vs: %s" (markdown e));
  (match resolver.Resolver.variants ~origin:cli ~vs:[ "not-a-thing" ] with
  | Error e ->
    check_contains ~name:"an unknown ref is refused with the choices"
      ~needle:"neither a release tag" (markdown e)
  | Ok _ -> fail "unknown refs should be refused");
  let pr_origin ?head_sha ?base_ref () =
    {
      Api.kind =
        Api.Pr_comment
          {
            Api.repo = "any/thing";
            number = 7;
            url = "u";
            comment_id = "c1";
            comment_url = "cu";
            head_sha;
            base_ref;
          };
      id = "c1";
    }
  in
  (* A bare /bench on a PR: baseline = merge base, candidate = the PR head. *)
  (match resolver.Resolver.variants ~origin:(pr_origin ()) ~vs:[] with
  | Ok [ b; h ] ->
    check_true ~name:"the PR baseline is the merge base"
      (b.Variant.spec = Variant.Commit base_sha
      && b.Variant.role = Variant.Baseline);
    check_eq ~name:"the PR head is named pr-<n>-<sha>"
      ~expected:("ocaml-pr-7-" ^ short head_sha)
      ~actual:(Variant.runtime_name h);
    (* the head sha exists only on the PR's own repository *)
    check_true ~name:"the head pin carries the PR's repo"
      (h.Variant.repo = Some repo)
  | Ok _ -> fail "PR resolution: expected baseline + head"
  | Error e -> fail "PR resolution: %s" (markdown e));
  (* vs= on a PR overrides the baseline; the head stays a candidate. *)
  match resolver.Resolver.variants ~origin:(pr_origin ()) ~vs:[ "5.99.0" ] with
  | Ok (b :: h :: _) ->
    check_true ~name:"vs= chooses the PR baseline"
      (b.Variant.label = "5.99.0" && b.Variant.role = Variant.Baseline);
    check_true ~name:"the PR head stays the candidate"
      (h.Variant.spec = Variant.Commit head_sha
      && h.Variant.role = Variant.Candidate)
  | Ok _ -> fail "PR + vs=: expected at least two variants"
  | Error e -> fail "PR + vs=: %s" (markdown e)

(* --- 6. the request server (lib/server.ml) -------------------------------- *)

(* The server over injected deps: fixture facts, a fake tag filter, the
   offline resolver, and a throwaway state directory.  No bridge, no network,
   no machine -- exactly what the in-process design is for. *)
let test_server () =
  let state_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "bench-server-test-%d-%d" (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.) mod 100000))
  in
  let deps =
    {
      Server.service = service_config;
      facts;
      sweepable;
      base_include = "/base/macro_base.yml";
      program_count = (fun ~tags:_ -> Ok 20);
      resolver = Resolver.offline;
      sources =
        [
          Runspec.source ~name:"running-ng"
            ~repo:"https://github.com/udesou/running-ng"
            ~commit:"1111111111111111111111111111111111111111" ();
          Runspec.source ~name:"macro-benches"
            ~repo:"https://github.com/ocaml-bench/macro-benches"
            ~commit:"2222222222222222222222222222222222222222" ();
        ];
      state_dir;
      base_url = "http://bench.test";
      max_active_per_user = 2;
    }
  in
  let user = { Api.login = "udesou"; role = Api.User } in
  let watcher = { Api.login = "watcher"; role = Api.User } in
  (* Claims are not trusted: the server re-derives roles from its config, so
     this User claim comes back Admin, and the stranger's Admin claim buys
     nothing. *)
  let admin = { Api.login = "admin-person"; role = Api.User } in
  let stranger = { Api.login = "someone-else"; role = Api.Admin } in
  let submit ?(origin = "cli:udesou") auth cmd =
    Server.submit deps auth
      { Api.command = cmd; origin = { Api.kind = Api.Cli; id = origin } }
  in
  let vs = "vs=5.5.0,c0f8c8ceef751fb3a99652d3d52399db3d1c2aae" in

  (match submit stranger ("/bench " ^ vs) with
  | Error e ->
    check_true ~name:"unlisted login is forbidden, even claiming admin"
      (e.Api.code = Api.Forbidden)
  | Ok _ -> fail "a stranger's submit should be refused");

  (match submit user ("/bench tag=small invocations=1 " ^ vs) with
  | Error e -> fail "server submit: %s" (markdown e)
  | Ok (Api.Accepted a) ->
    check_true ~name:"accepted run ids are run-*"
      (Util.starts_with ~prefix:"run-" a.Api.run_id);
    check_contains ~name:"ack names the run" ~needle:a.Api.run_id
      a.Api.ack_markdown;
    check_true ~name:"resolved echoes the baseline"
      (a.Api.resolved.Api.baseline.Api.name = "ocaml-5.5.0");
    check_true ~name:"first run is queue position 1" (a.Api.queue_position = 1);
    let dir =
      Filename.concat (Filename.concat state_dir "runs") a.Api.run_id
    in
    check_true ~name:"the queue row is a directory of records"
      (List.for_all
         (fun f -> Sys.file_exists (Filename.concat dir f))
         [ "runspec.json"; "meta.json"; "request.json"; "config.yml" ]);
    (* The webview snapshot: rewritten on every state change, carrying the
       full meta records (pins included) the index renders. *)
    (let snap =
       Filename.concat (Filename.concat state_dir "webview") "runs.json"
     in
     match Yojson.Safe.from_string (Util.read_file snap) with
     | exception _ -> fail "webview/runs.json missing or unparseable"
     | j -> (
       match member "runs" j with
       | `List (m :: _) ->
         check_true ~name:"runs.json lists the new run"
           (jstr (member "run_id" m) = Some a.Api.run_id);
         check_eq_opt ~name:"runs.json carries the baseline pin"
           ~expected:(Some "ocaml-5.5.0")
           ~actual:(jstr (member "name" (member "baseline" m)))
       | _ -> fail "runs.json has no runs array"));
    (match Server.status deps user ~run_id:a.Api.run_id with
    | Ok st -> check_true ~name:"a fresh run is queued" (st.Api.state = Api.Queued)
    | Error e -> fail "status: %s" (markdown e));
    (* Idempotency: same origin id + same normalized command while active. *)
    (match submit user ("/bench  tag=small   invocations=1 " ^ vs) with
    | Ok (Api.Duplicate d) ->
      check_true ~name:"redelivery lands on the existing run"
        (d.run_id = a.Api.run_id)
    | _ -> fail "resubmission should be a Duplicate");
    (match Server.cancel deps watcher ~run_id:a.Api.run_id with
    | Error e ->
      check_true ~name:"non-owner cancel is forbidden"
        (e.Api.code = Api.Forbidden)
    | Ok () -> fail "watcher cancelled someone else's run");
    (match Server.cancel deps user ~run_id:a.Api.run_id with
    | Ok () -> (
      match Server.status deps user ~run_id:a.Api.run_id with
      | Ok st ->
        check_true ~name:"owner cancel lands" (st.Api.state = Api.Cancelled)
      | Error e -> fail "status after cancel: %s" (markdown e))
    | Error e -> fail "owner cancel: %s" (markdown e))
  | Ok _ -> fail "expected Accepted");

  (* The per-user active cap (Q10): two active runs, the third refused. *)
  (match
     ( submit ~origin:"cli:a" user ("/bench tag=small " ^ vs),
       submit ~origin:"cli:b" user ("/bench tag=large " ^ vs) )
   with
  | Ok (Api.Accepted _), Ok (Api.Accepted _) -> (
    match submit ~origin:"cli:c" user ("/bench tag=legacy " ^ vs) with
    | Error e ->
      check_true ~name:"third active run hits user_queue_full"
        (e.Api.code = Api.User_queue_full)
    | _ -> fail "third active run should be refused")
  | _ -> fail "two distinct runs should be accepted");

  (* Admin-only keys through the whole pipe. *)
  (match submit ~origin:"cli:e" user ("/bench force=true " ^ vs) with
  | Error e ->
    check_true ~name:"server refuses force for users"
      (e.Api.code = Api.Forbidden)
  | Ok _ -> fail "user force should be refused");
  (match submit ~origin:"cli:f" admin ("/bench force=true " ^ vs) with
  | Ok (Api.Accepted _) -> check_true ~name:"server allows force for admins" true
  | Error e -> fail "admin force: %s" (markdown e)
  | Ok _ -> fail "admin force should be Accepted");

  (* Offline resolution limits, stated rather than guessed. *)
  (match submit ~origin:"cli:g" admin "/bench vs=trunk" with
  | Error e ->
    check_contains ~name:"refs are refused offline" ~needle:"commit sha"
      (markdown e)
  | Ok _ -> fail "vs=trunk should be refused offline");
  let pr_origin =
    {
      Api.kind =
        Api.Pr_comment
          {
            Api.repo = "ocaml/ocaml";
            number = 1;
            url = "https://github.com/ocaml/ocaml/pull/1";
            comment_id = "c1";
            comment_url = "https://github.com/ocaml/ocaml/pull/1#c1";
            head_sha = None;
            base_ref = None;
          };
      id = "c1";
    }
  in
  (match
     Server.submit deps user { Api.command = "/bench " ^ vs; origin = pr_origin }
   with
  | Error e ->
    check_contains ~name:"PR submissions wait for the GitHub resolver"
      ~needle:"GitHub" (markdown e)
  | Ok _ -> fail "PR-origin submit should be refused offline");

  (* Machines: unknown, drained, admin-gated listing. *)
  (match submit ~origin:"cli:h" admin ("/bench machine=nope " ^ vs) with
  | Error e ->
    check_true ~name:"unknown machine has its own code"
      (e.Api.code = Api.Unknown_machine)
  | Ok _ -> fail "machine=nope should be refused");
  (match Server.machines deps user with
  | Error e ->
    check_true ~name:"machines listing is admin-only"
      (e.Api.code = Api.Forbidden)
  | Ok _ -> fail "user should not list machines");
  (match Server.drain deps admin ~machine:"monolith" with
  | Ok () -> (
    (match submit ~origin:"cli:i" admin ("/bench " ^ vs) with
    | Error e ->
      check_true ~name:"drained machine refuses new runs"
        (e.Api.code = Api.Machine_drained)
    | Ok _ -> fail "drained machine should refuse");
    match Server.undrain deps admin ~machine:"monolith" with
    | Ok () -> (
      match Server.machines deps admin with
      | Ok [ m ] ->
        check_true ~name:"undrain restores the machine" (not m.Api.drained)
      | _ -> fail "machines should list exactly monolith")
    | Error e -> fail "undrain: %s" (markdown e))
  | Error e -> fail "drain: %s" (markdown e));

  (* Non-run commands are Answered outcomes (Q18): the server acts, the
     requester posts the markdown. *)
  (match submit ~origin:"cli:j" user "/bench help" with
  | Ok (Api.Answered { markdown = md }) ->
    check_contains ~name:"submit answers /bench help with the reference"
      ~needle:"`/bench` usage" md
  | _ -> fail "/bench help should be Answered");
  (match submit ~origin:"cli:k" watcher ("/bench tag=small " ^ vs) with
  | Ok (Api.Accepted a) -> (
    match
      submit ~origin:"cli:l" watcher ("/bench cancel " ^ a.Api.run_id)
    with
    | Ok (Api.Answered { markdown = md }) -> (
      check_contains ~name:"submit performs /bench cancel" ~needle:"Cancelled"
        md;
      match Server.status deps watcher ~run_id:a.Api.run_id with
      | Ok st ->
        check_true ~name:"cancel through submit lands"
          (st.Api.state = Api.Cancelled)
      | Error e -> fail "status after comment-cancel: %s" (markdown e))
    | Ok _ -> fail "/bench cancel should be Answered"
    | Error e -> fail "comment-cancel: %s" (markdown e))
  | _ -> fail "watcher's run should be accepted");

  (* A bridge failure is the SERVICE's fault: Internal code, raw tool output
     kept out of the postable message. *)
  let d_fail =
    {
      deps with
      Server.program_count = (fun ~tags:_ -> Error "boom-traceback");
      state_dir = state_dir ^ "-fail";
    }
  in
  (match
     Server.submit d_fail admin
       { Api.command = "/bench tag=small " ^ vs;
         origin = { Api.kind = Api.Cli; id = "cli:z" } }
   with
  | Error e ->
    check_true ~name:"bridge failures are Internal" (e.Api.code = Api.Internal);
    check_true ~name:"tool output stays in the log"
      (not (contains ~needle:"boom-traceback" e.Api.error_markdown))
  | Ok _ -> fail "a failing bridge should refuse the submit");

  (* The index: newest first, filterable. *)
  match
    Server.list deps user
      { Api.no_filter with Api.requester = Some "udesou" }
      { Api.limit = 50; after = None }
  with
  | Ok metas ->
    check_true ~name:"list filters by requester"
      (metas <> []
      && List.for_all
           (fun (m : Api.meta) -> m.Api.requested_by = "udesou")
           metas)
  | Error e -> fail "list: %s" (markdown e)

let test_help () =
  let h =
    Help.render ~facts ~sweepable ~machines:[ "monolith" ] ~cap_seconds:7200.
      ~default_machine:"monolith"
  in
  (* Help is generated, so it must reflect the fixtures rather than prose. *)
  check_contains ~name:"help lists the default set size" ~needle:"| `default` | 20 |" h;
  check_contains ~name:"help lists all_benches size" ~needle:"| `all` | 92 |" h;
  check_contains ~name:"help lists the sweepable params" ~needle:"space_overhead" h;
  check_contains ~name:"help states the cap" ~needle:"2h00m" h;
  check_contains ~name:"help speaks in invocations" ~needle:"invocations=5" h;
  check_true ~name:"help never says iterations"
    (not (contains ~needle:"iterations" h));
  check_contains ~name:"help shows the tag union" ~needle:"tag=small,large" h;
  check_contains ~name:"help says cancel takes a run id" ~needle:"cancel <run-id>" h;
  check_contains ~name:"help marks the admin-only keys" ~needle:"admin-only" h;
  check_true ~name:"help does not advertise removed options"
    (not (contains ~needle:"tools=" h) && not (contains ~needle:"benches=" h))

let () =
  test_parsing ();
  test_golden ();
  test_shape_rules ();
  test_multi_tag ();
  test_modifier_chain ();
  test_baseline_direction ();
  test_canonical_dimension_spelling ();
  test_single_runtime ();
  test_gen_rejects ();
  test_variant_naming ();
  test_cost ();
  test_runspec ();
  test_run_key ();
  test_api_json ();
  test_authz ();
  test_admin_keys ();
  test_github_resolver ();
  test_server ();
  test_help ();
  ok "done";
  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1
