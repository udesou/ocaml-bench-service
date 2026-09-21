(* A runtime to measure: one side of the comparison.  Variants arrive already
   pinned (resolution is the server's), which keeps this module pure. *)

type spec = Version of string | Commit of string

type role = Baseline | Candidate

type t = {
  label : string;
  spec : spec;
  role : role;
  repo : string option;
      (* clone URL when the sha is not on the default compiler repo (a fork
         PR's head exists only on the fork).  Not part of the runtime name. *)
  configure_args : string;
      (* whitespace-separated configure args; part of the build identity
         (runtime_name) and emitted into the config's `configure_args:` *)
  flavor : string option;
      (* human suffix for the runtime name when configure_args came from named
         flavors, e.g. "fp-flambda"; None means arbitrary args, which get the
         digest.  Whoever sets it owes the injectivity of (suffix <-> args). *)
}

(* The default flavor table (name -> configure args); the deployed one is
   service.json `flavors`.  List order is canonical, so a flavor set maps 1:1
   onto a configure_args string and a name suffix however the user ordered the
   suffixes (matching the existing running-ng-ocaml-5.5.0-fp-flambda naming). *)
let default_flavors =
  [ ("fp", "--enable-frame-pointers"); ("flambda", "--enable-flambda") ]

(* canonicalize a set of flavor names against a table: (suffix, args),
   table order, duplicates collapsed *)
let canonical_flavors ~flavors names =
  let picked = List.filter (fun (n, _) -> List.mem n names) flavors in
  ( String.concat "-" (List.map fst picked),
    String.concat " " (List.map snd picked) )

(* the inverse, for raw args that happen to be exactly a canonical set (the
   dev tool's --variant path): args -> suffix *)
let suffix_of_args ~flavors args =
  let rec subsets = function
    | [] -> [ [] ]
    | x :: rest ->
      let s = subsets rest in
      List.map (fun t -> x :: t) s @ s
  in
  List.find_map
    (fun sub ->
      if sub = [] then None
      else
        let suffix, a = canonical_flavors ~flavors (List.map fst sub) in
        if a = args then Some suffix else None)
    (subsets flavors)

let sha_short sha =
  let n = String.length sha in
  if n <= 7 then sha else String.sub sha 0 7

(* The runtime name is the compiler cache key: running-ng provisions
   `running-ng-<name>` and trusts the config author to make names unique per
   build, so the name must be injective in (compiler sha-or-version,
   configure_args).  Environmental inputs (dune, opam repo state) are
   deliberately absent; the agent's switch-provenance check catches their drift. *)
let args_slug args = "c" ^ String.sub (Digest.to_hex (Digest.string args)) 0 6

let runtime_name t =
  let label = Util.sanitize t.label in
  let base =
    match t.spec with
    | Version v ->
      let v = Util.sanitize v in
      if label = "" || label = v then "ocaml-" ^ v
      else "ocaml-" ^ label ^ "-" ^ v
    | Commit sha ->
      let s = Util.sanitize (sha_short sha) in
      if label = "" then "ocaml-" ^ s else "ocaml-" ^ label ^ "-" ^ s
  in
  if t.configure_args = "" then base
  else
    match t.flavor with
    | Some suffix -> base ^ "-" ^ suffix
    | None -> base ^ "-" ^ args_slug t.configure_args

let is_hex s =
  s <> ""
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
       s

let validate t =
  match t.spec with
  | Version "" -> Error "a variant has an empty version"
  | Commit sha when not (is_hex sha) ->
    Error
      (Printf.sprintf
         "`%s` is not a commit sha (expected hex). Resolve refs to a sha before \
          generating a config -- two runs labelled the same ref must be the \
          same commit."
         sha)
  | Commit sha when String.length sha < 7 ->
    Error (Printf.sprintf "commit sha `%s` is too short to be unambiguous" sha)
  | _ -> Ok ()

(* Emitted into the config's `runtimes:` block.  `version:` and `commit:` both
   resolve to a git ref in running-ng (version "5.5.0" builds the release tag,
   not the ocaml-base-compiler package). *)
let yaml_fields t =
  match t.spec with
  | Version v -> [ ("version", v) ]
  | Commit sha -> [ ("commit", sha) ]

let describe t =
  match t.spec with
  | Version v -> Printf.sprintf "version %s" v
  | Commit sha -> Printf.sprintf "commit %s" sha

let role_string = function Baseline -> "baseline" | Candidate -> "candidate"

let of_cli_string s =
  (* kind:label:value[:configure args], e.g. version:base:5.5.0 or
     commit:pr-1234:a1b2c3d... or commit:fp:a1b2c3d:--enable-frame-pointers.
     Everything after the third colon is the configure args, verbatim. *)
  match Util.split_on ~sep:':' s with
  | "version" :: label :: v :: args ->
    let configure_args = String.concat ":" args in
    Ok
      {
        label;
        spec = Version v;
        role = Candidate;
        repo = None;
        configure_args;
        flavor = suffix_of_args ~flavors:default_flavors configure_args;
      }
  | "commit" :: label :: sha :: args ->
    let configure_args = String.concat ":" args in
    Ok
      {
        label;
        spec = Commit sha;
        role = Candidate;
        repo = None;
        configure_args;
        flavor = suffix_of_args ~flavors:default_flavors configure_args;
      }
  | _ ->
    Error
      (Printf.sprintf
         "cannot parse variant %S; expected `version:<label>:<v>` or \
          `commit:<label>:<sha>` (optionally `:<configure args>`)"
         s)

let with_role role t = { t with role }
