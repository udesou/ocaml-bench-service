(* bench-agent -- the bench machine daemon (API B, §6.2).

   Dials the server (the agent pulls, §6.4: the machine needs no inbound
   access at all) with an agent capability, claims work, executes it, ships
   events and artifacts back, and reports its caches.  The capability file IS
   the machine's identity: whoever holds agent-<machine>.cap is that
   machine's agent.

   The REAL executor (the default):

     prepare   own working clones under --state-dir (never the operator's
               personal checkouts), hard-checked-out to the spec's pinned
               shas; the config materialized from the spec with
               ${RUNNING_NG_ROOT} substituted, after verifying its md5
     execute   the pinned tree's own launch script (tools switch, opam
               compiler plugin, olly build, then python3 -m running runbms)
               under setsid, supervised against the assignment's timeout
               with a heartbeat every 30s -- a Cancel reply, like a timeout,
               SIGTERMs the process group, waits out a grace, SIGKILLs
     collect   the new run directory under LOG_DIR, mapped into the §8
               bundle: contract/ and runbms*.yml verbatim, per-cell logs and
               tool sidecars under raw/, our captured console.log; raw
               memtrace traces never leave the machine (spec exclude)

   Not here yet (stage 2b): switch-provenance enforcement and binary-cache
   wiping (§6.3) -- this build reuses whatever running-ng reuses and deletes
   nothing, because the opam root is shared with the operator's own compiler
   cache.  --stub keeps the protocol-only executor for tests.

   The process exits on a broken connection rather than reconnecting: a
   supervisor loop (screen/systemd) restarting it is simpler and more honest
   than half-reconnected state. *)

open Bench_service
open Bench_rpc

let home = try Sys.getenv "HOME" with Not_found -> "."

