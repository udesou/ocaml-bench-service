(* Service configuration: bot identity, who may trigger, which machines exist.

   All three are config, never constants:

   * The **bot account** must be swappable -- the prototype runs as a throwaway
     account (as Julia's Nanosoldier does) and will move to a real one.  Nothing
     in the code names it, and the token is read from a named environment
     variable so rotating it never touches a source file.
   * The **allowlist** must be extendable without a deploy: a maintainer edits
     this file and the next request sees it.
   * The **machine registry** is how machines are added and removed.  A slot is
     (host, OPAMROOT, benches dir) -- see the design doc, section 8 -- because
     the opam root lock is what serialises runs. *)

type bot = { account : string; token_env : string }

type machine = {
  name : string;
  ssh : string;
  opamroot : string option;
  macro_bench_dir : string;
  log_dir : string;
  dedicated : bool;
  is_default : bool;
}

type t = {
  bot : bot;
  results_repo : string;
  allowlist : string list;
  allow_associations : string list;
  machines : machine list;
  cap_seconds : float;
  cell_seconds : float;
}

let member k = function
  | `Assoc kvs -> ( match List.assoc_opt k kvs with Some v -> v | None -> `Null)
  | _ -> `Null

let str ?default j =
  match (j, default) with
  | `String s, _ -> Ok s
  | _, Some d -> Ok d
  | _ -> Error "expected a string"

let strings j =
  match j with
  | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
  | _ -> []

let bool_or d j = match j with `Bool b -> b | _ -> d

let float_or d j =
  match j with `Float f -> f | `Int i -> float_of_int i | _ -> d

let string_opt j = match j with `String s -> Some s | _ -> None

let ( let* ) = Result.bind

let machine_of_json j =
  let* name = str (member "name" j) in
  let* ssh = str ~default:"localhost" (member "ssh" j) in
  let* macro_bench_dir = str (member "macro_bench_dir" j) in
  let* log_dir = str (member "log_dir" j) in
  Ok
    {
      name;
      ssh;
      opamroot = string_opt (member "opamroot" j);
      macro_bench_dir;
      log_dir;
      dedicated = bool_or false (member "dedicated" j);
      is_default = bool_or false (member "default" j);
    }

let of_json j =
  let botj = member "bot" j in
  let* account = str (member "account" botj) in
  let* token_env = str ~default:"BENCH_BOT_TOKEN" (member "token_env" botj) in
  let* results_repo = str (member "results_repo" j) in
  let* machines =
    match member "machines" j with
    | `List ms ->
      List.fold_left
        (fun acc m ->
          let* acc = acc in
          let* m = machine_of_json m in
          Ok (acc @ [ m ]))
        (Ok []) ms
    | _ -> Error "`machines` must be a list"
  in
  if machines = [] then Error "`machines` is empty -- nothing could ever run"
  else
    let allowlist = List.map String.lowercase_ascii (strings (member "allowlist" j)) in
    if allowlist = [] && strings (member "allow_associations" j) = [] then
      Error
        "`allowlist` is empty and no `allow_associations` are set: nobody could \
         trigger a run. Add at least one login."
    else
      Ok
        {
          bot = { account; token_env };
          results_repo;
          allowlist;
          allow_associations = strings (member "allow_associations" j);
          machines;
          cap_seconds = float_or Cost.default_cap_seconds (member "cap_seconds" j);
          cell_seconds =
            float_or Cost.default_cell_seconds (member "cell_seconds" j);
        }

let of_string s =
  match Yojson.Safe.from_string s with
  | exception Yojson.Json_error m -> Error ("bad JSON in service config: " ^ m)
  | j -> of_json j

let of_file path =
  match Util.read_file path with
  | exception Sys_error m -> Error m
  | s -> of_string s

let default_machine t =
  match List.find_opt (fun m -> m.is_default) t.machines with
  | Some m -> Some m
  | None -> ( match t.machines with m :: _ -> Some m | [] -> None)

let machine_names t = List.map (fun m -> m.name) t.machines

(* Resolve `machine=` against the registry.  An unknown name is a user error
   with the list attached, not a silent fallback to the default -- silently
   running somewhere else would make the numbers unattributable. *)
let resolve_machine t = function
  | None -> (
    match default_machine t with
    | Some m -> Ok m
    | None -> Error "no machines are registered")
  | Some name -> (
    match List.find_opt (fun m -> m.name = name) t.machines with
    | Some m -> Ok m
    | None ->
      Error
        (Printf.sprintf "Unknown machine `%s`.%s Registered machines: %s." name
           (Util.suggest ~candidates:(machine_names t) name)
           (String.concat ", " (machine_names t))))

(* The bot's credential is never in the config file, only its variable name. *)
let bot_token t =
  match Sys.getenv_opt t.bot.token_env with
  | Some "" | None -> Error (Printf.sprintf "$%s is not set" t.bot.token_env)
  | Some tok -> Ok tok
