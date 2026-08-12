(* Small helpers.  Deliberately dependency-free: the service builds in the
   ocaml-bench-dashboard switch, and we don't add packages to a switch someone
   else owns. *)

let split_on ~sep s = String.split_on_char sep s

let trim = String.trim

let is_space = function ' ' | '\t' | '\r' | '\n' -> true | _ -> false

(* Whitespace tokenisation.  A comment is user input, so runs of spaces,
   tabs and stray \r (GitHub sends CRLF) all have to collapse. *)
let tokens s =
  let out = ref [] and buf = Buffer.create 16 in
  let flush () =
    if Buffer.length buf > 0 then begin
      out := Buffer.contents buf :: !out;
      Buffer.clear buf
    end
  in
  String.iter (fun c -> if is_space c then flush () else Buffer.add_char buf c) s;
  flush ();
  List.rev !out

let contains ~needle s =
  let nl = String.length needle and hl = String.length s in
  let rec go i = i + nl <= hl && (String.sub s i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* Split "k=v" at the FIRST '=' only: sweep values can't contain '=', but
   being lenient here keeps error messages about the value rather than the
   shape. *)
let split_kv s =
  match String.index_opt s '=' with
  | None -> None
  | Some i ->
    Some (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))

let comma_list s =
  split_on ~sep:',' s |> List.map trim |> List.filter (fun x -> x <> "")

let levenshtein a b =
  let la = String.length a and lb = String.length b in
  if la = 0 then lb
  else if lb = 0 then la
  else begin
    let prev = Array.init (lb + 1) (fun j -> j) in
    let cur = Array.make (lb + 1) 0 in
    for i = 1 to la do
      cur.(0) <- i;
      for j = 1 to lb do
        let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
        cur.(j) <-
          min (min (cur.(j - 1) + 1) (prev.(j) + 1)) (prev.(j - 1) + cost)
      done;
      Array.blit cur 0 prev 0 (lb + 1)
    done;
    prev.(lb)
  end

(* "Did you mean" only fires when it is likely to be right: a typo, not a
   different word.  A wrong suggestion is worse than none in a PR comment --
   short words are the trap ("wat" is within 2 edits of "tag" but means nothing
   like it), so they get a tighter budget. *)
let did_you_mean ~candidates word =
  let budget = if String.length word <= 4 then 1 else 2 in
  let scored =
    (* Never suggest the word back at the user: that happens when the name is
       spelled correctly but is unavailable for some other reason, and
       "Did you mean `small`?" after typing `small` reads as a bug. *)
    List.filter (fun c -> c <> word) candidates
    |> List.map (fun c -> (levenshtein word c, c))
    |> List.sort compare
  in
  match scored with (d, c) :: _ when d <= budget -> Some c | _ -> None

let suggest ~candidates word =
  match did_you_mean ~candidates word with
  | Some c -> Printf.sprintf " Did you mean `%s`?" c
  | None -> ""

let is_int s =
  s <> ""
  && String.for_all (fun c -> c >= '0' && c <= '9') s

(* Anything that reaches an opam switch name (running-ng-<runtime name>) or a
   filename.  opam accepts letters, digits, '-', '_' and '.'. *)
let sanitize s =
  String.map
    (fun c ->
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> c
      | _ -> '-')
    s

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let write_file path contents =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      output_string oc contents)
