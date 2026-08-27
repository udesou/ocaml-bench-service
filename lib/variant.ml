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
      (* e.g. "--enable-flambda --enable-frame-pointers" (§5.3 runtime_pin),
         whitespace-separated.  Part of the requested build identity: it goes
         into the runtime NAME (as a digest, see runtime_name) and into the
         generated config's `configure_args:` list, which running-ng passes to
         `opam compiler create --configure-command`.  No grammar key produces
         it yet (a raised doc question); the CLI's --variant 4th field does. *)
}

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
  else base ^ "-" ^ args_slug t.configure_args

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
