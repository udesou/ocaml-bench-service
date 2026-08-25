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
    configure_args = "";
  }

let head_v =
  {
    Variant.label = "pr-1234";
    spec = Variant.Commit "c0f8c8ceef751fb3a99652d3d52399db3d1c2aae";
    role = Variant.Candidate;
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

let gen ?program_count ?cap_seconds ?(variants = [ base_v; head_v ]) comment =
  match Request.parse comment with
  | Error e -> Error e
  | Ok request ->
    Gen.generate ~ctx:(ctx ?program_count ?cap_seconds ()) ~request ~facts
      ~sweepable ~variants

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
  | Error e -> fail "golden: generation failed: %s" e
  | Ok spec ->
    check_eq ~name:"golden default config" ~expected:golden_default
      ~actual:spec.config_yaml

let test_shape_rules () =
  (match gen "/bench" with
  | Error e -> fail "shape: %s" e
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
  | Error e -> fail "sweep: %s" e
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
  | Error e -> fail "multi-tag: %s" e
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
  | Error e -> Error e
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
  | Error e -> fail "pre-#15 chain: %s" e
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
  | Error e -> fail "lavyek chain: %s" e
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
  | Error e -> fail "baseline direction: %s" e
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
  | Error e -> fail "baseline direction (swapped): %s" e
  | Ok spec ->
    check_contains ~name:"role swap moves a:"
      ~needle:"    a: ocaml-pr-1234-c0f8c8c" spec.config_yaml;
    check_contains ~name:"role swap moves b:" ~needle:"    b: [ocaml-base-5.5.0]"
      spec.config_yaml

let test_single_runtime () =
  match gen ~variants:[ head_v ] "/bench" with
  | Error e -> fail "single runtime: %s" e
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
        check_contains ~name:(Printf.sprintf "gen reject %S" comment) ~needle e)
    gen_rejects;
  (* Duplicate runtime names would silently share one opam switch. *)
  match gen ~variants:[ base_v; { base_v with role = Variant.Candidate } ] "/bench" with
  | Ok _ -> fail "duplicate runtime names should have been rejected"
  | Error e -> check_contains ~name:"duplicate runtimes" ~needle:"same name" e

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
      ~expected:"--enable-frame-pointers" ~actual:v.configure_args
  | Error e -> fail "configure args variant rejected: %s" e);
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
    check_contains ~name:"cap refusal names the estimate" ~needle:"4h36m" e;
    check_contains ~name:"cap refusal says what to shrink" ~needle:"invocations=" e;
    check_contains ~name:"cap refusal says force is admin-only" ~needle:"admin" e);
  (* force=true overrides, and says so.  (Whether the ASKER may say force= is
     Authz's decision, tested below; generation only honours it.) *)
  match gen ~program_count:92 "/bench tag=all force=true" with
  | Error e -> fail "force=true should be accepted: %s" e
  | Ok spec ->
    check_true ~name:"forced run warns"
      (List.exists (contains ~needle:"force=true") spec.warnings)

let service_config =
  match
    Service_config.of_string
      {|{ "bot": {"account":"bot-acct","token_env":"TOK"},
          "results_repo":"u/r",
          "allowlist":["Udesou"],
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
  | Error e -> fail "runspec: generation failed: %s" e
  | Ok spec ->
    let sources =
      [
        Runspec.source ~name:"running-ng" ~dir:"/rng"
          ~git_ref:"origin/adding-ocaml-support" ();
        Runspec.source ~name:"macro-benches" ~dir:"/mb" ~git_ref:"origin/master"
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
        ~slot:"monolith:default-opamroot"
    in
    check_eq_opt ~name:"runspec is versioned" ~expected:(Some "2")
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
    (* RUNNING_TAG is why a run spec cannot be just a YAML file. *)
    check_eq_opt ~name:"env carries RUNNING_TAG" ~expected:(Some "small_run")
      ~actual:(jstr (member "RUNNING_TAG" (member "env" j)));
    (* The selection keeps both spellings: the resolved tag and what the user
       typed, so the ack can echo the user's own words. *)
    (match member "tags" (member "selection" j) with
    | `List [ t ] ->
      check_eq_opt ~name:"selection resolves the tag"
        ~expected:(Some "small_run") ~actual:(jstr (member "name" t));
      check_eq_opt ~name:"selection keeps the user's spelling"
        ~expected:(Some "small") ~actual:(jstr (member "requested" t))
    | _ -> fail "runspec: expected exactly one selection tag");
    check_eq_opt ~name:"env carries switch reuse" ~expected:(Some "1")
      ~actual:(jstr (member "RUNNING_REUSE_SWITCHES" (member "env" j)));
    (* Both repos pinned by ref, commit left for the agent to fill in -- the
       macro-benches commit is part of run identity because a benchmark-source
       change does not invalidate a cached binary. *)
    (match member "sources" j with
    | `List [ a; b ] ->
      check_eq_opt ~name:"first source is running-ng (also the cwd)"
        ~expected:(Some "running-ng") ~actual:(jstr (member "name" a));
      check_eq_opt ~name:"macro-benches is pinned too"
        ~expected:(Some "macro-benches") ~actual:(jstr (member "name" b));
      check_true ~name:"commits are the agent's to fill in"
        (member "commit" a = `Null && member "commit" b = `Null);
      check_eq_opt ~name:"cwd is the running-ng checkout" ~expected:(Some "/rng")
        ~actual:(jstr (member "cwd" (member "command" j)))
    | _ -> fail "runspec: expected exactly two sources");
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
    (* The timeout must exceed the estimate and respect the cold-build floor,
       or a slot gets freed while the run was still fine. *)
    let limits = member "limits" j in
    let est = Option.value (jint (member "estimated_seconds" limits)) ~default:0
    and tmo = Option.value (jint (member "timeout_seconds" limits)) ~default:0 in
    check_true ~name:"timeout exceeds the estimate" (tmo > est);
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
  test_help ();
  ok "done";
  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1
