all: repl.wasm

repl:
	guile xorg-repl.scm

quick-repl:
	guile play-repl.scm

repl.wasm: repl.scm module/repl-environment.scm module/xorg/play.scm
	guild compile-wasm -L module --bundle -gruntime-modules -o repl.wasm repl.scm

serve: repl.wasm
	guile -c '((@ (hoot web-server) serve))'

clean:
	rm repl.wasm
