all: repl.wasm

repl:
	guile xorg-repl.scm

quick-repl:
	guile play-repl.scm

repl.wasm: repl.scm module/xorg/gplay.scm
	guild compile-wasm -L module -L lib --bundle -o repl.wasm repl.scm

serve: repl.wasm
	guile -c '((@ (hoot web-server) serve))'

relay:
	guile xorg-relay.scm

server:
	guile -L module xorg-server.scm

test: test-gplay test-play test-knowledge

test-play:
	guile -L module tests/test.scm

test-gplay:
	guile -L module tests/test-gplay.scm

test-knowledge:
	guile -L module tests/test-knowledge.scm

clean:
	rm repl.wasm
