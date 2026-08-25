(lang dune 3.16)
(name ocaml-bench-service)
(generate_opam_files true)

(source
 (github udesou/ocaml-bench-service))
(license ISC)
(authors "Eduardo Souza")
(maintainers "eduardo@tarides.com")

(package
 (name ocaml-bench-service)
 ; Nothing is installable yet -- bench-gen is a development entry point, not a
 ; public binary.  The package exists so `opam install --deps-only .` can build
 ; the local switch from a committed dependency list.
 (allow_empty)
 (synopsis "Comment-triggered benchmarking service for OCaml compiler PRs")
 (description
  "Turns a /bench comment on a pull request into a validated running-ng run, \
   schedules it on a bench machine, and publishes contract artifacts plus a \
   report. See benchmarking-service-design.md.")
 (depends
  (ocaml (>= 5.2))
  (dune (>= 3.16))
  (yojson (>= 2.0))
  (capnp (>= 3.6))
  (capnp-rpc (>= 2.1))
  (capnp-rpc-unix (>= 2.1))
  eio_main
  logs
  fmt
  (mirage-crypto-rng (>= 1.2))))
