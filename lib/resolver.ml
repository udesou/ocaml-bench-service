(* Turning what the user wrote into pinned runtimes.

   The full resolver is the server's one GitHub dependency: PR head, merge
   base, ref -> sha.  This module is the seam it plugs into, plus the OFFLINE
   rules that need no network at all: release versions and commit shas pass
   through, anything else is refused with instructions rather than guessed at.
   Swapping in the GitHub-backed resolver must not touch the server.

   Offline semantics of `vs=`, CLI submissions only:

   * the FIRST entry is the baseline, the rest are candidates -- there is no
     merge base to default to without a PR;
   * `5.4.1`-shaped entries become `version:` pins (running-ng builds the
     release tag); >= 7 hex characters become `commit:` pins;
   * a ref like `trunk` is refused: two runs labelled "trunk" must be the same
     commit or they are not comparable, and only the GitHub resolver can make
     that guarantee.

   PR-comment submissions always need GitHub (the candidate is the PR head,
   the default baseline its merge base), so the offline resolver refuses them
   whole. *)

type t = {
  variants :
    origin:Api.origin -> vs:string list -> (Variant.t list, Api.error) result;
}

let err fmt = Api.error Api.Bad_command fmt

let looks_like_version s =
  s <> ""
  && String.for_all (function '0' .. '9' | '.' -> true | _ -> false) s
  && String.contains s '.'
  && s.[0] <> '.'
  && s.[String.length s - 1] <> '.'

let is_hex s =
  s <> ""
  && String.for_all
       (function '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
       s

let offline_variant entry =
  if looks_like_version entry then
    Ok
      {
        Variant.label = "";
        spec = Variant.Version entry;
        role = Variant.Candidate;
        repo = None;
        configure_args = "";
        flavor = None;
      }
  else if is_hex entry && String.length entry >= 7 then
    Ok
      {
        Variant.label = "";
        spec = Variant.Commit (String.lowercase_ascii entry);
        role = Variant.Candidate;
        repo = None;
        configure_args = "";
        flavor = None;
      }
  else
    err
      "Cannot resolve `%s` without GitHub access, which this server does not \
       have yet. Give a release version (`5.4.1`) or a commit sha -- two runs \
       labelled `%s` must be the same commit or they are not comparable."
      entry entry

let ( let* ) = Result.bind

(* `5.5.0+fp+flambda`: a vs= entry is a compiler spec plus build flavors.
   Parsed HERE, once for every resolver, so the compiler part travels on to
   version/sha/ref resolution unchanged.  The TABLE is policy and comes from
   the service config (Variant.default_flavors when it says nothing); the
   flavors become configure_args and a name suffix in the table's canonical
   order, so `+flambda+fp` and `+fp+flambda` are the same build with the
   same runtime name. *)
let split_flavors ~flavors entry =
  match Util.split_on ~sep:'+' entry with
  | [] | [ _ ] -> Ok (entry, None)
  | base :: fs -> (
    let names = List.map fst flavors in
    match List.find_opt (fun f -> not (List.mem_assoc f flavors)) fs with
    | Some u ->
      err "`%s` is not a build flavor.%s The flavors: %s." u
        (Util.suggest ~candidates:names u)
        (String.concat ", " names)
    | None -> Ok (base, Some (Variant.canonical_flavors ~flavors fs)))

let with_flavors ~flavors resolve entry =
  let* base, f = split_flavors ~flavors entry in
  let* v = resolve base in
  match f with
  | None -> Ok v
  | Some (suffix, configure_args) ->
    Ok { v with Variant.configure_args; flavor = Some suffix }

let cli_variants ~flavors ~resolve ~vs =
  let resolve = with_flavors ~flavors resolve in
  match vs with
  | [] ->
    err
      "A CLI submission has no pull request to take compilers from: name them \
       with `vs=`. The first is the baseline -- for example \
       `vs=5.4.1,c0f8c8ceef751fb3a99652d3d52399db3d1c2aae`."
  | baseline :: rest ->
    let* b = resolve baseline in
    let* cs =
      List.fold_left
        (fun acc e ->
          let* acc = acc in
          let* v = resolve e in
          Ok (acc @ [ v ]))
        (Ok []) rest
    in
    Ok (Variant.with_role Variant.Baseline b :: cs)

let offline_with ~flavors =
  {
    variants =
      (fun ~origin ~vs ->
        match origin.Api.kind with
        | Api.Pr_comment _ ->
          err
            "PR-triggered runs need the server's GitHub resolution (the PR \
             head and its merge base), which is not wired up yet. Use the CLI \
             with `vs=` for now."
        | Api.Cli -> cli_variants ~flavors ~resolve:offline_variant ~vs);
  }

let offline = offline_with ~flavors:Variant.default_flavors

(* --- the GitHub-backed resolver -------------------------------------------- *)

(* The server's whole GitHub dependency, and it is only `git`: refs, release
   tags and PR heads resolve with `ls-remote` (GitHub advertises
   refs/pull/N/head), and the merge-base baseline is computed in a local bare
   cache repo the resolver fetches into.  No API, no token -- public repos
   only, which is what this service measures.

   Names follow the document's example (`ocaml-pr-14796-e5f6a7b`): the label
   says what the user meant, the sha pins it, and the runtime name -- the
   compiler cache key -- carries both. *)

type github = {
  git : string;  (** the git binary *)
  compiler_repo : string;  (** clone URL that `vs=` entries resolve against *)
  url_of_repo : string -> string;
      (** pr_context.repo ("owner/name") -> clone URL; overridable in tests *)
  cache_dir : string;  (** bare repo used only for merge-base computation *)
  default_base : string;  (** branch a PR targets when the bot did not say *)
  flavors : (string * string) list;
      (** the build-flavor table (name -> configure args), from the service
          config; order is canonical *)
}

let github_defaults ~cache_dir =
  {
    git = "git";
    compiler_repo = "https://github.com/ocaml/ocaml";
    url_of_repo = (fun repo -> "https://github.com/" ^ repo);
    cache_dir;
    default_base = "trunk";
    flavors = Variant.default_flavors;
  }

let git_run ~git args =
  let cmd = Filename.quote_command git args ^ " 2>&1" in
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 1
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  let out = String.trim (Buffer.contents buf) in
  match status with
  | Unix.WEXITED 0 -> Ok out
  | _ -> Error out

let run_git (g : github) args = git_run ~git:g.git args

(* Pinning a LOCAL checkout: sources carry shas, never refs (§6.1 --
   everything resolved before dispatch), and the server resolves them from
   the checkouts it already reads for facts and validation, so no network is
   involved.  The clone URL comes from the checkout's own origin remote (the
   directory path stands in for dev checkouts without one). *)