type opts = {
  cap : string option;
  state_dir : string;  (* clones + work areas + LOG_DIR live here *)
  log_root : string option;  (* override LOG_DIR (default <state>/logs) *)
  interval : float;  (* seconds between empty claims *)
  once : bool;  (* execute one assignment, then exit (smoke tests) *)
  stub : bool;  (* protocol-only executor: no benchmark runs *)
  stub_seconds : float;  (* how long the stub's fake measurement takes *)
}

let default_opts () =
  {
    cap = Sys.getenv_opt "BENCH_AGENT_CAP";
    state_dir = Filename.concat home ".bench-agent";
    log_root = None;
    interval = 5.0;
    once = false;
    stub = false;
    stub_seconds = 1.0;
  }

let die fmt = Printf.ksprintf (fun s -> prerr_endline s; exit 2) fmt
let log fmt = Printf.ksprintf (fun s -> Printf.printf "bench-agent: %s\n%!" s) fmt

let usage () =
  print_string
    {|bench-agent -- the bench machine daemon (API B)

  bench-agent --cap agent-<machine>.cap [--state-dir DIR] [--once] [--stub]

Claims queued runs for its machine from the server and executes them with
running-ng at the spec's pinned sources.

Options:
  --cap FILE        the agent capability (or $BENCH_AGENT_CAP);
                    written by bench-serve as <state>/caps/agent-<machine>.cap
  --state-dir DIR   clones, work areas and logs (default ~/.bench-agent)
  --log-dir DIR     running-ng LOG_DIR (default <state-dir>/logs)
  --interval SEC    poll interval while the queue is empty (default 5)
  --once            process one assignment, then exit
  --stub            protocol-only executor: walks claim/heartbeat/events/
                    upload/finish but runs no benchmark
  --stub-seconds S  how long the stub's fake measurement sleeps (default 1)
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
      | "--state-dir" -> set (fun v -> { !o with state_dir = v })
      | "--log-dir" -> set (fun v -> { !o with log_root = Some v })
      | "--interval" -> set (fun v -> { !o with interval = float_of_string v })
      | "--once" -> o := { !o with once = true }; go rest
      | "--stub" -> o := { !o with stub = true }; go rest
      | "--stub-seconds" ->
        set (fun v -> { !o with stub_seconds = float_of_string v })
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

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  end

(* --- small utilities --------------------------------------------------------- *)

let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let jstr = function `String s -> Some s | _ -> None
let jint = function `Int i -> i | _ -> 0
let jlist = function `List l -> l | _ -> []

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* Replace every occurrence of [sub] in [s] with [by]. *)
let replace_all ~sub ~by s =
  let b = Buffer.create (String.length s) in
  let n = String.length sub in
  let rec go i =
    if i > String.length s - n then
      Buffer.add_string b (String.sub s i (String.length s - i))
    else if String.sub s i n = sub then begin
      Buffer.add_string b by;
      go (i + n)
    end
    else begin
      Buffer.add_char b s.[i];
      go (i + 1)
    end
  in
  if n = 0 then s else (go 0; Buffer.contents b)

(* fnmatch over '/'-separated relative paths: '*' stops at '/', '**' crosses
   it.  Enough for the spec's artifact globs. *)
let glob_match pat s =
  let pl = String.length pat and sl = String.length s in
  let rec go i j =
    if i >= pl then j >= sl
    else if i + 1 < pl && pat.[i] = '*' && pat.[i + 1] = '*' then
      let rec try_j j' = j' <= sl && (go (i + 2) j' || try_j (j' + 1)) in
      try_j j
    else
      match pat.[i] with
      | '*' ->
        let rec try_j j' =
          go (i + 1) j' || (j' < sl && s.[j'] <> '/' && try_j (j' + 1))
        in
        try_j j
      | c -> j < sl && s.[j] = c && go (i + 1) (j + 1)
  in
  go 0 0

(* Every file under [root], as root-relative paths. *)
let walk root =
  let acc = ref [] in
  let rec go rel =
    let abs = if rel = "" then root else Filename.concat root rel in
    match (Unix.stat abs).Unix.st_kind with
    | Unix.S_DIR ->
      Array.iter
        (fun name -> go (if rel = "" then name else Filename.concat rel name))
        (Sys.readdir abs)
    | Unix.S_REG -> acc := rel :: !acc
    | _ -> ()
    | exception Unix.Unix_error _ -> ()
  in
  go "";
  List.rev !acc

let tail_of_file path n =
  match Util.read_file path with
  | exception _ -> ""
  | s ->
    let l = String.length s in
    if l <= n then s else String.sub s (l - n) n

(* --- the execution protocol, shared by both executors ------------------------ *)

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

type proto = {
  id : Api.execution_id;
  post : Yojson.Safe.t list -> unit;
  heartbeat : Api.execution_phase -> [ `Continue | `Cancel ];
  upload : path:string -> content:string -> unit;
  finish : Api.execution_result -> unit;
}

let proto cap (id : Api.execution_id) =
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
  {
    id;
    post;
    heartbeat =
      (fun phase ->
        match Rpc.Agent_client.heartbeat cap ~id ~phase with
        | Ok order -> order
        | Error e ->
          log "heartbeat failed: %s" e.Api.error_markdown;
          (* no lease, no legitimacy: stop rather than run unsupervised *)
          `Cancel);
    upload =
      (fun ~path ~content ->
        match Rpc.Agent_client.upload cap ~id { Api.path; content } with
        | Ok () -> ()
        | Error e -> log "upload %s failed: %s" path e.Api.error_markdown);
    finish =
      (fun result ->
        post [ finished_body result ];
        match Rpc.Agent_client.finish cap ~id result with
        | Ok () ->
          (* the server's Ok IS the store confirmation (§6.5) *)
          log "%s execution %d finished: %s" id.Api.run_id id.Api.execution
            (Api.string_of_execution_outcome result.Api.outcome)
        | Error e -> log "finish failed: %s" e.Api.error_markdown);
  }

(* announce a phase, then heartbeat: the reply is the control channel *)
let phase (p : proto) ph detail =
  p.post [ phase_body ph detail ];
  p.heartbeat ph

let abort (p : proto) ~detail =
  p.post [ phase_body Api.Aborted (Some detail) ];
  p.finish
    {
      Api.outcome = `Aborted;
      cells_passed = 0;
      cells_failed = 0;
      detail = Some detail;
    }

let fail_run (p : proto) fmt =
  Printf.ksprintf
    (fun detail ->
      log "%s execution %d failed: %s" p.id.Api.run_id p.id.Api.execution
        detail;
      p.finish
        {
          Api.outcome = `Failed;
          cells_passed = 0;
          cells_failed = 0;
          detail = Some detail;
        })
    fmt

