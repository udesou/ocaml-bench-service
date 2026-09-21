(* Who may trigger a run, and as what role.  Triggering runs arbitrary PR code
   for an hour of machine time, so the gate is an explicit allowlist, not
   `author_association`.  Admins may additionally use `force=true` and
   `priority=top`.  `allow_associations` (["OWNER"]) is an escape hatch, empty
   by default. *)

type decision =
  | Allowed of Api.auth * string (* why *)
  | Denied of string (* message, postable verbatim *)

let check (cfg : Service_config.t) ~login ~association =
  let login_lc = String.lowercase_ascii (String.trim login) in
  let auth role = { Api.login = login_lc; role } in
  if login_lc = "" then Denied "Could not determine who sent this command."
  else if List.mem login_lc cfg.admins then Allowed (auth Api.Admin, "admin")
  else if List.mem login_lc cfg.allowlist then
    Allowed (auth Api.User, "allowlisted login")
  else
    match association with
    | Some a when List.mem a cfg.allow_associations ->
      Allowed (auth Api.User, Printf.sprintf "author_association=%s" a)
    | _ ->
      Denied
        (Printf.sprintf
           "Sorry @%s -- benchmark runs take about an hour of exclusive machine \
            time, so only a few people can start one for now. Ask a maintainer \
            to add you to the allowlist."
           login)

let allowed = function Allowed _ -> true | Denied _ -> false

let message = function Allowed (_, why) -> why | Denied m -> m

let auth = function Allowed (a, _) -> Some a | Denied _ -> None

(* The admin-only grammar keys are parsed for everyone and refused here, where
   the role is known, before any generation work. *)
let vet_request (auth : Api.auth) (r : Request.t) : (unit, Api.error) result =
  match auth.role with
  | Api.Admin -> Ok ()
  | Api.User ->
    if r.force then
      Api.error Api.Forbidden
        "`force=true` runs past the cost limit and is admin-only. Shrink the \
         request instead (lower `invocations=`, a smaller `tag=`, fewer sweep \
         values), or ask an admin to force it."
    else if r.priority <> None then
      Api.error Api.Forbidden
        "`priority=` is admin-only; requests are otherwise served in order. \
         Drop it and your run will be queued normally."
    else Ok ()
