#!r6rs
;;; A malformed setting raised out of `serve` through a guard whose clause
;;; does not match it, then caught by one that reports what arrived.  On
;;; chez-libuv v0.8.0 it arrived as &uv-handle-closed; on v0.9.0 it arrives
;;; as &http-server-config-error (chez-libuv #120, 2026-10-11).
;;;
;;;   CHEZSCHEMELIBDIRS=<make build's library path> chez --program serve-raise-through-guard.sps
(import (rnrs) (http-server) (only (libuv) uv-handle-closed?))
(display
 (guard (e ((http-server-config-error? e) "arrived: &http-server-config-error")
           ((uv-handle-closed? e) "arrived: &uv-handle-closed")
           (#t "arrived: something else"))
   (guard (e ((string? e) "inner guard matched"))
     (serve (lambda (req) #f)
            (lambda (name) (and (string=? name "CHEZ_HTTP_PORT") "not-a-port"))))))
(newline)
