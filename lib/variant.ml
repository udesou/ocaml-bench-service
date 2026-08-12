(* A runtime to measure: one side of the comparison.

   Resolution (a ref like "trunk" -> a sha) happens upstream of the generator,
   in the server, because it needs the network and a git remote.  By the time a
   variant reaches here it is already pinned -- which is what makes two runs
   labelled "trunk" comparable, and what makes this module pure. *)

type spec = Version of string | Commit of string

type role = Baseline | Candidate

type t = { label : string; spec : spec; role : role }

let sha_short sha =
  let n = String.length sha in
  if n <= 7 then sha else String.sub sha 0 7

(* The runtime name is the compiler cache key: running-ng provisions the switch
   `running-ng-<runtime name>` and treats it as the cache.  Encoding the sha
   here is what makes a second request against the same commit reuse the switch
   instead of rebuilding for 10-20 minutes.  (Sufficient reuse also needs the
   provenance check in the design doc section 7 -- the sha alone does not
   capture configure_args or the dune pin.) *)
let runtime_name t =
  let label = Util.sanitize t.label in
  match t.spec with
  | Version v ->
    let v = Util.sanitize v in
    if label = "" || label = v then "ocaml-" ^ v else "ocaml-" ^ label ^ "-" ^ v
  | Commit sha ->
    let s = Util.sanitize (sha_short sha) in
    if label = "" then "ocaml-" ^ s else "ocaml-" ^ label ^ "-" ^ s

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
  (* kind:label:value, e.g. version:base:5.5.0 or commit:pr-1234:a1b2c3d... *)
  match Util.split_on ~sep:':' s with
  | [ "version"; label; v ] ->
    Ok { label; spec = Version v; role = Candidate }
  | [ "commit"; label; sha ] ->
    Ok { label; spec = Commit sha; role = Candidate }
  | _ ->
    Error
      (Printf.sprintf
         "cannot parse variant %S; expected `version:<label>:<v>` or \
          `commit:<label>:<sha>`"
         s)

let with_role role t = { t with role }