let local_source ?(git = "git") ~name ~dir ~ref_ () =
  match git_run ~git [ "-C"; dir; "rev-parse"; ref_ ] with
  | Error out ->
    Api.internal
      ~detail:(Printf.sprintf "rev-parse %s in %s failed: %s" ref_ dir out)
      "The service could not pin its `%s` checkout to a commit." name
  | Ok commit ->
    let repo =
      match git_run ~git [ "-C"; dir; "remote"; "get-url"; "origin" ] with
      | Ok url when url <> "" -> url
      | _ -> dir
    in
    Ok (Runspec.source ~name ~repo ~commit ())

(* `git ls-remote <url> <ref>`: the sha in the first column, or None when the
   remote has no such ref.  A FAILURE (unreachable url, garbage output) is the
   SERVICE's problem, not the request's: git's stderr goes to the server log,
   the requester gets the incident id. *)
let ls_remote g ~url ~ref_ =
  match run_git g [ "ls-remote"; url; ref_ ] with
  | Error out ->
    Api.internal
      ~detail:
        (Printf.sprintf "git ls-remote %s %s failed: %s" url ref_
           (if out = "" then "(no output)" else out))
      "The service could not reach `%s` to resolve refs." url
  | Ok "" -> Ok None
  | Ok out -> (
    match Util.split_on ~sep:'\t' (List.hd (Util.split_on ~sep:'\n' out)) with
    | sha :: _ when is_hex sha && String.length sha >= 40 -> Ok (Some sha)
    | _ ->
      Api.internal
        ~detail:
          (Printf.sprintf "unexpected ls-remote output from %s for %s: %s" url
             ref_ out)
        "The service got an unexpected answer from `%s` while resolving refs."
        url)

let github_variant g entry =
  if is_hex entry && String.length entry >= 7 then
    Ok
      {
        Variant.label = "";
        spec = Variant.Commit (String.lowercase_ascii entry);
        role = Variant.Candidate;
        repo = Some g.compiler_repo;
        configure_args = "";
        flavor = None;
      }
  else
    let pinned sha =
      {
        Variant.label = entry;
        spec = Variant.Commit sha;
        role = Variant.Candidate;
        repo = Some g.compiler_repo;
        configure_args = "";
        flavor = None;
      }
    in
    if looks_like_version entry then
      (* the peeled ref (^{}) is the tagged commit; annotated tags need it *)
      let* peeled =
        ls_remote g ~url:g.compiler_repo ~ref_:("refs/tags/" ^ entry ^ "^{}")
      in
      let* sha =
        match peeled with
        | Some sha -> Ok (Some sha)
        | None -> ls_remote g ~url:g.compiler_repo ~ref_:("refs/tags/" ^ entry)
      in
      match sha with
      | Some sha -> Ok (pinned sha)
      | None ->
        err "`%s` is not a release tag of %s." entry g.compiler_repo
    else
      let* sha =
        ls_remote g ~url:g.compiler_repo ~ref_:("refs/heads/" ^ entry)
      in
      match sha with
      | Some sha -> Ok (pinned sha)
      | None ->
        err
          "`%s` is neither a release tag, a branch of %s, nor a commit sha."
          entry g.compiler_repo

