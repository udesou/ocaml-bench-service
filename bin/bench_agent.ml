(* bench-agent -- the bench machine daemon (API B, §6.2).

   Dials the server (the agent pulls, §6.4: the machine needs no inbound
   access at all) with an agent capability, claims work, executes it, ships
   events and artifacts back, and reports its caches.  The capability file IS
   the machine's identity: whoever holds agent-<machine>.cap is that
   machine's agent.

   STAGE 1: the executor is a STUB.  It exercises the whole §6.2 surface --
   claim, heartbeat (including obeying a cancel order), post_events, upload,
   finish, report_caches -- but runs no benchmark: it sleeps where running-ng
   would run and uploads a marker report saying so.  The real executor
   (checkouts, provisioning, running-ng under setsid, collection per the
   spec's globs) replaces one function, [execute].

   The process exits on a broken connection rather than reconnecting: a
   supervisor loop (screen/systemd) restarting it is simpler and more honest
   than half-reconnected state. *)

open Bench_service
open Bench_rpc

type opts = {
  cap : string option;
  interval : float;  (* seconds between empty claims *)
  stub_seconds : float;  (* how long the fake measurement takes *)
  once : bool;  (* execute one assignment, then exit (smoke tests) *)
}

let default_opts () =
  {
    cap = Sys.getenv_opt "BENCH_AGENT_CAP";
    interval = 5.0;
    stub_seconds = 1.0;
    once = false;
  }

let die fmt = Printf.ksprintf (fun s -> prerr_endline s; exit 2) fmt
let log fmt = Printf.ksprintf (fun s -> Printf.printf "bench-agent: %s\n%!" s) fmt

let usage () =
  print_string
    {|bench-agent -- the bench machine daemon (STAGE 1: stub executor)

  bench-agent --cap agent-<machine>.cap [--interval 5] [--once]

Claims queued runs for its machine from the server and executes them.  In
this build the executor is a stub: it walks the whole execution protocol
(events, heartbeats, artifacts, finish) but runs no benchmark.

Options:
  --cap FILE        the agent capability (or $BENCH_AGENT_CAP);
                    written by bench-serve as <state>/caps/agent-<machine>.cap
  --interval SEC    poll interval while the queue is empty (default 5)
  --stub-seconds S  how long the fake measurement sleeps (default 1)
  --once            process one assignment, then exit
|};
  exit 0

let parse_args argv =
  let o = ref (default_opts ()) in
  let rec go = function
    | [] -> ()
    | flag :: rest ->
      let need () =
        match rest with v :: tl -> (v, tl) | [] -> die "%s needs a value" flag
      in
      let set f = let v, tl = need () in o := f v; go tl in
      (match flag with
      | "--cap" -> set (fun v -> { !o with cap = Some v })
      | "--interval" -> set (fun v -> { !o with interval = float_of_string v })
      | "--stub-seconds" ->
        set (fun v -> { !o with stub_seconds = float_of_string v })
      | "--once" -> o := { !o with once = true }; go rest
      | "-h" | "--help" -> usage ()
      | other -> die "unknown flag %s (try --help)" other)
  in
  go argv;
  !o

let iso_now () =
  let t = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (t.Unix.tm_year + 1900)
    (t.Unix.tm_mon + 1) t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min
    t.Unix.tm_sec

(* --- the stub executor ------------------------------------------------------ *)

(* §7 event bodies, PROVISIONAL JSON spelling (API E is not agreed yet). *)
let phase_body phase detail =
  `Assoc
    [
      ("type", `String "phase");
      ("phase", `String (Api.string_of_execution_phase phase));
      ("detail", match detail with None -> `Null | Some d -> `String d);
    ]

let finished_body (r : Api.execution_result) =
  `Assoc
    [
      ("type", `String "execution_finished");
      ("result", `String (Api.string_of_execution_outcome r.Api.outcome));
      ("cells_passed", `Int r.Api.cells_passed);
      ("cells_failed", `Int r.Api.cells_failed);
    ]

(* JSON helpers for reading the spec (the agent trusts the spec's shape: the
   server resolved and validated everything before dispatch) *)
let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let jint = function `Int i -> i | _ -> 0

let execute cap ~clock ~stub_seconds (a : Api.assignment) =
  let id = a.Api.id in
  let seq = ref 0 in
  let event body =
    incr seq;
    {
      Api.seq = !seq;
      ts = iso_now ();
      run_id = id.Api.run_id;
      execution = id.Api.execution;
      body;
    }
  in
  let post bodies =
    match Rpc.Agent_client.post_events cap ~id (List.map event bodies) with
    | Ok () -> ()
    | Error e -> log "post_events failed: %s" e.Api.error_markdown
  in
  let finish result =
    post [ finished_body result ];
    match Rpc.Agent_client.finish cap ~id result with
    | Ok () ->
      (* the server's Ok IS the store confirmation (§6.5): a real executor
         deletes its local run directory here *)
      log "%s execution %d finished: %s" id.Api.run_id id.Api.execution
        (Api.string_of_execution_outcome result.Api.outcome)
    | Error e -> log "finish failed: %s" e.Api.error_markdown
  in
  let aborted () =
    post [ phase_body Api.Aborted (Some "cancel order received") ];
    finish
      {
        Api.outcome = `Aborted;
        cells_passed = 0;
        cells_failed = 0;
        detail = Some "cancelled via heartbeat";
      }
  in
  (* enter a phase: announce it, then heartbeat -- the reply is the control
     channel, and `Cancel is obeyed at the next phase boundary *)
  let phase p detail =
    post [ phase_body p detail ];
    match Rpc.Agent_client.heartbeat cap ~id ~phase:p with
    | Ok `Continue -> `Continue
    | Ok `Cancel -> `Cancel
    | Error e ->
      log "heartbeat failed: %s" e.Api.error_markdown;
      `Cancel (* no lease, no legitimacy: stop rather than run unsupervised *)
  in
  log "%s execution %d claimed (timeout %ds, caches %s)" id.Api.run_id
    id.Api.execution a.Api.timeout_seconds
    (match a.Api.caches with `Reuse -> "reuse" | `Bypass -> "bypass");
  match phase Api.Preparing (Some "stub executor: no benchmark will run") with
  | `Cancel -> aborted ()
  | `Continue -> (
    match phase Api.Measuring (Some "stub: sleeping in place of running-ng") with
    | `Cancel -> aborted ()
    | `Continue -> (
      Eio.Time.sleep clock stub_seconds;
      match phase Api.Collecting None with
      | `Cancel -> aborted ()
      | `Continue ->
        let report =
          Printf.sprintf
            "# %s\n\nStub execution %d: the agent claimed this run and \
             walked the execution protocol, but ran no benchmark (stage 1).\n"
            id.Api.run_id id.Api.execution
        in
        (match
           Rpc.Agent_client.upload cap ~id
             { Api.path = "report.md"; content = report }
         with
        | Ok () -> ()
        | Error e -> log "upload failed: %s" e.Api.error_markdown);
        (* the stub claims every planned cell passed; the real executor
           counts them from running-ng's contract output *)
        let programs = jint (member "programs" (member "selection" a.Api.spec)) in
        let config_count =
          jint (member "config_count" (member "measurement" a.Api.spec))
        in
        finish
          {
            Api.outcome = `Done;
            cells_passed = programs * config_count;
            cells_failed = 0;
            detail = Some "stub execution: no benchmark ran";
          }))

(* --- the claim loop ---------------------------------------------------------- *)

let () =
  let o = parse_args (List.tl (Array.to_list Sys.argv)) in
  let cap_file =
    match o.cap with
    | Some c -> c
    | None -> die "no capability: pass --cap FILE or set $BENCH_AGENT_CAP"
  in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let vat = Capnp_rpc_unix.client_only_vat ~sw (Eio.Stdenv.net env) in
  match Capnp_rpc_unix.Cap_file.load vat cap_file with
  | Error (`Msg m) -> die "cannot load capability %s: %s" cap_file m
  | Ok sr -> (
    match
      Capnp_rpc_unix.with_cap_exn sr @@ fun cap ->
      (* an empty report registers the machine's cache view (none yet) *)
      (match Rpc.Agent_client.report_caches cap [] with
      | Ok () -> ()
      | Error e -> log "report_caches failed: %s" e.Api.error_markdown);
      log "polling for work (interval %.0fs, stub executor)" o.interval;
      let rec loop () =
        match Rpc.Agent_client.claim cap with
        | Error e ->
          (* claim failing is a server/transport problem; exit and let the
             supervisor restart with a fresh connection *)
          Printf.eprintf "bench-agent: claim failed: %s\n" e.Api.error_markdown;
          exit 3
        | Ok None ->
          Eio.Time.sleep clock o.interval;
          loop ()
        | Ok (Some a) ->
          execute cap ~clock ~stub_seconds:o.stub_seconds a;
          if o.once then () else loop ()
      in
      loop ()
    with
    | () -> ()
    | exception ex ->
      Printf.eprintf "bench-agent: cannot reach the server behind %s: %s\n"
        cap_file (Printexc.to_string ex);
      exit 3)
