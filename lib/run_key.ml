(* The run key: the content identity of a measurement.  A request whose key
   matches a completed stored run is answered from the store, so the key hashes
   everything that could change the numbers (running-ng X.Y, machine name and
   fingerprint).  The encoding mirrors the contract's config_id recipe: a
   delimiter-joined string, so any producer computes the same digest. *)

type runtime = {
  name : string;  (** the running-ng runtime name (encodes the sha) *)
  pin : string;  (** the resolved commit sha, or the release version *)
  configure_args : string;
}

type t = {
  runtimes : runtime list;
  family : Api.family;
  tags : string list;  (** resolved running-ng tags (union) *)
  invocations : int;
  sweeps : (string * string list) list;
  benches_commit : string;  (** macro-benches (or benches) sha *)
  running_ng_xy : string;  (** running-ng version truncated to X.Y *)
  contract_version : string;  (** the contract's schema_version *)
  tool_versions : (string * string) list;  (** olly, perf *)
  machine : string;
  env_fingerprint : string;  (** digest of kernel, CPU model, governor *)
}

(* "vX.Y.Z" | "X.Y.Z" | "X.Y" -> "X.Y"; anything else is kept whole. *)
let version_xy v =
  let v' =
    if String.length v > 0 && (v.[0] = 'v' || v.[0] = 'V') then
      String.sub v 1 (String.length v - 1)
    else v
  in
  match Util.split_on ~sep:'.' v' with
  | x :: y :: _ when Util.is_int x && Util.is_int y -> x ^ "." ^ y
  | _ -> v

(* Field separator / list separator, same characters as the contract's
   config_id recipe (vocab.json). *)
let fs = "\x1f"
let ls = ","

let canonical t =
  let runtime r = String.concat ":" [ r.name; r.pin; r.configure_args ] in
  let sweep (dim, values) = dim ^ ":" ^ String.concat ";" values in
  let tool (name, v) = name ^ ":" ^ v in
  let sorted_by f l = List.sort (fun a b -> compare (f a) (f b)) l in
  String.concat fs
    [
      String.concat ls
        (List.map runtime (sorted_by (fun r -> r.name) t.runtimes));
      Api.string_of_family t.family;
      (* Sorted: the union is order-independent, so the key must be too. *)
      String.concat ls (List.sort compare t.tags);
      string_of_int t.invocations;
      String.concat ls (List.map sweep (sorted_by fst t.sweeps));
      t.benches_commit;
      version_xy t.running_ng_xy;
      t.contract_version;
      String.concat ls (List.map tool (sorted_by fst t.tool_versions));
      t.machine;
      t.env_fingerprint;
    ]

(* The "rk_" prefix follows the contract's "cfg_" convention: a key is
   recognisable in a log without context. *)
let compute t = "rk_" ^ Digest.to_hex (Digest.string (canonical t))
