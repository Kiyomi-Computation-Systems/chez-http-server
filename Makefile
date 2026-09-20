# chez-http-server — canonical entry points.
#
# Dependencies are pinned git submodules under vendor/ (global-constraints):
# chez-libuv v0.6.0, chez-httparse v0.4.0, uriparse v0.4.0, and chez-srfi for
# the SRFI-64 test framework; byte-machine v0.6.0 arrives transitively under
# chez-httparse.  `make build` assembles them onto one library path.  A pin is
# a gitlink; `make check-pins` is the fingerprint check the brief's M0 asks for.

CHEZ ?= chez

# --- pinned dependencies -----------------------------------------------------
LIBUV_DIR        := vendor/chez-libuv
HTTPARSE_DIR     := vendor/chez-httparse
URIPARSE_DIR     := vendor/uriparse
SRFI_DIR         := vendor/chez-srfi
BYTE_MACHINE_DIR := $(HTTPARSE_DIR)/vendor/byte-machine

LIBUV_PIN        := ad4c1e9d9f01a54ef9301144c9af94302cf2e5b4  # v0.6.0
HTTPARSE_PIN     := 1cddba8214227645f5ca831bb055f49818bdfc3a  # v0.4.0
URIPARSE_PIN     := 611b04b5a5a8eba68c4a964db613e6b89bdd1981  # v0.4.0
SRFI_PIN         := 7879b527f267f067416552fb989135ad1b4ea436
BYTE_MACHINE_PIN := 0245db3059504c462b881a550310300fece55216  # v0.6.0

# --- one library path --------------------------------------------------------
# chez-libuv locates its C shim by an absolute path baked into a generated
# config.sls at *its* build time, so only its src/ is needed here for imports.
# byte-machine comes from chez-httparse's vendored copy (uriparse pins the same
# commit, so a second copy is redundant).  `tests` carries the (testing) bridge
# and build/scheme-libs carries (srfi :64).
#
# The chez-httparse corpus harness ((httparse test ...)) lives under its
# test/support/harness, NOT its src/, so it is a separate, test-only path (M1.1,
# design §3.2).  check-imports keeps it out of the pure libraries under
# src/http-server/, so nothing shipped can reach it.
BUILD_DIR := build
SRFI_LIBS := $(BUILD_DIR)/scheme-libs
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
LIBDIR_LIST := src tests \
  $(LIBUV_DIR)/src \
  $(HTTPARSE_DIR)/src $(BYTE_MACHINE_DIR)/src \
  $(URIPARSE_DIR)/src \
  $(SRFI_LIBS) \
  $(HTTPARSE_DIR)/test/support/harness
LIBDIRS := $(subst $(SPACE),:,$(strip $(LIBDIR_LIST)))

# Each tests/test-*.sps is its own process with its own (exit ...) status.
TESTS := $(wildcard tests/test-*.sps)

# timeout(1) is GNU coreutils; macOS installs it as gtimeout. Absent both, a
# hung suite is not capped but the run is otherwise identical.
TIMEOUT_BIN := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
SUITE_TIMEOUT ?= 120

.PHONY: help check-help submodules deps build dev test check-pins check-imports prod clean
.DEFAULT_GOAL := help

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_.-]+:.*?## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

check-help: ## Fail if any .PHONY target is undocumented in `make help`
	@missing=0; \
	targets=$$(awk '/^\.PHONY:/ { $$1=""; print }' Makefile); \
	for t in $$targets; do \
	  grep -qE "^$$t:.*## " Makefile || { echo "check-help: '$$t' has no '## ' description" >&2; missing=1; }; \
	done; \
	exit $$missing

submodules: ## Init the pinned dependency submodules (top-level + byte-machine)
	git submodule update --init $(LIBUV_DIR) $(URIPARSE_DIR) $(SRFI_DIR)
	git submodule update --init --recursive $(HTTPARSE_DIR)