(* --- the real executor ------------------------------------------------------- *)

let git args =
  match Resolver.git_run ~git:"git" args with
  | Ok out -> Ok out
  | Error msg -> Error msg

(* The agent's own working clone of one pinned source, hard-positioned at the
   spec's sha.  Untracked files survive on purpose: macro-benches caches its
   built binaries in-tree (_build-<runtime>/) and olly its _build/. *)
let ensure_checkout ~dir ~repo ~commit =
  let ( let* ) = Result.bind in
  let* () =
    if Sys.file_exists dir then Ok ()
    else begin
      log "cloning %s -> %s (first run; may take a while)" repo dir;
      mkdir_p (Filename.dirname dir);
      match git [ "clone"; "--quiet"; repo; dir ] with
      | Ok _ -> Ok ()
      | Error m -> Error (Printf.sprintf "clone %s: %s" repo m)
    end
  in
  let* () =
    match git [ "-C"; dir; "cat-file"; "-e"; commit ^ "^{commit}" ] with
    | Ok _ -> Ok ()
    | Error _ -> (
      match git [ "-C"; dir; "fetch"; "--quiet"; "origin" ] with
      | Ok _ -> Ok ()
      | Error m -> Error (Printf.sprintf "fetch %s: %s" dir m))
  in
  match git [ "-C"; dir; "checkout"; "--quiet"; "--force"; "--detach"; commit ]
  with
  | Ok _ -> Ok ()
  | Error m -> Error (Printf.sprintf "checkout %s in %s: %s" commit dir m)

let launch_script = "run_ocaml_bench_gc_sweep.sh"

(* environment for the child: current env with [overrides] winning *)
let child_env overrides =
  let keys = List.map fst overrides in
  let keep e =
    match String.index_opt e '=' with
    | Some i -> not (List.mem (String.sub e 0 i) keys)
    | None -> true
  in
  Array.of_list
    (List.filter keep (Array.to_list (Unix.environment ()))
    @ List.map (fun (k, v) -> k ^ "=" ^ v) overrides)

(* SIGTERM the child's process group (setsid made pid its group), grace,
   SIGKILL, and reap. *)
let kill_group ~clock pid =
  let signal s = try Unix.kill (-pid) s with Unix.Unix_error _ -> () in
  signal Sys.sigterm;
  let rec grace n =
    if n <= 0 then begin
      signal Sys.sigkill;
      ignore (try Unix.waitpid [] pid with Unix.Unix_error _ -> (0, Unix.WEXITED 0))
    end
    else
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ ->
        Eio.Time.sleep clock 1.0;
        grace (n - 1)
      | _ -> ()
      | exception Unix.Unix_error _ -> ()
  in
  grace 30

