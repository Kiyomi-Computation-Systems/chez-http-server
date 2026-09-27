# chez-http-server — canonical entry points.
#
# Dependencies are pinned git submodules under vendor/ (global-constraints):
# chez-libuv, chez-httparse, uriparse, and chez-srfi for the SRFI-64 test
# framework; byte-machine arrives transitively under chez-httparse.  The
# *_PIN lines below name each commit and its tag.  `make build` assembles them
# onto one library path.  A pin is
# a gitlink; `make check-pins` is the fingerprint check the brief's M0 asks for.
# It also holds uriparse to the byte-machine on the library path, and refuses a
# vendored checkout with local edits.

CHEZ ?= chez

# --- pinned dependencies -----------------------------------------------------
LIBUV_DIR        := vendor/chez-libuv
HTTPARSE_DIR     := vendor/chez-httparse
URIPARSE_DIR     := vendor/uriparse
SRFI_DIR         := vendor/chez-srfi
BYTE_MACHINE_DIR := $(HTTPARSE_DIR)/vendor/byte-machine

LIBUV_PIN        := ed302067e6c7367d24e8bc75f4f9dcf8fa8f7ea1  # v0.7.0
HTTPARSE_PIN     := bdcdfe2b0d27285e574010199979e8be3867660e  # v0.4.3
URIPARSE_PIN     := 88d538f461fc2ee94a86f323bf796ece7ebc0db5  # v0.6.1
SRFI_PIN         := 7879b527f267f067416552fb989135ad1b4ea436
BYTE_MACHINE_PIN := 5c1cb7ea8679df48d4e1c4da34b3dadf50f24922  # v0.6.1

# --- one library path --------------------------------------------------------
# chez-libuv locates its C shim by an absolute path baked into a generated
# config.sls at *its* build time, so only its src/ is needed here for imports.
# byte-machine comes from chez-httparse's vendored copy (uriparse pins the same
# commit, so a second copy is redundant; check-pins holds uriparse to it).
# `tests` carries the (testing) bridge
# and build/scheme-libs carries (srfi :64).
#
# The chez-httparse corpus harness ((httparse test ...)) lives under its
# test/support/harness, NOT its src/, so it is a separate, test-only path (M1.1,
# design §3.2).  So is chez-libuv's tests/, for (uv-testing): the socket lane's
# iteration-capped waits and loopback plumbing (design §8.5, M4.2).
# check-imports keeps both out of src/, so nothing shipped can reach them.
BUILD_DIR := build
SRFI_LIBS := $(BUILD_DIR)/scheme-libs
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
LIBDIR_LIST := src tests \
  $(LIBUV_DIR)/src \
  $(HTTPARSE_DIR)/src $(BYTE_MACHINE_DIR)/src \
  $(URIPARSE_DIR)/src \
  $(SRFI_LIBS) \
  $(HTTPARSE_DIR)/test/support/harness \
  $(LIBUV_DIR)/tests
LIBDIRS := $(subst $(SPACE),:,$(strip $(LIBDIR_LIST)))

# Each tests/test-*.sps is its own process with its own (exit ...) status.
TESTS := $(wildcard tests/test-*.sps)

# timeout(1) is GNU coreutils; macOS installs it as gtimeout. Absent both, a
# hung suite is not capped but the run is otherwise identical.
TIMEOUT_BIN := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
SUITE_TIMEOUT ?= 120

.PHONY: help check-help submodules deps build dev run test check-pins check-imports check-close-ownership prod clean corpus-refresh
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
	nested=$$(git -C $(URIPARSE_DIR) rev-parse HEAD:vendor/byte-machine 2>/dev/null); \
	if [ "$$nested" != "$(strip $(BYTE_MACHINE_PIN))" ]; then \
	  echo "PIN MISMATCH: $(URIPARSE_DIR) was released with byte-machine $${nested:-<absent>}, the library path carries $(strip $(BYTE_MACHINE_PIN))" >&2; fail=1; \
	else echo "pin ok: $(URIPARSE_DIR) was released with byte-machine $$nested"; fi; \
	for d in $(LIBUV_DIR) $(HTTPARSE_DIR) $(URIPARSE_DIR) $(SRFI_DIR) $(BYTE_MACHINE_DIR); do \
	  if [ -n "$$(git -C $$d status --porcelain --untracked-files=no 2>/dev/null)" ]; then \
	    echo "PIN DIRTY: $$d has local edits to tracked files" >&2; fail=1; fi; \
	done; \
	exit $$fail

