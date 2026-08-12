(* S0 acceptance tests.

   Three groups:

   1. Comment parsing -- a table of inputs to expected outcomes.  Rejections are
      asserted on the *user-facing message*, because that message is the product:
      it gets posted back to a PR verbatim.
   2. Generation -- request + fixture facts -> exact YAML, plus the rules that
      are easy to regress silently (comparison shape, sweep modifier
      definitions, the lavyek modifier chain, invocations via overrides).
   3. Authorisation and cost.

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

let base_v = { Variant.label = "base"; spec = Variant.Version "5.5.0"; role = Variant.Baseline }

let head_v =
  {
    Variant.label = "pr-1234";
    spec = Variant.Commit "c0f8c8ceef751fb3a99652d3d52399db3d1c2aae";
    role = Variant.Candidate;
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
    ("/bench", fun (r : Request.t) -> Request.iterations_or_default r = 3);
    ("/bench", fun r -> Request.resolved_tag r = "default_run");
    ("/bench tag=small", fun r -> Request.resolved_tag r = "small_run");
    ("/bench tag=all", fun r -> Request.resolved_tag r = "all_benches");
    ("/bench tag=legacy", fun r -> Request.resolved_tag r = "legacy");
    (* Unaliased names fall through, so feature tags stay reachable. *)
    ("/bench tag=bigarrays", fun r -> Request.resolved_tag r = "bigarrays");
    ("/bench iterations=5", fun r -> Request.iterations_or_default r = 5);
    ("/bench vs=trunk", fun r -> r.vs = [ "trunk" ]);
    ("/bench vs=5.4.1,trunk", fun r -> r.vs = [ "5.4.1"; "trunk" ]);
    ("/bench cancel", fun r -> r.action = Request.Cancel);
    ("/bench rerun", fun r -> r.action = Request.Rerun);
    ("/bench help", fun r -> r.action = Request.Help);
    ("/bench force=true", fun r -> r.force);
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
       Request.resolved_tag r = "small_run");
    (* Extra whitespace. *)
    ("/bench   iterations=2    tag=large", fun r ->
       Request.iterations_or_default r = 2 && Request.resolved_tag r = "large_run");
  ]

let parse_rejects =
  [
    ("/bench tags=small", "Did you mean `tag`?");
    ("/bench tag=", "empty value");
    ("/bench iterations=0", "at least 1");
    ("/bench iterations=99", "exceeds the limit of 10");
    ("/bench iterations=many", "not a positive whole number");
    ("/bench sweep=s", "missing a value list");
    ("/bench sweep=:1,2", "empty parameter name");
    ("/bench sweep=s:1 sweep=s:2", "more than once");
    ("/bench tag=small tag=large", "more than once");
    ("/bench force=maybe", "must be `true` or `false`");
    ("/bench tag=small,large", "takes a single name");
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
   is the artifact that ends up in the results repo, and a diff here should be a
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
# estimate:     1h00m (20 programs x 2 configs x 3 iterations = 120 runs)
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
  match gen "/bench iterations=1 sweep=o:80,120" with
  | Error e -> fail "sweep: %s" e
  | Ok spec ->
    check_contains ~name:"sweep defines the modifier"
      ~needle:"modifiers:\n  o:\n    type: OCamlRunParam\n    val: \"o={0}\""
      spec.config_yaml;
    check_contains ~name:"sweep emits config_sweep"
      ~needle:"config_sweep:\n  o: [80, 120]" spec.config_yaml;
    check_true ~name:"sweep multiplies the config count"
      (List.length spec.configs = 2 && spec.cost.configs = 4)

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
    ~actual:(Variant.runtime_name { head_v with label = "feat/x y" })

(* --- 3. cost and authorisation ------------------------------------------- *)

let test_cost () =
  (* The calibration point: 20 min per iteration for 2 runtimes over the 20
     default_run programs.  If this drifts, every estimate is wrong. *)
  let c = Cost.estimate ~programs:20 ~configs:2 ~iterations:1 () in
  check_eq ~name:"calibration: 1 iteration is 20m" ~expected:"20m"
    ~actual:(Cost.human c.seconds);
  let c3 = Cost.estimate ~programs:20 ~configs:2 ~iterations:3 () in
  check_eq ~name:"calibration: 3 iterations is 1h" ~expected:"1h00m"
    ~actual:(Cost.human c3.seconds);
  check_true ~name:"default request is inside the cap" (not (Cost.over_cap c3));
  (* all_benches at 3 iterations must be refused. *)
  (match gen ~program_count:92 "/bench tag=all" with
  | Ok _ -> fail "tag=all should exceed the cap"
  | Error e ->
    check_contains ~name:"cap refusal names the estimate" ~needle:"4h36m" e;
    check_contains ~name:"cap refusal says how to fix it" ~needle:"force=true" e);
  (* force=true overrides, and says so. *)
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
          "allow_associations":[],
          "machines":[{"name":"monolith","default":true,
                       "macro_bench_dir":"/mb","log_dir":"/logs"}] }|}
  with
  | Ok c -> c
  | Error e -> failwith ("service config fixture: " ^ e)

let test_authz () =
  let d = Authz.check service_config ~login:"udesou" ~association:None in
  check_true ~name:"allowlist is case-insensitive" (Authz.allowed d);
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
  check_true ~name:"help does not advertise removed options"
    (not (contains ~needle:"tools=" h) && not (contains ~needle:"benches=" h))

let () =
  test_parsing ();
  test_golden ();
  test_shape_rules ();
  test_modifier_chain ();
  test_baseline_direction ();
  test_canonical_dimension_spelling ();
  test_single_runtime ();
  test_gen_rejects ();
  test_variant_naming ();
  test_cost ();
  test_authz ();
  test_help ();
  ok "done";
  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1
