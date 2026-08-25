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
        configure_args = "";
      }
  else if is_hex entry && String.length entry >= 7 then
    Ok
      {
        Variant.label = "";
        spec = Variant.Commit (String.lowercase_ascii entry);
        role = Variant.Candidate;
        configure_args = "";
      }
  else
    err
      "Cannot resolve `%s` without GitHub access, which this server does not \
       have yet. Give a release version (`5.4.1`) or a commit sha -- two runs \
       labelled `%s` must be the same commit or they are not comparable."
      entry entry

let offline =
  {
    variants =
      (fun ~origin ~vs ->
        match origin.Api.kind with
        | Api.Pr_comment _ ->
          err
            "PR-triggered runs need the server's GitHub resolution (the PR \
             head and its merge base), which is not wired up yet. Use the CLI \
             with `vs=` for now."
        | Api.Cli -> (
          match vs with
          | [] ->
            err
              "A CLI submission has no pull request to take compilers from: \
               name them with `vs=`. The first is the baseline -- for example \
               `vs=5.4.1,c0f8c8ceef751fb3a99652d3d52399db3d1c2aae`."
          | baseline :: rest ->
            let ( let* ) = Result.bind in
            let* b = offline_variant baseline in
            let* cs =
              List.fold_left
                (fun acc e ->
                  let* acc = acc in
                  let* v = offline_variant e in
                  Ok (acc @ [ v ]))
                (Ok []) rest
            in
            Ok (Variant.with_role Variant.Baseline b :: cs)));
  }
