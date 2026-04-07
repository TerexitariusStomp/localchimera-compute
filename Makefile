all: browser/repl.wasm weave/weave.wasm

CHANNELS = deploy/guix/channels.scm
TIME_MACHINE = guix time-machine -C $(CHANNELS) --
# Patched Hoot 0.8.0: adds missing mutable-bytevector? case in backend.scm.
# Drop this and `guile-hoot/fixed` once the upstream regression is fixed.
HOOT_FIXED = -L deploy/packages -e '(@ (hoot-fix) guile-hoot/fixed)'

# ── Reproducible runners ─────────────────────────────────────────────────────
# Every Make target that runs Guile code goes through one of these wrappers
# so the same toolchain is used on every machine. Adding a new dep means
# adding it to one of these variables, never relying on host PATH.
#
#   GUILE_RUN     — vanilla server-side Guile + Goblins (REPLs, relay, server)
#   GUILE_TEST    — same, but for the test/ tree
#   WEAVE_RUN     — adds guile-json (the prod Weave HTTP server in server/weave.scm)
#   HOOT_RUN      — adds the patched Hoot 0.8 + fibers + websocket (anything that
#                   imports `(hoot web-server)` / `(hoot web-repl)`)
#   WEAVE_DEV_RUN — HOOT_RUN + the prod Weave deps (the live-hacking server)
#   HOOT_BUILD    — environment for `guild compile-wasm` (no `guile`, just the
#                   tool the wasm compiler needs)
GUILE_RUN     = $(TIME_MACHINE) shell guile-next guile-goblins -- \
                  guile --no-auto-compile
GUILE_TEST    = $(GUILE_RUN)
WEAVE_RUN     = $(TIME_MACHINE) shell guile-next guile-goblins guile-json -- \
                  guile --no-auto-compile
HOOT_RUN      = $(TIME_MACHINE) shell guile-next $(HOOT_FIXED) \
                  guile-fibers guile-websocket -- \
                  guile --no-auto-compile
WEAVE_DEV_RUN = $(TIME_MACHINE) shell guile-next $(HOOT_FIXED) \
                  guile-goblins guile-json guile-fibers guile-websocket -- \
                  guile --no-auto-compile
HOOT_BUILD    = $(TIME_MACHINE) shell guile-next $(HOOT_FIXED) guile-goblins --

# ── Local dev REPLs ──────────────────────────────────────────────────────────

repl:
	$(GUILE_RUN) -L module server/repl.scm

quick-repl:
	$(GUILE_RUN) -L module server/play-repl.scm

# ── Wasm builds ──────────────────────────────────────────────────────────────

browser/repl.wasm: browser/repl.scm module/playnet/gplay.scm module/playnet/wisp.scm
	$(HOOT_BUILD) \
	  guild compile-wasm -L module -L docs/reference/lib-vendored \
	    --bundle -o browser/repl.wasm browser/repl.scm

serve: browser/repl.wasm
	$(HOOT_RUN) \
	  -c '((@ (hoot web-server) serve) #:work-dir "browser")'

relay:
	$(GUILE_RUN) -L module server/relay.scm

server:
	$(GUILE_RUN) -L module server/server.scm

test: test-gplay test-knowledge

test-gplay:
	$(GUILE_TEST) -L module tests/test-gplay.scm

test-knowledge:
	$(GUILE_TEST) -L module tests/test-knowledge.scm

test-governed:
	$(GUILE_TEST) -L module tests/test-governed-org.scm

test-signatures:
	$(GUILE_TEST) -L module tests/test-history-signatures.scm

test-wisp:
	$(GUILE_TEST) -L module tests/test-wisp.scm

test-endorsement:
	$(GUILE_TEST) -L module tests/test-endorsement.scm

test-output-cap:
	$(GUILE_TEST) -L module tests/test-output-cap.scm

test-output-port:
	$(GUILE_TEST) -L module tests/test-output-port.scm

test-persistence:
	$(GUILE_TEST) -L module tests/test-persistence.scm

test-planner:
	cd planner && $(TIME_MACHINE) shell guile-next guile-goblins -- sh run-tests.sh

test-relational:
	cd planner && $(TIME_MACHINE) shell guile-next guile-goblins -- \
	  guile --no-auto-compile -q -L ../module -l load-all.scm -l tests/relational-planner.scm

test-netlayer:
	$(GUILE_TEST) -L module tests/test-netlayer-substitute.scm

test-browser:
	$(TIME_MACHINE) shell -m deploy/guix/browser-test-manifest.scm -- \
	  sh tests/ux-test.sh

test-all: test-gplay test-knowledge test-governed test-signatures test-wisp test-endorsement test-persistence test-netlayer test-planner test-relational

