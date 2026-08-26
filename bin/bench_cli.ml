(* bench-cli -- the thin client of API A, over Cap'n Proto.

     submit "<command>"   send a /bench command; prints the acknowledgement
     status <run-id>      one run's state
     list                 the runs index (newest first)
     cancel <run-id>      cancel a queued run (owner or admin)
     help                 the /bench reference, served by the server
     vocab                machines, families, tags, sweepable params
     machines | drain <m> | undrain <m> | requeue <id> | evict <m>   (admin)

   Thin means thin: this binary parses NOTHING of the /bench grammar and
   renders NOTHING itself -- it sends the raw command and prints whatever
   markdown comes back (Q13: the grammar lives in the server; there is no
   offline mode).

   Identity is the capability file (--cap, or $BENCH_CAP): whoever holds
   <login>.cap is that login; there is no --login.  The one exception is the
   PR bot, which holds bot.cap and passes --as-login with the commenter it
   verified via GitHub, plus the --pr-* context from the webhook. *)

open Bench_service
open Bench_rpc

type opts = {
  cap : string option;
  as_login : string option;  (* bot.cap only *)
  pr_repo : string option;
  pr_number : int option;
  pr_url : string option;
  comment_id : string option;
  comment_url : string option;
  head_sha : string option;
  base_ref : string option;
  requester : string option;
  state : string option;
  limit : int;
  since : int;
  runtime : string option;
}

let default_opts () =
  {
    cap = Sys.getenv_opt "BENCH_CAP";
    as_login = None;
    pr_repo = None;
    pr_number = None;
    pr_url = None;
    comment_id = None;
    comment_url = None;
    head_sha = None;
    base_ref = None;
    requester = None;
    state = None;
    limit = 25;
    since = 0;
    runtime = None;
  }

let die fmt = Printf.ksprintf (fun s -> prerr_endline s; exit 2) fmt

let usage () =
  print_string
    {|bench-cli -- submit and watch benchmark runs (a thin API A client)

  bench-cli submit "/bench tag=small invocations=1 vs=5.4.1,trunk" --cap me.cap
  bench-cli status <run-id> --cap me.cap
  bench-cli list [--requester X] [--state queued] [--limit N]
  bench-cli cancel <run-id>
  bench-cli help | vocab
  bench-cli machines | drain <m> | undrain <m> | requeue <id> | evict <m> [--runtime NAME]

The capability file is the identity: --cap FILE or $BENCH_CAP. The grammar
lives in the server; run `bench-cli help` for the /bench reference.

Bot mode (bot.cap only): --as-login <commenter> plus the PR context
  --pr-repo owner/name --pr-number N --pr-url URL
  --comment-id ID --comment-url URL [--head-sha SHA] [--base-ref BRANCH]
|};
  exit 0

let parse_args argv =
  let o = ref (default_opts ()) in
  let positional = ref [] in
  let rec go = function
    | [] -> ()
    | flag :: rest ->
      let need () =
        match rest with v :: tl -> (v, tl) | [] -> die "%s needs a value" flag
      in
      let set f = let v, tl = need () in o := f v; go tl in
      (match flag with
      | "--cap" -> set (fun v -> { !o with cap = Some v })
      | "--as-login" -> set (fun v -> { !o with as_login = Some v })
      | "--pr-repo" -> set (fun v -> { !o with pr_repo = Some v })
      | "--pr-number" ->
        set (fun v -> { !o with pr_number = Some (int_of_string v) })
      | "--pr-url" -> set (fun v -> { !o with pr_url = Some v })
      | "--comment-id" -> set (fun v -> { !o with comment_id = Some v })
      | "--comment-url" -> set (fun v -> { !o with comment_url = Some v })
      | "--head-sha" -> set (fun v -> { !o with head_sha = Some v })
      | "--base-ref" -> set (fun v -> { !o with base_ref = Some v })
      | "--requester" -> set (fun v -> { !o with requester = Some v })
      | "--state" -> set (fun v -> { !o with state = Some v })
      | "--limit" -> set (fun v -> { !o with limit = int_of_string v })
      | "--since" -> set (fun v -> { !o with since = int_of_string v })
      | "--runtime" -> set (fun v -> { !o with runtime = Some v })
      | "-h" | "--help" -> usage ()
      | arg when String.length arg > 0 && arg.[0] = '-' ->
        die "unknown flag %s (try --help)" arg
      | arg -> positional := !positional @ [ arg ]; go rest)
  in
  go argv;
  (!o, !positional)

let fail_api (e : Api.error) =
  print_endline e.Api.error_markdown;
  exit 1

