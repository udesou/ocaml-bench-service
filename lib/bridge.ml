(* Calling scripts/rng_helper.py.

   The bridge is the only place the service touches python.  It is kept out of
   Gen so that config generation stays pure and testable; only the CLI and the
   one "live" test go through here. *)

type config = { python : string; helper : string; running_ng_src : string option }

let default_config ?(python = "python3") ?helper ?running_ng_src () =
  let helper =
    match helper with
    | Some h -> h
    | None -> Filename.concat (Sys.getcwd ()) "scripts/rng_helper.py"
  in
  { python; helper; running_ng_src }

let run cfg args =
  let env_prefix =
    match cfg.running_ng_src with
    | Some src -> Printf.sprintf "RUNNING_NG_SRC=%s " (Filename.quote src)
    | None -> ""
  in
  let cmd =
    env_prefix ^ Filename.quote_command cfg.python (cfg.helper :: args)
  in
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 8192 in
  (try
     while true do
       Buffer.add_channel buf ic 1
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  let out = Buffer.contents buf in
  match status with
  | Unix.WEXITED 0 -> Ok out
  | Unix.WEXITED 2 ->
    (* The helper's own failure path: it still prints JSON with bridge_error. *)
    Error (Printf.sprintf "rng_helper bridge failure: %s" (String.trim out))
  | Unix.WEXITED n ->
    Error (Printf.sprintf "rng_helper exited %d: %s" n (String.trim out))
  | _ -> Error "rng_helper was killed by a signal"

let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let strings j =
  match j with
  | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
  | _ -> []

let json_of_string s =
  match Yojson.Safe.from_string s with
  | j -> Ok j
  | exception Yojson.Json_error m -> Error ("bad JSON from rng_helper: " ^ m)

let facts cfg ~config =
  match run cfg [ "facts"; "--config"; config ] with
  | Error e -> Error e
  | Ok out -> Facts.of_json_string out

(* validate() + validate_tags().  Returns the bulleted rule breaches, which are
   the exact strings running-ng would have printed -- we do not paraphrase them,
   because the user needs to be able to grep for them in running-ng. *)
let validate cfg ~config =
  match run cfg [ "validate"; "--config"; config ] with
  | Error e -> Error [ e ]
  | Ok out -> (
    match json_of_string out with
    | Error e -> Error [ e ]
    | Ok j -> (
      match member "ok" j with
      | `Bool true -> Ok ()
      | _ -> Error (strings (member "errors" j))))

(* Program count for the cost model, resolved by running-ng's own
   intersection-only tag filter rather than by our approximation of it. *)
let tagfilter cfg ~config ~tags =
  match
    run cfg [ "tagfilter"; "--config"; config; "--tags"; String.concat "," tags ]
  with
  | Error e -> Error [ e ]
  | Ok out -> (
    match json_of_string out with
    | Error e -> Error [ e ]
    | Ok j -> (
      match member "ok" j with
      | `Bool true -> (
        match member "total" j with
        | `Int n -> Ok n
        | _ -> Error [ "tagfilter returned no total" ])
      | _ -> Error (strings (member "errors" j))))