# ── Docker (for macOS / non-Guix machines) ───────────────────────────────────
# Uses Guix inside Docker to provide the exact same toolchain.
# First run: `make docker-setup` to create the BuildKit builder.

DOCKER_IMAGE ?= playnet-dev
DOCKER_BUILDER ?= guix-builder

docker-setup:
	docker buildx create --name $(DOCKER_BUILDER) --driver docker-container \
	  --buildkitd-flags '--allow-insecure-entitlement security.insecure' 2>/dev/null || true

docker-build: docker-setup
	docker buildx build --builder $(DOCKER_BUILDER) \
	  --allow security.insecure --load -t $(DOCKER_IMAGE) .

docker-test-planner:
	docker run --rm --security-opt seccomp=unconfined \
	  -v "$$PWD":/src -w /src/planner $(DOCKER_IMAGE) sh run-tests.sh

docker-test-all:
	docker run --rm --security-opt seccomp=unconfined \
	  -v "$$PWD":/src -w /src $(DOCKER_IMAGE) sh -c '\
	  guile --no-auto-compile -L module tests/test-knowledge.scm && \
	  cd planner && sh run-tests.sh'

docker-shell:
	docker run --rm -it --security-opt seccomp=unconfined \
	  -v "$$PWD":/src $(DOCKER_IMAGE) guile --no-auto-compile -L module -L planner

docker-wasm:
	docker run --rm --security-opt seccomp=unconfined \
	  --entrypoint /usr/local/bin/guix-wasm \
	  -v "$$PWD":/src -w /src $(DOCKER_IMAGE) \
	  guild compile-wasm -L module --bundle --emit-names \
	    -o weave/weave.wasm module/weave/browser.scm

docker-weave:
	@echo "═══ Compiling weave.wasm in background ═══"
	@docker run --rm --security-opt seccomp=unconfined \
	  --entrypoint /usr/local/bin/guix-wasm \
	  -v "$$PWD":/src -w /src $(DOCKER_IMAGE) \
	  guild compile-wasm -L module --bundle --emit-names \
	    -o weave/weave.wasm module/weave/browser.scm \
	  && echo "═══ weave.wasm ready — reload browser ═══" &
	@echo "═══ Starting Weave → http://localhost:8081 ═══"
	@sleep 1 && { open http://localhost:8081 2>/dev/null || xdg-open http://localhost:8081 2>/dev/null || true; } &
	docker run --rm -it --security-opt seccomp=unconfined \
	  -v "$$PWD":/src -w /src -p 8081:8081 \
	  --env-file secrets.env \
	  $(DOCKER_IMAGE) guile --no-auto-compile -L module server/weave.scm

weave/weave.wasm: module/weave/browser.scm \
                  module/weave/ui/ffi.scm \
                  module/weave/ui/join.scm \
                  module/weave/ui/room.scm
	$(HOOT_BUILD) \
	  guild compile-wasm -gnames \
	    -L module -L docs/reference/lib-vendored --bundle \
	    -o weave/weave.wasm module/weave/browser.scm
# -gnames embeds a WebAssembly name section so Chrome/Firefox DevTools show
# readable function names (e.g. "render_join_screen") instead of "func[42]".
# Keep this flag on all development builds; strip it for production if size matters.
#
# -L docs/reference/lib-vendored brings in WASM-compatible Goblins/fibers
# sources. The system guile-goblins package can't be linked into a Hoot
# wasm bundle (some primitives need the vendored variants).

weave:
	$(WEAVE_RUN) -L module server/weave.scm

# ── Live-hacking dev bundles ─────────────────────────────────────────────────
# Dev bundles embed Hoot 0.8's runtime module system (-g2 = -gnames
# -gruntime-modules -gmutable-defs) so UI procedures can be redefined at
# runtime via (hoot web-repl) + Geiser. See docs/LIVE_HACKING.md.
#
# Dev output lives in browser/.dev/ and weave/.dev/ (both gitignored) so the
# dev bundle NEVER overwrites the prod browser/repl.wasm that GitHub Pages
# serves. Each dev dir holds symlinks to non-wasm assets (HTML/JS/CSS/etc.)
# plus the -g2 wasm as a real file. DO NOT DEPLOY dev bundles — they are
# several times larger and dial localhost on startup.

browser/.dev:
	mkdir -p browser/.dev

weave/.dev:
	mkdir -p weave/.dev

# Populate browser/.dev with symlinks to every sibling file in browser/
# EXCEPT repl.scm (source) and repl.wasm (written directly as the dev bundle,
# must not be a symlink or the build would clobber the prod wasm).
browser/.dev/.stamp-assets: | browser/.dev
	@cd browser && for f in *; do \
	  case "$$f" in \
	    .dev|repl.scm|repl-dev.scm|repl.wasm) ;; \
	    *) ln -sfn "../$$f" ".dev/$$f" ;; \
	  esac; \
	done
	@touch $@

