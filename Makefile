all: browser/repl.wasm

repl:
	guile -L module server/repl.scm

quick-repl:
	guile -L module server/play-repl.scm

CHANNELS = deploy/guix/channels.scm
TIME_MACHINE = guix time-machine -C $(CHANNELS) --

browser/repl.wasm: browser/repl.scm module/xorg/gplay.scm module/xorg/wisp.scm
	$(TIME_MACHINE) shell guile-next guile-hoot guile-goblins -- \
	  guild compile-wasm -L module -L docs/reference/lib-vendored --bundle -o browser/repl.wasm browser/repl.scm

serve: browser/repl.wasm
	$(TIME_MACHINE) shell guile-next guile-hoot -- \
	  sh -c 'cd browser && guile -c "((@ (hoot web-server) serve))"'

relay:
	guile -L module server/relay.scm

server:
	guile -L module server/server.scm

test: test-gplay test-knowledge

test-gplay:
	guile --no-auto-compile -L module tests/test-gplay.scm

test-knowledge:
	guile --no-auto-compile -L module tests/test-knowledge.scm

test-governed:
	guile --no-auto-compile -L module tests/test-governed-org.scm

test-signatures:
	guile --no-auto-compile -L module tests/test-history-signatures.scm

test-wisp:
	guile --no-auto-compile -L module tests/test-wisp.scm

test-all: test-gplay test-knowledge test-governed test-signatures test-wisp

clean:
	rm -f browser/repl.wasm
