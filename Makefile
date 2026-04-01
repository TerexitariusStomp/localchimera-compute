all: browser/repl.wasm

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

clean:
	rm -f browser/repl.wasm
