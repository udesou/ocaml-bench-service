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
  configure_args : string;
      (* e.g. "--enable-flambda" (§5.3 runtime_pin).  Part of the run's
         identity and of switch provenance, but NOT of the runtime name: the
         name encodes only the sha, and the runner's provenance record is what
         distinguishes two builds of the same sha.  Question raised on the
         document: no grammar key produces this yet, and how it reaches
         running-ng's provisioning is unspecified -- so it travels in the run
         spec and stays out of the generated config. *)
}

let sha_short sha =
  let n = String.length sha in
  if n <= 7 then sha else String.sub sha 0 7

(* The runtime name is the compiler cache key: running-ng provisions the switch
   `running-ng-<runtime name>` and treats it as the cache.  Encoding the sha
   here is what makes a second request against the same commit reuse the switch
   instead of rebuilding for 10-20 minutes.

   The sha alone is NOT sufficient to justify reuse: nothing in a switch records
   what built it, so the same commit under different configure_args, a different
   pinned dune, or a shifted opam repo gives a differently-built compiler under
   the same name.  The runner records that provenance separately and reuses only
   on an exact match. *)
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
  (* kind:label:value[:configure args], e.g. version:base:5.5.0 or
     commit:pr-1234:a1b2c3d... or commit:fp:a1b2c3d:--enable-frame-pointers.
     Everything after the third colon is the configure args, verbatim. *)
  match Util.split_on ~sep:':' s with
  | "version" :: label :: v :: args ->
    Ok
      {
        label;
        spec = Version v;
        role = Candidate;
        configure_args = String.concat ":" args;
      }
  | "commit" :: label :: sha :: args ->
    Ok
      {
        label;
        spec = Commit sha;
        role = Candidate;
        configure_args = String.concat ":" args;
      }
  | _ ->
    Error
      (Printf.sprintf
         "cannot parse variant %S; expected `version:<label>:<v>` or \
          `commit:<label>:<sha>` (optionally `:<configure args>`)"
         s)

let with_role role t = { t with role }