let ensure_cache g =
  if Sys.file_exists (Filename.concat g.cache_dir "HEAD") then Ok ()
  else
    match run_git g [ "init"; "--quiet"; "--bare"; g.cache_dir ] with
    | Ok _ -> Ok ()
    | Error out ->
      Api.internal
        ~detail:
          (Printf.sprintf "git init --bare %s failed: %s" g.cache_dir out)
        "The service could not prepare its git cache."

(* The merge-base baseline: fetch the PR head and the base branch into the
   cache, then ask git.  This is the one place that needs commit OBJECTS
   rather than just ref tips. *)
let merge_base g ~url ~number ~base_ref ~head_sha =
  let* () = ensure_cache g in
  let gd = "--git-dir=" ^ g.cache_dir in
  let* _ =
    match
      run_git g
        [
          gd;
          "fetch";
          "--quiet";
          url;
          Printf.sprintf "+refs/heads/%s:refs/bench/base" base_ref;
          Printf.sprintf "+refs/pull/%d/head:refs/bench/pr" number;
        ]
    with
    | Ok _ -> Ok ""
    | Error out ->
      Api.internal
        ~detail:
          (Printf.sprintf "fetch of %s + refs/pull/%d/head from %s failed: %s"
             base_ref number url out)
        "The service could not fetch `%s` to compute the merge base. Give an \
         explicit baseline with `vs=` while this persists."
        base_ref
  in
  match run_git g [ gd; "merge-base"; "refs/bench/base"; head_sha ] with
  | Ok sha when is_hex sha -> Ok sha
  | Ok out | Error out ->
    Api.internal
      ~detail:
        (Printf.sprintf "merge-base %s %s in %s failed: %s" base_ref head_sha
           g.cache_dir out)
      "The service could not compute the merge base of `%s` and the PR head \
       `%s`. Give an explicit baseline with `vs=` while this persists."
      base_ref
      (String.sub head_sha 0 7)

let github g =
  {
    variants =
      (fun ~origin ~vs ->
        match origin.Api.kind with
        | Api.Cli -> cli_variants ~flavors:g.flavors ~resolve:(github_variant g) ~vs
        | Api.Pr_comment ctx ->
          let url = g.url_of_repo ctx.Api.repo in
          let* head_sha =
            match ctx.Api.head_sha with
            | Some sha when is_hex sha && String.length sha >= 7 ->
              Ok (String.lowercase_ascii sha)
            | _ -> (
              let* sha =
                ls_remote g ~url
                  ~ref_:(Printf.sprintf "refs/pull/%d/head" ctx.Api.number)
              in
              match sha with
              | Some sha -> Ok sha
              | None ->
                err "`%s` does not advertise a head for PR #%d." ctx.Api.repo
                  ctx.Api.number)
          in
          let head =
            {
              Variant.label = Printf.sprintf "pr-%d" ctx.Api.number;
              spec = Variant.Commit head_sha;
              role = Variant.Candidate;
              (* the head sha exists only on the PR's own repository *)
              repo = Some url;
              configure_args = "";
        flavor = None;
            }
          in
          if vs <> [] then
            (* vs= chooses the baseline; the PR head stays the first candidate *)
            let* resolved = cli_variants ~flavors:g.flavors ~resolve:(github_variant g) ~vs in
            match resolved with
            | baseline :: extras -> Ok (baseline :: head :: extras)
            | [] -> err "empty `vs=` resolution"
          else
            let base_ref =
              Option.value ctx.Api.base_ref ~default:g.default_base
            in
            let* mb =
              merge_base g ~url ~number:ctx.Api.number ~base_ref ~head_sha
            in
            Ok
              [
                {
                  Variant.label = "base";
                  spec = Variant.Commit mb;
                  role = Variant.Baseline;
                  (* the merge base is an ancestor of the PR head, so the
                     PR's repository is guaranteed to serve it *)
                  repo = Some url;
                  configure_args = "";
        flavor = None;
                };
                head;
              ]);
  }
