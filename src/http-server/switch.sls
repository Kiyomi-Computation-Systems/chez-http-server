#!r6rs
;;; (http-server switch) — what a handler answers to take an upgrade (pure).
;;;
;;; Decision 0016.  A handler takes a request that asks to switch protocols
;;; by answering `(switch-protocols headers take-over)` instead of a
;;; response.  The server writes `HTTP/1.1 101 Switching Protocols`, the
;;; handler's fields and `Connection: upgrade`, and once the 101 is written
;;; it calls `(take-over transport retained)`: the stream, as (http-server
;;; transport)'s record of verbs, and the bytes the client sent after the
;;; request that the server has already read.  Like a response, a switch is
;;; only a record: what the server cannot write safely is found when it is
;;; answered, and answered 500 (see (http-server serializer)'s
;;; switch-fault).  PURE: imports only (rnrs).
(library (http-server switch)
  (export switch-protocols switch? switch-headers switch-take-over)
  (import (rnrs))

  ;; switch-protocols : Headers (Transport Bytevector -> Any) -> Switch
  ;;   Headers = (Listof (Pair Bytevector Bytevector)) — the 101's fields, in
  ;;             wire order, its Upgrade among them; as a response's
  ;; switch? : Any -> Boolean
  ;; switch-headers : Switch -> Headers
  ;; switch-take-over : Switch -> (Transport Bytevector -> Any)
  (define-record-type (switch switch-protocols switch?)
    (fields (immutable headers   switch-headers)
            (immutable take-over switch-take-over))))
