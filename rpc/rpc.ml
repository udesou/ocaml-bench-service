(* The Cap'n Proto adapter for API A (Q15).

   Nothing here decides anything: it binds the generated schema code
   (bench_api.capnp) to the server module on one side and offers typed client
   calls on the other.  The design rules it enforces:

   * **Identity is the capability.**  A [bench_api] service is constructed
     around one login; whoever holds its sturdy ref IS that login.  Roles are
     still re-derived from service.json per call (Server.effective_auth) --
     holding a capability never grants admin.
   * **The bot asserts, users cannot.**  Only the [bench_bot] service accepts
     a login parameter; it is issued once, to the PR bot, which verified the
     commenter via GitHub.
   * **CLI idempotency is server-named.**  A `Cli` origin's id is rewritten to
     "cli:<login>" here, so a client cannot dodge (or forge) the duplicate
     check: resubmitting the same command while it is active lands on the
     existing run.
   * **Errors travel as the API A envelope**, JSON-encoded in the capnp
     exception reason, so every client can show [error_markdown] and switch on
     [code]. *)

module Api_rpc = Bench_api.MakeRPC (Capnp_rpc)
open Bench_service

let fail_api (e : Api.error) =
  Capnp_rpc.Service.fail "%s" (Yojson.Safe.to_string (Api.json_of_error e))

let bad fmt = Printf.ksprintf (fun s -> { Api.code = Api.Bad_command; error_markdown = s }) fmt

(* A failure of the WIRE, not of the command: transport errors and cancelled
   calls come back as Internal so a requester (the bot, above all) can tell
   "post this refusal" from "log this and retry". *)
let transport fmt =
  Printf.ksprintf (fun s -> { Api.code = Api.Internal; error_markdown = s }) fmt

(* The envelope back out of a capnp error.  A reason that is not our JSON is
   a transport-level failure, and still surfaces as a postable message. *)
let error_of_rpc (`Capnp (e : Capnp_rpc.Error.t)) : Api.error =
  match e with
  | `Cancelled -> transport "The call was cancelled before the server answered."
  | `Exception ex -> (
    let reason = ex.Capnp_rpc.Exception.reason in
    match Yojson.Safe.from_string reason with
    | exception _ -> transport "Could not talk to the server: %s" reason
    | j -> (
      let mem k = function
        | `Assoc kvs -> (
          match List.assoc_opt k kvs with Some v -> v | None -> `Null)
        | _ -> `Null
      in
      match (mem "code" j, mem "error_markdown" j) with
      | `String c, `String m -> (
        match Api.error_code_of_string c with
        | Some code -> { Api.code; error_markdown = m }
        | None -> bad "%s" m)
      | _ -> transport "Could not talk to the server: %s" reason))

let origin_of_wire s =
  match Yojson.Safe.from_string s with
  | exception _ -> Error (bad "origin is not JSON")
  | j -> (
    match Api.origin_of_json j with
    | Ok o -> Ok o
    | Error m -> Error (bad "%s" m))

(* CLI origins are named by the server: the idempotency identity of a CLI
   submission is (the login, the command), never something the client chose. *)
let normalize_origin (auth : Api.auth) (o : Api.origin) =
  match o.Api.kind with
  | Api.Cli -> { o with Api.id = "cli:" ^ auth.Api.login }
  | Api.Pr_comment _ -> o

(* --- the services ----------------------------------------------------------- *)

let do_submit deps (auth : Api.auth) ~command ~origin_json =
  match origin_of_wire origin_json with
  | Error e -> Error e
  | Ok origin ->
    let origin = normalize_origin auth origin in
    Server.submit deps auth { Api.command; origin }

