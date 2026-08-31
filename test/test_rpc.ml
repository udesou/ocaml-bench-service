(* Round trips for the Cap'n Proto adapter (rpc/).

   Local capabilities, no network: a call on an in-process capability goes
   through the same generated schema code, JSON payload encoding and error
   envelope that the wire uses, so this covers everything except sockets and
   TLS -- which are capnp-rpc's to test, not ours.

   What must hold:

   * the identity is the capability: a service bound to an unlisted login is
     Forbidden, whatever the client claims;
   * a CLI origin's idempotency id is server-named, so two submissions of the
     same command dedupe even when the client picks different origin ids;
   * the error envelope survives the wire: code AND markdown;
   * the bot capability asserts the commenter, who must still be allowlisted;
   * a PR submission through the bot resolves baseline = merge base and
     candidate = PR head (github resolver over a scratch repo). *)

open Bench_service
open Bench_rpc

let failures = ref 0
let checks = ref 0

let fail fmt =
  Printf.ksprintf
    (fun s ->
      incr failures;
      print_string ("FAIL  " ^ s ^ "\n"))
    fmt

let check_true ~name cond = incr checks; if not cond then fail "%s" name

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let check_contains ~name ~needle actual =
  incr checks;
  if not (contains ~needle actual) then
    fail "%s\n      expected to contain: %S\n      actual: %S" name needle actual

