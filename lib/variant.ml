(* A runtime to measure: one side of the comparison.

   Resolution (a ref like "trunk" -> a sha) happens upstream of the generator,
   in the server, because it needs the network and a git remote.  By the time a
   variant reaches here it is already pinned -- which is what makes two runs
   labelled "trunk" comparable, and what makes this module pure. *)

type spec = Version of string | Commit of string

type role = Baseline | Candidate

type t = {
  label : string;
  spec : spec;
  role : role;
  repo : string option;
      (* clone URL the sha is fetched from, when it is not the default
         compiler repo -- a fork PR's head sha exists ONLY on the fork, so
         building it from ocaml/ocaml would fail.  Not part of the runtime
         NAME: a sha is globally unique, so identity is unaffected. *)
  configure_args : string;
      (* e.g. "--enable-frame-pointers --enable-flambda", whitespace-separated
         (the runtime_pin's field).  Part of the requested build identity: it
         goes into the runtime NAME (see runtime_name) and into the generated
         config's `configure_args:` list, which running-ng passes to
         `opam compiler create --configure-command`.  Produced by the
         grammar's `+<flavor>` suffixes on vs= entries and by bench-gen's
         --variant 4th field. *)
  flavor : string option;
      (* the human suffix for the runtime name when configure_args came from
         named flavors, e.g. "fp-flambda".  Set by whoever resolved the
         flavors (the policy owner: the resolver, from the service config's
         flavor table); None means arbitrary args, which get the digest.
         Whoever sets it owes the injectivity of (suffix <-> args), which the
         flavor table's validation guarantees. *)
}

(* The default flavor table: name -> configure args.  A FLAVOR is a named,
   allowlisted build variant; the grammar's `+fp` / `+flambda` suffixes on
   `vs=` entries (`vs=5.5.0,5.5.0+fp,5.5.0+fp+flambda`).  The deployed table
   lives in service.json (`flavors`, defaulting to this one) so adding a
   variant is a config edit; the LIST ORDER is the canonical order, so a
   flavor set maps 1:1 onto a configure_args string and a name suffix
   regardless of how the user ordered the suffixes -- which keeps
   runtime_name injective and matches the switch naming convention already
   in use on the bench machines (running-ng-ocaml-5.5.0-fp-flambda). *)
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

(* The runtime name is the compiler cache key: running-ng provisions the switch
   `running-ng-<runtime name>` and treats it as the cache -- and, per its own
   comment, TRUSTS the config author to make names unique per distinct build.
   The server is the config author, so the name must be an injective function
   of the requested identity: (compiler sha-or-version, configure_args).  The
   sha keeps same-commit requests sharing one switch; the args digest keeps
   two configurations of one commit from thrashing each other's.

   Environmental build inputs (running-ng's pinned dune, the opam repo state)
   are deliberately NOT in the name: nobody can request them, they just drift
   underneath it -- the agent's switch-provenance sidecar catches that and
   rebuilds in place (§6.3). *)
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
   resolve to a git ref in running-ng (version "5.5.0" builds from the release
   tag, not the ocaml-base-compiler package), so a released baseline and a PR
   head are provisioned the same way. *)
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
