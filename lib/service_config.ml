(* Service configuration: bot identity, who may trigger, which machines exist.

   All three are config, never constants:

   * The **bot account** must be swappable -- the prototype runs as a throwaway
     account (as Julia's Nanosoldier does) and will move to a real one.  Nothing
     in the code names it, and the token is read from a named environment
     variable so rotating it never touches a source file.
   * The **allowlist** must be extendable without a deploy: a maintainer edits
     this file and the next request sees it.
   * The **admins** are the allowlist's privileged subset (§5.4): they may use
     `force=true` and `priority=top`, cancel anyone's run, and operate machines.
     An admin need not appear in `allowlist` too.
   * The **machine registry** is how machines are added and removed.  An entry
     is really a *slot*: one concurrent run, because running-ng locks the opam
     root -- which is also the property that keeps two measurements from
     overlapping on one machine.  No ssh coordinates and NO PATHS: the server
     never connects to a bench machine (Q1, the agent dials out), and where
     things live on the machine is the AGENT's configuration (§6.1) -- the
     registry holds names and policy, nothing else. *)

type bot = { account : string; token_env : string }

type machine = { name : string; dedicated : bool; is_default : bool }

type t = {
  bot : bot;
  results_repo : string;
  compiler_repo : string;
      (* clone URL that vs= versions/branches resolve against *)
  allowlist : string list;
  admins : string list;
  allow_associations : string list;
  machines : machine list;
  cap_seconds : float;
  cell_seconds : float;
  flavors : (string * string) list;
      (* build flavors: grammar name -> configure args, canonical order.
         The vs= `+name` suffixes resolve against this; names and args must
         both be unique or runtime names stop being injective. *)
  report : Report.thresholds;
      (* verdict bands + gates for report.md (§5.5); provisional until Q12 *)
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
  Ok
    {
      name;
      dedicated = bool_or false (member "dedicated" j);
      is_default = bool_or false (member "default" j);
    }

let of_json j =
  let botj = member "bot" j in
  let* account = str (member "account" botj) in
  let* token_env = str ~default:"BENCH_BOT_TOKEN" (member "token_env" botj) in
  let* results_repo = str (member "results_repo" j) in
  let* flavors =
    match member "flavors" j with
    | `Null -> Ok Variant.default_flavors
    | `List l ->
      let* fs =
        List.fold_left
          (fun acc f ->
            let* acc = acc in
            let* name = str (member "name" f) in
            let* args = str (member "configure_args" f) in
            if name = "" || args = "" then
              Error "a flavor needs a non-empty `name` and `configure_args`"
            else if
              not
                (String.for_all
                   (function
                     | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
                     | _ -> false)
                   name)
            then
              Error
                (Printf.sprintf
                   "flavor name `%s`: lowercase letters, digits, `-`, `_` \
                    only (it becomes part of switch names)"
                   name)
            else Ok (acc @ [ (name, args) ]))
          (Ok []) l
      in
      let dup key l =
        List.exists (fun x -> List.length (List.filter (( = ) (key x)) (List.map key l)) > 1) l
      in
      if dup fst fs then Error "`flavors` has a duplicate name"
      else if dup snd fs then
        Error
          "`flavors` has two names for the same configure_args -- runtime \
           names would stop being injective"
      else Ok fs
    | _ -> Error "`flavors` must be a list of {name, configure_args}"
  in
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
    let logins k = List.map String.lowercase_ascii (strings (member k j)) in
    let allowlist = logins "allowlist" in
    let admins = logins "admins" in
    if
      allowlist = [] && admins = []
      && strings (member "allow_associations" j) = []
    then
      Error
        "`allowlist` and `admins` are empty and no `allow_associations` are \
         set: nobody could trigger a run. Add at least one login."
    else
      Ok
        {
          bot = { account; token_env };
          results_repo;
          compiler_repo =
            (match
               str ~default:"https://github.com/ocaml/ocaml"
                 (member "compiler_repo" j)
             with
            | Ok s -> s
            | Error _ -> "https://github.com/ocaml/ocaml");
          allowlist;
          admins;
          allow_associations = strings (member "allow_associations" j);
          machines;
          cap_seconds = float_or Cost.default_cap_seconds (member "cap_seconds" j);
          cell_seconds =
            float_or Cost.default_cell_seconds (member "cell_seconds" j);
          flavors;
          report =
            (let r = member "report" j in
             let d = Report.default_thresholds in
             {
               Report.warn_pct = float_or d.Report.warn_pct (member "warn_pct" r);
               significant_pct =
                 float_or d.Report.significant_pct (member "significant_pct" r);
               wall_min_invocations =
                 (match member "wall_min_invocations" r with
                 | `Int i -> i
                 | _ -> d.Report.wall_min_invocations);
               rss_floor_kib =
                 float_or d.Report.rss_floor_kib (member "rss_floor_kib" r);
             });
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