(* The origin the server records.  A CLI origin's idempotency id is assigned
   server-side from the capability's login, so "cli" is just the kind. *)
let origin o =
  match (o.as_login, o.pr_repo, o.pr_number) with
  | None, None, None -> { Api.kind = Api.Cli; id = "cli" }
  | Some _, Some repo, Some number ->
    let req name = function
      | Some v -> v
      | None -> die "bot mode needs %s" name
    in
    let comment_id = req "--comment-id" o.comment_id in
    {
      Api.kind =
        Api.Pr_comment
          {
            Api.repo;
            number;
            url = req "--pr-url" o.pr_url;
            comment_id;
            comment_url = req "--comment-url" o.comment_url;
            head_sha = o.head_sha;
            base_ref = o.base_ref;
          };
      id = comment_id;
    }
  | Some _, _, _ -> die "--as-login needs the full --pr-* context"
  | None, _, _ ->
    die "--pr-* flags are bot mode; they need --as-login (and bot.cap)"

(* Exit codes are the bot's contract: 0 = outcome printed, 1 = the server
   REFUSED (postable markdown on stdout), 2 = CLI usage error, 3 = could not
   reach the server at all -- the caller should log and retry, never post. *)
let with_cap o f =
  let cap_file =
    match o.cap with
    | Some c -> c
    | None -> die "no capability: pass --cap FILE or set $BENCH_CAP"
  in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Eio.Switch.run @@ fun sw ->
  let vat = Capnp_rpc_unix.client_only_vat ~sw (Eio.Stdenv.net env) in
  match Capnp_rpc_unix.Cap_file.load vat cap_file with
  | Error (`Msg m) -> die "cannot load capability %s: %s" cap_file m
  | Ok sr -> (
    match Capnp_rpc_unix.with_cap_exn sr f with
    | v -> v
    | exception ex ->
      Printf.eprintf "cannot reach the server behind %s: %s\n" cap_file
        (Printexc.to_string ex);
      exit 3)

let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let jstr = function `String s -> Some s | _ -> None

(* Whatever the outcome, the server rendered something postable: print it. *)
let print_outcome j =
  match jstr (member "outcome" j) with
  | Some ("accepted" | "reused") -> (
    match jstr (member "ack_markdown" j) with
    | Some md -> print_endline md
    | None -> print_endline (Yojson.Safe.pretty_to_string j))
  | Some "answered" -> (
    match jstr (member "markdown" j) with
    | Some md -> print_endline md
    | None -> print_endline (Yojson.Safe.pretty_to_string j))
  | Some "duplicate" ->
    Printf.printf "Already submitted: this command is `%s` (still active).\n"
      (Option.value (jstr (member "run_id" j)) ~default:"?")
  | _ -> print_endline (Yojson.Safe.pretty_to_string j)

let print_metas j =
  match j with
  | `List [] -> print_endline "no runs"
  | `List metas ->
    List.iter
      (fun m ->
        Printf.printf "%-20s %-10s %-12s %-10s %s\n"
          (Option.value (jstr (member "run_id" m)) ~default:"?")
          (Option.value (jstr (member "state" m)) ~default:"?")
          (Option.value (jstr (member "requested_by" m)) ~default:"?")
          (Option.value (jstr (member "machine" m)) ~default:"?")
          (Option.value (jstr (member "command" m)) ~default:"?"))
      metas
  | other -> print_endline (Yojson.Safe.pretty_to_string other)

let unit_ok = function Ok () -> () | Error e -> fail_api e

let json_ok = function
  | Ok j -> print_endline (Yojson.Safe.pretty_to_string j)
  | Error e -> fail_api e

let () =
  match Array.to_list Sys.argv with
  | _ :: cmd :: rest -> (
    let o, positional = parse_args rest in
    match (cmd, positional) with
    | "submit", [ command ] -> (
      (* bot.cap and <login>.cap restore different interfaces, so the two
         paths are typed apart *)
      match o.as_login with
      | Some login ->
        with_cap o (fun cap ->
            match
              Rpc.Bot_client.submit_as cap ~login ~command ~origin:(origin o)
            with
            | Ok j -> print_outcome j
            | Error e -> fail_api e)
      | None ->
        with_cap o (fun cap ->
            match Rpc.Client.submit cap ~command ~origin:(origin o) with
            | Ok j -> print_outcome j
            | Error e -> fail_api e))
    | "submit", _ -> die "submit takes exactly one argument: the /bench command"
    | "status", [ id ] ->
      with_cap o (fun cap -> json_ok (Rpc.Client.status cap ~run_id:id))
    | "events", [ id ] ->
      with_cap o (fun cap ->
          json_ok (Rpc.Client.events cap ~run_id:id ~since:o.since))
    | "list", [] ->
      with_cap o (fun cap ->
          match
            Rpc.Client.list cap ?requester:o.requester ?state:o.state
              ~limit:o.limit ()
          with
          | Ok j -> print_metas j
          | Error e -> fail_api e)
    | "cancel", [ id ] ->
      with_cap o (fun cap ->
          unit_ok (Rpc.Client.cancel cap ~run_id:id);
          Printf.printf "cancelled %s\n" id)
    | "help", [] ->
      with_cap o (fun cap ->
          match Rpc.Client.help cap with
          | Ok md -> print_string md
          | Error e -> fail_api e)
    | "vocab", [] -> with_cap o (fun cap -> json_ok (Rpc.Client.vocab cap))
    | "machines", [] ->
      with_cap o (fun cap -> json_ok (Rpc.Client.machines cap))
    | "drain", [ m ] ->
      with_cap o (fun cap ->
          unit_ok (Rpc.Client.drain cap ~machine:m);
          Printf.printf "drained %s\n" m)
    | "undrain", [ m ] ->
      with_cap o (fun cap ->
          unit_ok (Rpc.Client.undrain cap ~machine:m);
          Printf.printf "undrained %s\n" m)
    | "requeue", [ id ] ->
      with_cap o (fun cap -> unit_ok (Rpc.Client.requeue cap ~run_id:id))
    | "evict", [ m ] ->
      with_cap o (fun cap ->
          match Rpc.Client.evict cap ~machine:m ~runtime_name:o.runtime with
          | Ok bytes -> Printf.printf "evicted %Ld bytes\n" bytes
          | Error e -> fail_api e)
    | ("-h" | "--help"), _ -> usage ()
    | other, _ -> die "unknown command %s (try --help)" other)
  | _ -> usage ()