(* Supervise the child: poll for exit, heartbeat every 30s (the reply is the
   cancel channel), enforce the assignment's timeout. *)
let supervise ~clock (p : proto) ~timeout_seconds pid =
  let deadline = Unix.gettimeofday () +. float_of_int timeout_seconds in
  let last_hb = ref 0. in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | exception Unix.Unix_error _ -> `Exited (Unix.WEXITED 127)
    | 0, _ ->
      let now = Unix.gettimeofday () in
      if now > deadline then begin
        log "%s: timeout after %ds; killing the process group"
          p.id.Api.run_id timeout_seconds;
        kill_group ~clock pid;
        `Timed_out
      end
      else if now -. !last_hb >= 30. then begin
        last_hb := now;
        match p.heartbeat Api.Measuring with
        | `Continue -> loop ()
        | `Cancel ->
          log "%s: cancel order; killing the process group" p.id.Api.run_id;
          kill_group ~clock pid;
          `Cancelled
      end
      else begin
        Eio.Time.sleep clock 2.0;
        loop ()
      end
    | _, status -> `Exited status
  in
  loop ()

let execute_real cap ~clock ~(opts : opts) (a : Api.assignment) =
  let p = proto cap a.Api.id in
  let id = a.Api.id in
  let spec = a.Api.spec in
  let state = opts.state_dir in
  let gits = Filename.concat state "git" in
  let workdir =
    Filename.concat state
      (Printf.sprintf "work/%s-e%d" id.Api.run_id id.Api.execution)
  in
  let log_root =
    Option.value opts.log_root ~default:(Filename.concat state "logs")
  in
  log "%s execution %d claimed (timeout %ds, caches %s)" id.Api.run_id
    id.Api.execution a.Api.timeout_seconds
    (match a.Api.caches with `Reuse -> "reuse" | `Bypass -> "bypass");
  match jstr (member "spec_version" spec) with
  | Some v when v <> "1" ->
    (* the RUNSPEC rule: refuse a version we do not know, never guess *)
    fail_run p "unknown spec_version %s (this agent speaks 1)" v
  | _ -> (
    match
      phase p Api.Preparing (Some "checking out pinned sources")
    with
    | `Cancel -> abort p ~detail:"cancelled before preparation"
    | `Continue -> (
      (* --- prepare: sources at the spec's shas --------------------------- *)
      let sources =
        List.filter_map
          (fun j ->
            match
              (jstr (member "name" j), jstr (member "repo" j),
               jstr (member "commit" j))
            with
            | Some name, Some repo, Some commit -> Some (name, repo, commit)
            | _ -> None)
          (jlist (member "sources" spec))
      in
      let dir_of name = Filename.concat gits name in
      let checkout_all () =
        List.fold_left
          (fun acc (name, repo, commit) ->
            match acc with
            | Error _ -> acc
            | Ok () -> (
              (* olly: a pin move must invalidate the cached _build, which
                 the launch script only rebuilds when the binary is absent *)
              let dir = dir_of name in
              let marker = Filename.concat state "olly-built" in
              if name = "olly" then begin
                let last =
                  match Util.read_file marker with
                  | s -> String.trim s
                  | exception _ -> ""
                in
                if last <> "" && last <> commit then begin
                  log "olly pin moved (%s -> %s): dropping its _build" last
                    commit;
                  ignore
                    (Sys.command
                       (Printf.sprintf "rm -rf %s"
                          (Filename.quote (Filename.concat dir "_build"))))
                end
              end;
              match ensure_checkout ~dir ~repo ~commit with
              | Error m -> Error m
              | Ok () ->
                if name = "olly" then Util.write_file marker (commit ^ "\n");
                Ok ()))
          (Ok ()) sources
      in
      match checkout_all () with
      | Error m -> fail_run p "prepare: %s" m
      | Ok () -> (
        let running_ng = dir_of "running-ng" in
        let benches_dir =
          if Sys.file_exists (dir_of "macro-benches") then
            dir_of "macro-benches"
          else dir_of "benches"
        in
        let script = Filename.concat running_ng launch_script in
        if not (Sys.file_exists script) then
          fail_run p "prepare: %s not in the pinned running-ng tree"
            launch_script
        else begin
          (* --- prepare: the config, materialized ------------------------- *)
          let config = member "config" spec in
          let contents =
            Option.value (jstr (member "contents" config)) ~default:""
          in
          let md5 = Option.value (jstr (member "md5" config)) ~default:"" in
          let filename =
            Option.value (jstr (member "filename" config))
              ~default:(id.Api.run_id ^ ".yml")
          in
          if contents = "" then fail_run p "prepare: the spec carries no config"
          else if md5 <> "" && Digest.to_hex (Digest.string contents) <> md5
          then fail_run p "prepare: config md5 mismatch (spec drifted?)"
          else begin
            mkdir_p workdir;
            mkdir_p log_root;
            let config_path = Filename.concat workdir filename in
            Util.write_file config_path
              (replace_all ~sub:Runspec.running_ng_root_var ~by:running_ng
                 contents);
            let tags =
              List.filter_map
                (fun j -> jstr (member "name" j))
                (jlist (member "tags" (member "selection" spec)))
            in
            (* --- execute: the pinned tree's own launch script ------------- *)
            let overrides =
              [
                ("LOG_DIR", log_root);
                ("CONFIG_FILE", config_path);
                ("RUNNING_MACRO_BENCH_DIR", benches_dir);
                ("RUNNING_BENCH_DIR", benches_dir);
                ("OLLY_DIR", dir_of "olly");
                ("RUNNING_REUSE_SWITCHES", "1");
              ]
              @ (if tags = [] then [] else
                 [ ("RUNNING_TAG", String.concat "," tags) ])
            in
            let console_path = Filename.concat workdir "console.log" in
            let console =
              Unix.openfile console_path
                [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
                0o644
            in
            let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
            let before =
              if Sys.file_exists log_root then
                Array.to_list (Sys.readdir log_root)
              else []
            in
            let outcome =
              match
                phase p Api.Measuring
                  (Some
                     (Printf.sprintf
                        "running-ng runbms (cold caches build compilers \
                         first; timeout %ds)"
                        a.Api.timeout_seconds))
              with
              | `Cancel -> `Cancelled
              | `Continue -> (
                match
                  Unix.create_process_env "setsid"
                    [| "setsid"; script |]
                    (child_env overrides) devnull console console
                with
                | exception e ->
                  `Spawn_failed (Printexc.to_string e)
                | pid ->
                  supervise ~clock p
                    ~timeout_seconds:a.Api.timeout_seconds pid)
            in
            Unix.close console;
            Unix.close devnull;
            (* --- collect: on failure as well as success ------------------- *)
            let after =
              if Sys.file_exists log_root then
                Array.to_list (Sys.readdir log_root)
              else []
            in
            let fresh = List.filter (fun d -> not (List.mem d before)) after in
            ignore (phase p Api.Collecting
                      (Some (match fresh with
                       | d :: _ -> "run directory " ^ d
                       | [] -> "no run directory was produced")));
            let fetch =
              List.filter_map jstr
                (jlist (member "fetch" (member "artifacts" spec)))
            in
            let exclude =
              List.filter_map jstr
                (jlist (member "exclude" (member "artifacts" spec)))
            in
            let uploaded = ref 0 in
            List.iter
              (fun d ->
                let run_dir = Filename.concat log_root d in
                List.iter
                  (fun rel ->
                    let wanted =
                      List.exists (fun g -> glob_match g rel) fetch
                      && not (List.exists (fun g -> glob_match g rel) exclude)
                    in
                    if wanted then begin
                      let abs = Filename.concat run_dir rel in
                      let size = (Unix.stat abs).Unix.st_size in
                      if size > 16 * 1024 * 1024 then
                        log "skipping %s (%d bytes > 16MB)" rel size
                      else begin
                        let dest =
                          if
                            starts_with ~prefix:"contract/" rel
                            || rel = "runbms.yml" || rel = "runbms_args.yml"
                          then rel
                          else "raw/" ^ rel
                        in
                        p.upload ~path:dest ~content:(Util.read_file abs);
                        incr uploaded
                      end
                    end)
                  (walk run_dir))
              fresh;
            p.upload ~path:"console.log"
              ~content:(Util.read_file console_path);
            log "%s: uploaded %d artifacts + console.log" id.Api.run_id
              !uploaded;
            (* --- finish ---------------------------------------------------- *)
            let planned =
              jint (member "programs" (member "selection" spec))
              * jint (member "config_count" (member "measurement" spec))
            in
            match outcome with
            | `Exited (Unix.WEXITED 0) ->
              (* exit 0 is not success: running-ng skips failed benchmark
                 builds and finishes cleanly, so ask the contract whether
                 anything was actually measured *)
              let measured =
                List.exists
                  (fun d ->
                    match
                      Yojson.Safe.from_string
                        (Util.read_file
                           (Filename.concat
                              (Filename.concat log_root d)
                              "contract/manifest.json"))
                    with
                    | j -> jlist (member "configs" j) <> []
                    | exception _ -> false)
                  fresh
              in
              if measured then
                p.finish
                  {
                    Api.outcome = `Done;
                    (* planned counts until the §7 progress plugin reports
                       real per-cell passes *)
                    cells_passed = planned;
                    cells_failed = 0;
                    detail = None;
                  }
              else
                fail_run p
                  "running-ng exited cleanly but the contract holds no \
                   measurements (every benchmark build failed?); console \
                   tail: %s"
                  (tail_of_file console_path 500)
            | `Exited status ->
              let what =
                match status with
                | Unix.WEXITED n -> Printf.sprintf "exit %d" n
                | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n
              in
              fail_run p "running-ng failed (%s); console tail: %s" what
                (tail_of_file console_path 500)
            | `Spawn_failed m -> fail_run p "could not spawn running-ng: %s" m
            | `Timed_out ->
              p.finish
                {
                  Api.outcome = `Timed_out;
                  cells_passed = 0;
                  cells_failed = 0;
                  detail =
                    Some
                      (Printf.sprintf "killed after %ds"
                         a.Api.timeout_seconds);
                }
            | `Cancelled -> abort p ~detail:"cancelled via heartbeat"
          end
        end)))

(* --- the stub executor (--stub): the protocol with no benchmark -------------- *)

let execute_stub cap ~clock ~stub_seconds (a : Api.assignment) =
  let p = proto cap a.Api.id in
  let id = a.Api.id in
  log "%s execution %d claimed (timeout %ds, caches %s) [stub]" id.Api.run_id
    id.Api.execution a.Api.timeout_seconds
    (match a.Api.caches with `Reuse -> "reuse" | `Bypass -> "bypass");
  match phase p Api.Preparing (Some "stub executor: no benchmark will run") with
  | `Cancel -> abort p ~detail:"cancelled via heartbeat"
  | `Continue -> (
    match
      phase p Api.Measuring (Some "stub: sleeping in place of running-ng")
    with
    | `Cancel -> abort p ~detail:"cancelled via heartbeat"
    | `Continue -> (
      Eio.Time.sleep clock stub_seconds;
      match phase p Api.Collecting None with
      | `Cancel -> abort p ~detail:"cancelled via heartbeat"
      | `Continue ->
        p.upload ~path:"report.md"
          ~content:
            (Printf.sprintf
               "# %s\n\nStub execution %d: the agent claimed this run and \
                walked the execution protocol, but ran no benchmark.\n"
               id.Api.run_id id.Api.execution);
        p.finish
          {
            Api.outcome = `Done;
            cells_passed =
              jint (member "programs" (member "selection" a.Api.spec))
              * jint (member "config_count" (member "measurement" a.Api.spec));
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
      (* an empty report registers the machine's cache view (stage 2b fills
         it with real switch/binary provenance) *)
      (match Rpc.Agent_client.report_caches cap [] with
      | Ok () -> ()
      | Error e -> log "report_caches failed: %s" e.Api.error_markdown);
      log "polling for work (interval %.0fs, %s executor, state %s)"
        o.interval
        (if o.stub then "STUB" else "real")
        o.state_dir;
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
          (if o.stub then execute_stub cap ~clock ~stub_seconds:o.stub_seconds a
           else execute_real cap ~clock ~opts:o a);
          if o.once then () else loop ()
      in
      loop ()
    with
    | () -> ()
    | exception ex ->
      Printf.eprintf "bench-agent: cannot reach the server behind %s: %s\n"
        cap_file (Printexc.to_string ex);
      exit 3)
