(import (rnrs) (only (libuv) make-uv-loop uv-loop-close! uv-version) (only (libuv private native) uv-handle-size uv-req-size) (only (libuv private constants) uv-timer-type uv-tcp-type uv-write-req-type) (only (chezscheme) printf))
(define loop (make-uv-loop))
(printf "uv_handle_size(UV_TIMER)=~a uv_handle_size(UV_TCP)=~a uv_req_size(UV_WRITE)=~a libuv=~a\n"
        (uv-handle-size (uv-timer-type)) (uv-handle-size (uv-tcp-type)) (uv-req-size (uv-write-req-type)) (uv-version))
(uv-loop-close! loop)