(* One user's view of the service: the capability is the identity. *)
let bench_api deps ~login =
  let module B = Api_rpc.Service.BenchApi in
  let auth = { Api.login; role = Api.User } (* role re-derived per call *) in
  let text_result init set v =
    let response, results = Capnp_rpc.Service.Response.create init in
    set results v;
    Capnp_rpc.Service.return response
  in
  let unit_result = function
    | Ok () -> Capnp_rpc.Service.return_empty ()
    | Error e -> fail_api e
  in
  B.local
  @@ object
       inherit B.service

       method submit_impl params release_param_caps =
         let open B.Submit in
         let command = Params.command_get params in
         let origin_json = Params.origin_json_get params in
         release_param_caps ();
         (match do_submit deps auth ~command ~origin_json with
         | Error e -> fail_api e
         | Ok outcome ->
           text_result Results.init_pointer Results.outcome_json_set
             (Yojson.Safe.to_string (Api.json_of_submit_outcome outcome)))

       method status_impl params release_param_caps =
         let open B.Status in
         let run_id = Params.run_id_get params in
         release_param_caps ();
         (match Server.status deps auth ~run_id with
         | Error e -> fail_api e
         | Ok st ->
           text_result Results.init_pointer Results.status_json_set
             (Yojson.Safe.to_string (Api.json_of_run_status st)))

       method events_impl params release_param_caps =
         let open B.Events in
         let run_id = Params.run_id_get params in
         let since = Int32.to_int (Params.since_get params) in
         release_param_caps ();
         (match Server.events deps auth ~run_id ~since with
         | Error e -> fail_api e
         | Ok events ->
           let j =
             `List
               (List.map
                  (fun (e : Api.event) ->
                    `Assoc
                      [
                        ("seq", `Int e.Api.seq);
                        ("ts", `String e.Api.ts);
                        ("run_id", `String e.Api.run_id);
                        ("execution", `Int e.Api.execution);
                        ("body", e.Api.body);
                      ])
                  events)
           in
           text_result Results.init_pointer Results.events_json_set
             (Yojson.Safe.to_string j))

       method cancel_impl params release_param_caps =
         let open B.Cancel in
         let run_id = Params.run_id_get params in
         release_param_caps ();
         unit_result (Server.cancel deps auth ~run_id)

       method list_impl params release_param_caps =
         let open B.List in
         let opt s = if s = "" then None else Some s in
         let filter =
           {
             Api.pr = opt (Params.pr_get params);
             requester = opt (Params.requester_get params);
             state =
               Option.bind (opt (Params.state_get params))
                 Api.run_state_of_string;
             machine = opt (Params.machine_get params);
             family =
               Option.bind (opt (Params.family_get params))
                 Api.family_of_string;
           }
         in
         let page =
           {
             Api.limit = Int32.to_int (Params.limit_get params);
             after = opt (Params.after_get params);
           }
         in
         release_param_caps ();
         (match Server.list deps auth filter page with
         | Error e -> fail_api e
         | Ok metas ->
           text_result Results.init_pointer Results.metas_json_set
             (Yojson.Safe.to_string
                (`List (List.map Api.json_of_meta metas))))

       method help_impl _params release_param_caps =
         let open B.Help in
         release_param_caps ();
         text_result Results.init_pointer Results.markdown_set
           (Server.help deps ())

       method vocab_impl _params release_param_caps =
         let open B.Vocab in
         release_param_caps ();
         text_result Results.init_pointer Results.vocab_json_set
           (Yojson.Safe.to_string (Api.json_of_vocab (Server.vocab deps ())))

       method machines_impl _params release_param_caps =
         let open B.Machines in
         release_param_caps ();
         (match Server.machines deps auth with
         | Error e -> fail_api e
         | Ok ms ->
           let j =
             `List
               (List.map
                  (fun (m : Api.machine_status) ->
                    `Assoc
                      [
                        ("machine", `String m.Api.machine);
                        ("drained", `Bool m.Api.drained);
                        ( "busy_with",
                          match m.Api.busy_with with
                          | None -> `Null
                          | Some r -> `String r );
                      ])
                  ms)
           in
           text_result Results.init_pointer Results.machines_json_set
             (Yojson.Safe.to_string j))

       method drain_impl params release_param_caps =
         let open B.Drain in
         let machine = Params.machine_get params in
         release_param_caps ();
         unit_result (Server.drain deps auth ~machine)

       method undrain_impl params release_param_caps =
         let open B.Undrain in
         let machine = Params.machine_get params in
         release_param_caps ();
         unit_result (Server.undrain deps auth ~machine)

       method requeue_impl params release_param_caps =
         let open B.Requeue in
         let run_id = Params.run_id_get params in
         release_param_caps ();
         unit_result (Server.requeue deps auth ~run_id)

       method evict_impl params release_param_caps =
         let open B.Evict in
         let machine = Params.machine_get params in
         let selector =
           match Params.runtime_name_get params with
           | "" -> Api.All_caches
           | name -> Api.Runtime_cache name
         in
         release_param_caps ();
         (match Server.evict deps auth ~machine selector with
         | Error e -> fail_api e
         | Ok bytes ->
           let response, results =
             Capnp_rpc.Service.Response.create Results.init_pointer
           in
           Results.bytes_set results bytes;
           Capnp_rpc.Service.return response)
     end

(* The bot's capability: submit as the commenter it verified. *)
let bench_bot deps =
  let module B = Api_rpc.Service.BenchBot in
  B.local
  @@ object
       inherit B.service

       method submit_as_impl params release_param_caps =
         let open B.SubmitAs in
         let login = Params.login_get params in
         let command = Params.command_get params in
         let origin_json = Params.origin_json_get params in
         release_param_caps ();
         let auth = { Api.login; role = Api.User } in
         (match do_submit deps auth ~command ~origin_json with
         | Error e -> fail_api e
         | Ok outcome ->
           let response, results =
             Capnp_rpc.Service.Response.create Results.init_pointer
           in
           Results.outcome_json_set results
             (Yojson.Safe.to_string (Api.json_of_submit_outcome outcome));
           Capnp_rpc.Service.return response)
     end

(* --- typed client calls ------------------------------------------------------ *)

module Client = struct
  module B = Api_rpc.Client.BenchApi

  type t = B.t Capnp_rpc.Capability.t

  let call cap method_id request read =
    match Capnp_rpc.Capability.call_for_value cap method_id request with
    | Ok results -> Ok (read results)
    | Error e -> Error (error_of_rpc e)

  let json s =
    match Yojson.Safe.from_string s with
    | j -> j
    | exception _ -> `String s

  let submit t ~command ~origin =
    let open B.Submit in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    Params.command_set params command;
    Params.origin_json_set params
      (Yojson.Safe.to_string (Api.json_of_origin origin));
    call t method_id request (fun r -> json (Results.outcome_json_get r))

  let status t ~run_id =
    let open B.Status in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    Params.run_id_set params run_id;
    call t method_id request (fun r -> json (Results.status_json_get r))

  let events t ~run_id ~since =
    let open B.Events in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    Params.run_id_set params run_id;
    Params.since_set params (Int32.of_int since);
    call t method_id request (fun r -> json (Results.events_json_get r))

  let cancel t ~run_id =
    let open B.Cancel in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    Params.run_id_set params run_id;
    call t method_id request (fun _ -> ())

  let list t ?requester ?state ?machine ?pr ?family ?(limit = 25) ?after () =
    let open B.List in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    let set f v = f params (Option.value v ~default:"") in
    set Params.requester_set requester;
    set Params.state_set state;
    set Params.machine_set machine;
    set Params.pr_set pr;
    set Params.family_set family;
    set Params.after_set after;
    Params.limit_set params (Int32.of_int limit);
    call t method_id request (fun r -> json (Results.metas_json_get r))

  let help t =
    let open B.Help in
    let request, _ = Capnp_rpc.Capability.Request.create Params.init_pointer in
    call t method_id request Results.markdown_get

  let vocab t =
    let open B.Vocab in
    let request, _ = Capnp_rpc.Capability.Request.create Params.init_pointer in
    call t method_id request (fun r -> json (Results.vocab_json_get r))

  let machines t =
    let open B.Machines in
    let request, _ = Capnp_rpc.Capability.Request.create Params.init_pointer in
    call t method_id request (fun r -> json (Results.machines_json_get r))

  let drain t ~machine =
    let open B.Drain in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    Params.machine_set params machine;
    call t method_id request (fun _ -> ())

  let undrain t ~machine =
    let open B.Undrain in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    Params.machine_set params machine;
    call t method_id request (fun _ -> ())

  let requeue t ~run_id =
    let open B.Requeue in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    Params.run_id_set params run_id;
    call t method_id request (fun _ -> ())

  let evict t ~machine ~runtime_name =
    let open B.Evict in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    Params.machine_set params machine;
    Params.runtime_name_set params (Option.value runtime_name ~default:"");
    call t method_id request Results.bytes_get
end

module Bot_client = struct
  module B = Api_rpc.Client.BenchBot

  type t = B.t Capnp_rpc.Capability.t

  let submit_as t ~login ~command ~origin =
    let open B.SubmitAs in
    let request, params =
      Capnp_rpc.Capability.Request.create Params.init_pointer
    in
    Params.login_set params login;
    Params.command_set params command;
    Params.origin_json_set params
      (Yojson.Safe.to_string (Api.json_of_origin origin));
    match Capnp_rpc.Capability.call_for_value t method_id request with
    | Ok r -> Ok (Client.json (Results.outcome_json_get r))
    | Error e -> Error (error_of_rpc e)
end