# Same pattern for weave/.dev — exclude weave.wasm so the dev build writes a
# real file there instead of clobbering the prod copy via symlink.
weave/.dev/.stamp-assets: | weave/.dev
	@cd weave && for f in *; do \
	  case "$$f" in \
	    .dev|weave.wasm) ;; \
	    *) ln -sfn "../$$f" ".dev/$$f" ;; \
	  esac; \
	done
	@touch $@

# The dev wrapper files (browser/repl-dev.scm, module/weave/browser-dev.scm)
# are *tail fragments* — they only contain the (run-web-repl) call (and an
# optional parameterize override of current-repl-server). We build the
# actual compilation input by:
#
#   1. Cloning the prod entry point and injecting (hoot web-repl) into its
#      top-level (use-modules ...) form. Hoot's library-group compiler
#      requires use-modules to be the first AND ONLY top-level imports
#      form, so we can't simply prepend a second one.
#   2. Appending the dev tail.
#
# The result starts the prod entry point's full init flow (FFI, refresh!,
# register-callbacks!, OCapN bootstrap), then hands control to
# run-web-repl which dials the dev server's WebSocket relay.
#
# We can't (include …) the prod source from a separate wrapper because
# Hoot's library-group compiler forbids top-level include clauses.

browser/.dev/repl-live.scm: browser/repl.scm browser/repl-dev.scm \
                            | browser/.dev
	sed '0,/(use-modules /s//(use-modules (hoot web-repl) /' \
	    browser/repl.scm > $@
	cat browser/repl-dev.scm >> $@

browser/.dev/repl.wasm: browser/.dev/repl-live.scm \
                       module/playnet/gplay.scm module/playnet/wisp.scm \
                       browser/.dev/.stamp-assets
	$(HOOT_BUILD) \
	  guild compile-wasm -g2 -L module -L docs/reference/lib-vendored \
	    --bundle -o browser/.dev/repl.wasm browser/.dev/repl-live.scm

weave/.dev/weave-live.scm: module/weave/browser.scm \
                           module/weave/browser-dev.scm \
                           | weave/.dev
	sed '0,/(use-modules /s//(use-modules (hoot web-repl) /' \
	    module/weave/browser.scm > $@
	cat module/weave/browser-dev.scm >> $@

weave/.dev/weave.wasm: weave/.dev/weave-live.scm \
                      module/weave/ui/ffi.scm \
                      module/weave/ui/join.scm module/weave/ui/room.scm \
                      weave/.dev/.stamp-assets
	$(HOOT_BUILD) \
	  guild compile-wasm -g2 \
	    -L module -L docs/reference/lib-vendored --bundle \
	    -o weave/.dev/weave.wasm weave/.dev/weave-live.scm

# `make serve-dev` — rebuild the REPL UI dev bundle and serve it with
# (hoot web-server), which exposes /repl as the WebSocket proxy for Geiser.
serve-dev: browser/.dev/repl.wasm
	$(HOOT_RUN) \
	  -c '((@ (hoot web-server) serve) #:work-dir "browser/.dev")'

# `make weave-dev` — rebuild the Weave dev bundle and serve it via
# server/weave-dev.scm on port 8082 (localhost only).
weave-dev: weave/.dev/weave.wasm
	$(WEAVE_DEV_RUN) -L module server/weave-dev.scm

# `make live-watch` — auto-reload on save.
#
# Run alongside `make weave-dev` (or `make serve-dev`): edit a Scheme
# file under module/, this watches for the save and pushes the new
# definitions into the running browser tab via the REPL relay on
# 127.0.0.1:37146. No page reload, no rebuild.
#
# Defaults to watching ./module. Pass extra paths after `--`:
#   make live-watch ARGS="server module/playnet"
#
# Pulls inotify-tools, bash AND guile-next through guix so the script
# works from a clean checkout — the bash loop calls tools/live-reload.scm
# which in turn calls /usr/bin/env guile, so guile must be on PATH inside
# the shell. The Hetzner VM gets the same packages via the live-watch
# shepherd service.
live-watch:
	$(TIME_MACHINE) shell inotify-tools coreutils bash guile-next -- \
	  ./tools/live-watch.sh $(ARGS)

clean:
	rm -f browser/repl.wasm weave/weave.wasm \
	      browser/.dev/repl.wasm browser/.dev/repl-live.scm \
	      weave/.dev/weave.wasm weave/.dev/weave-live.scm \
	      browser/.dev/.stamp-assets weave/.dev/.stamp-assets