check-pins: ## Verify each submodule sits at its pinned commit (fingerprint check)
	@fail=0; \
	check_pin() { \
	  got=$$(git -C "$$1" rev-parse HEAD 2>/dev/null); \
	  if [ "$$got" != "$$2" ]; then \
	    echo "PIN MISMATCH: $$1 at $${got:-<absent>}, expected $$2" >&2; fail=1; \
	  else echo "pin ok: $$1 $$2"; fi; }; \
	check_pin $(LIBUV_DIR) $(LIBUV_PIN); \
	check_pin $(HTTPARSE_DIR) $(HTTPARSE_PIN); \
	check_pin $(URIPARSE_DIR) $(URIPARSE_PIN); \
	check_pin $(SRFI_DIR) $(SRFI_PIN); \
	check_pin $(BYTE_MACHINE_DIR) $(BYTE_MACHINE_PIN); \
	exit $$fail

# The pure connection libraries under src/http-server/ (outside private/) must
# not reach the impure world: (libuv ...) and (chezscheme) live only in
# private/, the tests and this Makefile (global-constraints).  A check, not a
# comment: add such an import to a pure library and this target reddens.
check-imports: ## Assert pure libraries import no (libuv)/(chezscheme)
	@hits=$$(grep -REn '\((chezscheme|libuv)( |\))' src/http-server --include='*.sls' 2>/dev/null | grep -v '/private/' || true); \
	if [ -n "$$hits" ]; then \
	  echo "IMPURE IMPORT in a pure library:" >&2; echo "$$hits" >&2; exit 1; \
	fi; \
	echo "import audit ok: no (libuv)/(chezscheme) outside src/http-server/private/"

deps: submodules ## Build the chez-libuv shim and link SRFI-64 onto the path
	$(MAKE) -C $(LIBUV_DIR) build
	@mkdir -p $(SRFI_LIBS)/srfi
	@src=$(abspath $(SRFI_DIR)); dst=$(abspath $(SRFI_LIBS))/srfi; \
	for f in $$src/*; do \
	  b=$$(basename "$$f"); \
	  ln -sfn "$$f" "$$dst/$$b"; \
	  d=$$(printf '%s' "$$b" | sed 's/%3a/:/g'); \
	  [ "$$d" = "$$b" ] || ln -sfn "$$f" "$$dst/$$d"; \
	done

build: deps ## Build dependencies and assemble the one library path
	@echo "build: chez-libuv shim built; library path = $(LIBDIRS)"

dev: build ## Start a REPL with everything on the library path
	CHEZSCHEMELIBDIRS=$(LIBDIRS) $(CHEZ)

test: build check-pins check-imports ## Run every tests/test-*.sps (status 0/1/2/3, keep-going)
	@test -n "$(TESTS)" || { echo "test: empty selection — no tests/test-*.sps (failure)" >&2; exit 2; }
	@test -n "$(TIMEOUT_BIN)" || echo "note: no timeout(1) on PATH; a hung suite will not be capped"
	@fail=0; \
	for t in $(TESTS); do \
	  echo "=== $$t ==="; \
	  CHEZSCHEMELIBDIRS=$(LIBDIRS) $(TIMEOUT_BIN) $(if $(TIMEOUT_BIN),$(SUITE_TIMEOUT),) $(CHEZ) --program $$t; \
	  rc=$$?; \
	  if [ $$rc -eq 124 ] && [ -n "$(TIMEOUT_BIN)" ]; then \
	    echo "HUNG: $$t exceeded $(SUITE_TIMEOUT)s and was killed" >&2; fail=1; \
	  elif [ $$rc -ne 0 ]; then echo "suite $$t exited $$rc" >&2; fail=1; fi; \
	done; \
	if [ $$fail -eq 0 ]; then echo "ALL SUITES PASSED"; else echo "SUITE FAILED"; fi; \
	exit $$fail

prod: ## Rebuild the shim optimized (FLAVOR=prod), then run the suite
	$(MAKE) -C $(LIBUV_DIR) prod
	$(MAKE) test

clean: ## Remove our build artifacts and the vendored shim
	rm -rf $(BUILD_DIR)
	-$(MAKE) -C $(LIBUV_DIR) clean