let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let jstr = function `String s -> Some s | _ -> None

(* --- fixtures (the same ones the main suite uses) -------------------------- *)

let facts =
  match Facts.of_file "fixtures/facts_macro_base.json" with
  | Ok f -> f
  | Error e -> failwith ("fixture facts: " ^ e)

let sweepable =
  match Vocab.of_file "fixtures/vocab.json" with
  | Ok d -> d
  | Error e -> failwith ("fixture vocab: " ^ e)

let service_config =
  match
    Service_config.of_string
      {|{ "bot": {"account":"bot-acct","token_env":"TOK"},
          "results_repo":"u/r",
          "allowlist":["udesou"],
          "admins":[],
          "machines":[{"name":"monolith","default":true}] }|}
  with
  | Ok c -> c
  | Error e -> failwith ("service config fixture: " ^ e)

let fresh_state =
  let n = ref 0 in
  fun () ->
    incr n;
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "bench-rpc-test-%d-%d" (Unix.getpid ()) !n)

let deps ?(resolver = Resolver.offline) () =
  {
    Server.service = service_config;
    facts;
    sweepable;
    base_include = "/base/macro_base.yml";
    program_count = (fun ~tags:_ -> Ok 20);
    resolver;
    sources =
      [
        Runspec.source ~name:"running-ng"
          ~repo:"https://github.com/udesou/running-ng"
          ~commit:"1111111111111111111111111111111111111111" ();
        Runspec.source ~name:"macro-benches"
          ~repo:"https://github.com/ocaml-bench/macro-benches"
          ~commit:"2222222222222222222222222222222222222222" ();
      ];
    pin_config = [];
    service_version = "test";
    validate_pin = (fun _ ~commit:_ -> Ok ());
    on_bump = ignore;
    state_dir = fresh_state ();
    base_url = "http://bench.test";
    max_active_per_user = 4;
  }

let sha = "c0f8c8ceef751fb3a99652d3d52399db3d1c2aae"
let cli_origin id = { Api.kind = Api.Cli; id }

(* scratch compiler repo for the PR path, same shape as the resolver test *)
let scratch_repo root =
  let repo = Filename.concat root "compiler" in
  let sh fmt =
    Printf.ksprintf
      (fun c -> if Sys.command (c ^ " >/dev/null 2>&1") <> 0 then failwith c)
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
  git "checkout -q -b feature";
  git "commit -q --allow-empty -m change";
  git "update-ref refs/pull/9/head refs/heads/feature";
  git "checkout -q trunk";
  git "commit -q --allow-empty -m more";
  repo

let () =
  Eio_main.run @@ fun _env ->
  (* --- the user path ------------------------------------------------------ *)
  let d = deps () in
  let api = Rpc.bench_api d ~login:"udesou" in

  (match Rpc.Client.help api with
  | Ok md ->
    check_contains ~name:"help travels the wire" ~needle:"`/bench` usage" md
  | Error e -> fail "help: %s" e.Api.error_markdown);

  (match Rpc.Client.vocab api with
  | Ok j ->
    check_true ~name:"vocab travels as JSON"
      (member "machines" j = `List [ `String "monolith" ])
  | Error e -> fail "vocab: %s" e.Api.error_markdown);

  (match
     Rpc.Client.submit api ~command:"/bench help" ~origin:(cli_origin "x")
   with
  | Ok j ->
    check_true ~name:"/bench help is an answered outcome"
      (jstr (member "outcome" j) = Some "answered")
  | Error e -> fail "submit help: %s" e.Api.error_markdown);

  let command = "/bench tag=small invocations=1 vs=5.5.0," ^ sha in
  let run_id =
    match Rpc.Client.submit api ~command ~origin:(cli_origin "one") with
    | Ok j when jstr (member "outcome" j) = Some "accepted" -> (
      check_contains ~name:"the ack rides along"
        ~needle:"queued"
        (Option.value (jstr (member "ack_markdown" j)) ~default:"");
      match jstr (member "run_id" j) with
      | Some id -> id
      | None -> failwith "accepted without run_id")
    | Ok j -> failwith ("expected accepted, got " ^ Yojson.Safe.to_string j)
    | Error e -> failwith ("submit: " ^ e.Api.error_markdown)
  in

  (* The server names CLI idempotency ids: a different client-chosen origin id
     must still land on the existing run. *)
  (match
     Rpc.Client.submit api ~command ~origin:(cli_origin "totally-different")
   with
  | Ok j ->
    check_true ~name:"CLI dedupe ignores client-chosen origin ids"
      (jstr (member "outcome" j) = Some "duplicate"
      && jstr (member "run_id" j) = Some run_id)
  | Error e -> fail "resubmit: %s" e.Api.error_markdown);

  (match Rpc.Client.status api ~run_id with
  | Ok j ->
    check_true ~name:"status travels the wire"
      (jstr (member "state" j) = Some "queued")
  | Error e -> fail "status: %s" e.Api.error_markdown);

  (match Rpc.Client.cancel api ~run_id with
  | Ok () -> (
    match Rpc.Client.status api ~run_id with
    | Ok j ->
      check_true ~name:"cancel lands"
        (jstr (member "state" j) = Some "cancelled")
    | Error e -> fail "status after cancel: %s" e.Api.error_markdown)
  | Error e -> fail "cancel: %s" e.Api.error_markdown);

  (* --- the envelope and the roles ----------------------------------------- *)
  (match Rpc.Client.machines api with
  | Error e ->
    check_true ~name:"the error code survives the wire"
      (e.Api.code = Api.Forbidden)
  | Ok _ -> fail "a user listing machines should be Forbidden");

  let nobody = Rpc.bench_api d ~login:"nobody" in
  (match Rpc.Client.submit nobody ~command ~origin:(cli_origin "x") with
  | Error e ->
    check_true ~name:"an unlisted login's capability is Forbidden"
      (e.Api.code = Api.Forbidden);
    check_contains ~name:"...with the postable explanation"
      ~needle:"allowlist" e.Api.error_markdown
  | Ok _ -> fail "an unlisted login should be refused");

  (* --- the bot path over a real (scratch) repo ----------------------------- *)
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "bench-rpc-bot-%d" (Unix.getpid ()))
  in
  let repo = scratch_repo root in
  let d_bot =
    deps
      ~resolver:
        (Resolver.github
           {
             (Resolver.github_defaults
                ~cache_dir:(Filename.concat root "cache"))
             with
             compiler_repo = repo;
             url_of_repo = (fun _ -> repo);
           })
      ()
  in
  let bot = Rpc.bench_bot d_bot in
  let pr_origin =
    {
      Api.kind =
        Api.Pr_comment
          {
            Api.repo = "any/thing";
            number = 9;
            url = "https://example/pr/9";
            comment_id = "c-9";
            comment_url = "https://example/pr/9#c-9";
            head_sha = None;
            base_ref = None;
          };
      id = "c-9";
    }
  in
  (match
     Rpc.Bot_client.submit_as bot ~login:"udesou"
       ~command:"/bench tag=small invocations=1" ~origin:pr_origin
   with
  | Ok j ->
    check_true ~name:"a PR comment becomes an accepted run"
      (jstr (member "outcome" j) = Some "accepted");
    let resolved = member "resolved" j in
    let name_of x = Option.value (jstr (member "name" x)) ~default:"" in
    check_contains ~name:"the baseline is the merge base"
      ~needle:"ocaml-base-"
      (name_of (member "baseline" resolved));
    (match member "candidates" resolved with
    | `List [ c ] ->
      check_contains ~name:"the candidate is the PR head" ~needle:"ocaml-pr-9-"
        (name_of c)
    | _ -> fail "expected exactly one candidate")
  | Error e -> fail "bot submit: %s" e.Api.error_markdown);

  (match
     Rpc.Bot_client.submit_as bot ~login:"stranger"
       ~command:"/bench tag=small invocations=1" ~origin:pr_origin
   with
  | Error e ->
    check_true ~name:"the bot cannot elevate an unlisted commenter"
      (e.Api.code = Api.Forbidden)
  | Ok _ -> fail "an unlisted commenter should be refused");

  (* --- the agent path (API B) ---------------------------------------------- *)
  (* A fresh queue, one submitted run, and the whole execution protocol over
     the adapter: the same generated code and JSON payloads the wire uses. *)
  let d_agent = deps () in
  let api2 = Rpc.bench_api d_agent ~login:"udesou" in
  let agent = Rpc.agent_api d_agent ~machine:"monolith" in
  let foreign = Rpc.agent_api d_agent ~machine:"not-registered" in
  let run_id =
    match Rpc.Client.submit api2 ~command ~origin:(cli_origin "a") with
    | Ok j when jstr (member "outcome" j) = Some "accepted" ->
      Option.value (jstr (member "run_id" j)) ~default:""
    | _ -> failwith "agent-path submit"
  in
  (match Rpc.Agent_client.claim foreign with
  | Error e ->
    check_true ~name:"an unregistered machine's capability is refused"
      (e.Api.code = Api.Unknown_machine)
  | Ok _ -> fail "a foreign agent capability claimed work");
  (match Rpc.Agent_client.claim agent with
  | Ok (Some a) ->
    check_true ~name:"the assignment travels the wire"
      (a.Api.id = { Api.run_id; execution = 1 }
      && a.Api.caches = `Reuse
      && a.Api.timeout_seconds >= 90 * 60
      && jstr (member "run_id" a.Api.spec) = Some run_id);
    let id = a.Api.id in
    check_true ~name:"heartbeat over the wire Continues"
      (Rpc.Agent_client.heartbeat agent ~id ~phase:Api.Measuring
      = Ok `Continue);
    (match
       Rpc.Agent_client.post_events agent ~id
         [
           {
             Api.seq = 1;
             ts = "2026-08-27T00:00:00Z";
             run_id = "ignored";
             execution = 9;
             body = `Assoc [ ("type", `String "phase") ];
           };
         ]
     with
    | Ok () -> (
      match Rpc.Client.events api2 ~run_id ~since:0 with
      | Ok (`List [ e ]) ->
        check_true ~name:"events ride the wire under the authenticated id"
          (jstr (member "run_id" e) = Some run_id
          && member "execution" e = `Int 1)
      | _ -> fail "expected one event back")
    | Error e -> fail "post_events: %s" e.Api.error_markdown);
    (match
       Rpc.Agent_client.upload agent ~id
         { Api.path = "raw/notes.md"; content = "# hi\n" }
     with
    | Ok () -> ()
    | Error e -> fail "upload: %s" e.Api.error_markdown);
    (match
       Rpc.Agent_client.upload agent ~id
         { Api.path = "meta.json"; content = "{}" }
     with
    | Error e ->
      check_true ~name:"server-owned refusal survives the wire"
        (e.Api.code = Api.Forbidden)
    | Ok () -> fail "meta.json overwritten over the wire");
    (match
       Rpc.Agent_client.finish agent ~id
         {
           Api.outcome = `Done;
           cells_passed = 3;
           cells_failed = 0;
           detail = None;
         }
     with
    | Ok () -> (
      match Rpc.Client.status api2 ~run_id with
      | Ok j ->
        check_true ~name:"finish lands as done over the wire"
          (jstr (member "state" j) = Some "done")
      | Error e -> fail "status after finish: %s" e.Api.error_markdown)
    | Error e -> fail "finish: %s" e.Api.error_markdown)
  | Ok None -> fail "agent claim found no work"
  | Error e -> fail "agent claim: %s" e.Api.error_markdown);
  (match
     Rpc.Agent_client.report_caches agent
       [
         Api.Binaries
           {
             runtime_name = "ocaml-5.5.0";
             benches_commit = "2222222222222222222222222222222222222222";
             switch_build_id = "b-1";
             size_bytes = 42L;
             last_used = "2026-08-27T00:00:00Z";
           };
       ]
   with
  | Ok () ->
    check_true ~name:"cache reports round-trip the wire"
      (match Server.reported_caches d_agent "monolith" with
      | Some (_, [ Api.Binaries b ]) ->
        b.switch_build_id = "b-1" && b.size_bytes = 42L
      | _ -> false)
  | Error e -> fail "report_caches: %s" e.Api.error_markdown);

  Capnp_rpc.Capability.dec_ref api;
  Capnp_rpc.Capability.dec_ref nobody;
  Capnp_rpc.Capability.dec_ref bot;
  Capnp_rpc.Capability.dec_ref api2;
  Capnp_rpc.Capability.dec_ref agent;
  Capnp_rpc.Capability.dec_ref foreign;
  Printf.printf "\n%d checks, %d failures\n" !checks !failures;
  if !failures > 0 then exit 1