# The pure connection libraries under src/http-server/ (outside private/) must
# not reach the impure world: (libuv ...) and (chezscheme) live only in
# private/, the tests and this Makefile (global-constraints).  The facade,
# src/http-server.sls, reaches them only through private/ (design §3.1).  A
# check, not a comment: add such an import to either and this target reddens.
# Nothing under src/ imports a (libuv private ...) library either: the shell
# uses chez-libuv's public verbs, and a private reach is a workaround, carried
# only until its upstream ask lands (decision 0008), as chez-libuv #28's was.
check-imports: ## Assert pure libraries import no (libuv)/(chezscheme), and src/ no test or chez-libuv private library
	@hits=$$(grep -REn '\((chezscheme|libuv)( |\))' src/http-server src/http-server.sls --include='*.sls' 2>/dev/null | grep -v '/private/' || true); \
	if [ -n "$$hits" ]; then \
	  echo "IMPURE IMPORT outside src/http-server/private/:" >&2; echo "$$hits" >&2; exit 1; \
	fi; \
	tests=$$(grep -REn '\((uv-testing|httparse test)( |\))' src --include='*.sls' 2>/dev/null || true); \
	if [ -n "$$tests" ]; then \
	  echo "TEST-ONLY IMPORT in a shipped library:" >&2; echo "$$tests" >&2; exit 1; \
	fi; \
	private=$$(grep -REn '\(libuv private ' src --include='*.sls' 2>/dev/null || true); \
	if [ -n "$$private" ]; then \
	  echo "CHEZ-LIBUV PRIVATE IMPORT in a shipped library:" >&2; echo "$$private" >&2; exit 1; \
	fi; \
	echo "import audit ok: no (libuv)/(chezscheme) outside src/http-server/private/, the facade's included; no test library and no chez-libuv private library in src/"

# One procedure closes every handle: handle-close!, the one use of uv-close!
# in src/ (design §5.3 and §7.6, decision 0003).  chez-libuv keeps the
# callback of a handle's first close alone, so a close from anywhere else
# could run first and leave the shell's own callback never run.  The check is
# a suite, tests/test-close-ownership.sps, which `make test` runs with the
# others: it reads the source with Chez's own reader, so a string, a comment
# or two uses side by side cannot hide one.  This target runs it alone.
check-close-ownership: build ## Check handle-close! is the one uv-close! use in src/
	CHEZSCHEMELIBDIRS=$(LIBDIRS) $(CHEZ) --program tests/test-close-ownership.sps

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

run: build ## Run a program on the library path: make run PROGRAM=hello.sps
	@test -n "$(PROGRAM)" || { echo "run: set PROGRAM=path/to/program.sps" >&2; exit 2; }
	CHEZSCHEMELIBDIRS=$(LIBDIRS) $(CHEZ) --program $(PROGRAM)

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

# The vendored libhtp corpus is upstream's bytes and is never hand-edited
# (decision 0007). The initial vendor and every refresh run this one recipe, so
# a refresh cannot drift from however the first copy was made; the source
# checkout is named here, never committed. tests/test-libhtp.sps re-checksums
# every file on each run, so a stale or corrupt vendor is a status-3 failure.
corpus-refresh: ## Re-vendor the libhtp .t corpus (needs LIBHTP_ROOT=/path/to/libhtp)
	@test -n "$(LIBHTP_ROOT)" || { echo "corpus-refresh: set LIBHTP_ROOT=/path/to/a/libhtp/checkout" >&2; exit 2; }
	@test -f "$(LIBHTP_ROOT)/LICENSE" && test -d "$(LIBHTP_ROOT)/test/files" || { echo "corpus-refresh: LIBHTP_ROOT has no LICENSE or test/files" >&2; exit 2; }
	@dst=test/vendor/libhtp; \
	sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$1"; else shasum -a 256 "$$1"; fi | awk '{print $$1}'; }; \
	rm -rf "$$dst/files"; mkdir -p "$$dst/files"; \
	cp "$(LIBHTP_ROOT)/LICENSE" "$$dst/LICENSE"; \
	cp "$(LIBHTP_ROOT)"/test/files/*.t "$$dst/files/"; \
	printf '%s\n' '# Vendored corpus: exact upstream bytes, verified by sha256 (decision 0007).' '# Never normalize line endings, or the checksums break on a fresh checkout.' '* -text' > "$$dst/.gitattributes"; \
	commit=$$(git -C "$(LIBHTP_ROOT)" rev-parse HEAD); \
	count=$$(ls -1 "$$dst/LICENSE" "$$dst"/files/*.t | wc -l | tr -d ' '); \
	{ echo "# PROVENANCE -- the vendored libhtp connection-stream corpus (decision 0007)."; \
	  echo "#"; \
	  echo "# Upstream's bytes, verbatim and never hand-edited: a stream we believe is"; \
	  echo "# wrong becomes an expectation and a decision record, never a change to these"; \
	  echo "# bytes. Every file is checksummed below and verified by tests/test-libhtp.sps"; \
	  echo "# on every run, so drift or corruption is a status-3 failure, not a discovery."; \
	  echo "# Rewritten only by 'make corpus-refresh LIBHTP_ROOT=<checkout>'."; \
	  echo "#"; \
	  echo "# libhtp is BSD-3-Clause (LICENSE beside this file). This is test data; it is"; \
	  echo "# not part of the distributed library."; \
	  echo "upstream-url: https://github.com/OISF/libhtp"; \
	  echo "upstream-ref: 0.5.x"; \
	  echo "upstream-commit: $$commit"; \
	  echo "retrieved: $$(date -u +%Y-%m-%d)"; \
	  echo "file-count: $$count"; \
	  echo ""; \
	  ( cd "$$dst" && for f in LICENSE files/*.t; do echo "sha256 $$(sha "$$f") $$f"; done ); \
	} > "$$dst/PROVENANCE"; \
	echo "corpus-refresh: vendored $$count files at $$commit into $$dst"
