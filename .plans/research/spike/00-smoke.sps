(import (rnrs) (libuv) (only (chezscheme) threaded? machine-type))
(display (list 'libuv (uv-version) 'threaded (threaded?) 'machine (machine-type)))
(newline)
