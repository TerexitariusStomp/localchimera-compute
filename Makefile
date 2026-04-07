all: browser/repl.wasm weave/weave.wasm

repl:
	guile -L module server/repl.scm

quick-repl:
	guile -L module server/play-repl.scm

CHANNELS = deploy/guix/channels.scm
TIME_MACHINE = guix time-machine -C $(CHANNELS) --
# Patched Hoot 0.8.0: adds missing mutable-bytevector? case in backend.scm
HOOT_FIXED = -L deploy/packages -e '(@ (hoot-fix) guile-hoot/fixed)'

browser/repl.wasm: browser/repl.scm module/playnet/gplay.scm module/playnet/wisp.scm
	$(TIME_MACHINE) shell guile-next $(HOOT_FIXED) guile-goblins -- \
	  guild compile-wasm -L module -L docs/reference/lib-vendored --bundle -o browser/repl.wasm browser/repl.scm

serve: browser/repl.wasm
	$(TIME_MACHINE) shell guile-next $(HOOT_FIXED) -- \
	  sh -c 'cd browser && guile -c "((@ (hoot web-server) serve))"'

relay:
	guile -L module server/relay.scm

server:
	guile -L module server/server.scm

test: test-gplay test-knowledge

GUILE_TEST = $(TIME_MACHINE) shell guile-next guile-goblins -- \
  guile --no-auto-compile

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
                  module/weave/ui/join.scm \
                  module/weave/ui/room.scm
	$(TIME_MACHINE) shell guile-next $(HOOT_FIXED) guile-goblins -- \
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
	guile -L module server/weave.scm

# ── Live-hacking dev bundles ─────────────────────────────────────────────────
# Dev bundles embed Hoot 0.8's runtime module system (-g2 = -gnames
# -gruntime-modules -gmutable-defs) so UI procedures can be redefined at
# runtime via (hoot web-repl) + Geiser. See docs/weave/LIVE_HACKING.md.
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
	$(TIME_MACHINE) shell guile-next $(HOOT_FIXED) guile-goblins -- \
	  guild compile-wasm -g2 -L module -L docs/reference/lib-vendored \
	    --bundle -o browser/.dev/repl.wasm browser/.dev/repl-live.scm

weave/.dev/weave-live.scm: module/weave/browser.scm \
                           module/weave/browser-dev.scm \
                           | weave/.dev
	sed '0,/(use-modules /s//(use-modules (hoot web-repl) /' \
	    module/weave/browser.scm > $@
	cat module/weave/browser-dev.scm >> $@

weave/.dev/weave.wasm: weave/.dev/weave-live.scm \
                      module/weave/ui/join.scm module/weave/ui/room.scm \
                      weave/.dev/.stamp-assets
	$(TIME_MACHINE) shell guile-next $(HOOT_FIXED) guile-goblins -- \
	  guild compile-wasm -g2 \
	    -L module -L docs/reference/lib-vendored --bundle \
	    -o weave/.dev/weave.wasm weave/.dev/weave-live.scm

# `make serve-dev` — rebuild the REPL UI dev bundle and serve it with
# (hoot web-server), which exposes /repl as the WebSocket proxy for Geiser.
serve-dev: browser/.dev/repl.wasm
	$(TIME_MACHINE) shell guile-next $(HOOT_FIXED) -- \
	  sh -c 'cd browser/.dev && guile -c "((@ (hoot web-server) serve))"'

# `make weave-dev` — rebuild the Weave dev bundle and serve it via
# server/weave-dev.scm on port 8082 (localhost only).
weave-dev: weave/.dev/weave.wasm
	guile -L module server/weave-dev.scm

clean:
	rm -f browser/repl.wasm weave/weave.wasm \
	      browser/.dev/repl.wasm browser/.dev/repl-live.scm \
	      weave/.dev/weave.wasm weave/.dev/weave-live.scm \
	      browser/.dev/.stamp-assets weave/.dev/.stamp-assets
