# Build the compiled hot-loop kernel for planner.scm's §2b native-c backend.
#   make            → ONE object that runs on any x86-64 and still uses AVX-512
#                     where it finds it. The default.
#   make native     → tuned to THIS cpu (-march=native), and to no other.
#   make portable   → baseline x86-64, no per-cpu code at all.
#
# THE PROBLEM EACH ANSWERS. -march=native tunes the object to the machine that
# compiled it, and a .so copied to an older cpu then dies on an illegal
# instruction at the first solve: SIGILL, no message, no backtrace through the
# FFI, nothing naming the cause. Two independent fixes, and they compose:
#
#   · the object says what it needs. kernel.c exports pk_required_isa, a string
#     constant listing the extensions -march enabled; solver.scm reads it (data,
#     so safe on any cpu) and refuses the backend with a sentence naming the
#     missing features instead of taking the signal.
#   · the object stops needing anything in particular. The default build drops
#     -march and puts target_clones on every numeric function without an OpenMP
#     pragma, so GCC compiles each one once per psABI architecture level and an
#     IFUNC resolver picks by what the running cpu actually reports.
#
# WHAT AGNOSTIC COSTS, measured here (test-stone-paper-siting, OMP_NUM_THREADS=1,
# min of alternating runs on a laptop, so read it as approximate):
#
#     clones by EXTENSION   native  48.9 s | agnostic 55.0 s   ~11%   195 KB
#     clones by ARCH LEVEL  native  42.1 s | agnostic 43.2 s   ~3%    242 KB
#
# The first gap was an artefact of how the clones were asked for, not a price of
# multiversioning: target_clones("avx512f") enables that ONE extension and no
# -mtune, so the clone was compiled far weaker than -march=native. Asking by
# psABI architecture level instead gives each clone the whole feature set, and
# most of the difference disappears.
#
# ~3% is inside the run-to-run spread on this machine, and it buys an object
# with no cpu requirement at all — no SIGILL to diagnose, no rebuild needed when
# a .so is copied, and CI and laptop running identical code. That is worth three
# percent, so AGNOSTIC IS THE DEFAULT and `native` is the deliberate ask.
#
# Without any of this, planner.scm still loads; only the 'native-c backend is
# unavailable (the 'native and 'osqp backends are unaffected).
# `CC ?= gcc` reads as a default and is not one: make DEFINES CC as `cc` in its
# built-in rules, so `?=` never fires and every build silently used whatever
# `cc` the host happened to have. On this laptop that is /usr/bin/cc; inside the
# test manifest's profile there is no `cc` at all — gcc-toolchain installs
# `gcc` — so CI built nothing and the suite met the same missing .so it was
# meant to produce. Overriding only when the value is make's own built-in
# leaves `make CC=clang` and an exported CC working as they read.
CC := $(if $(filter default,$(origin CC)),gcc,$(CC))
# -fopenmp parallelizes the §2d Jacobi-CG hot loop across cores (set OMP_NUM_THREADS
# to control; defaults to all cores). Harmless to the serial backends.
# no -march, clones ON: each numeric function is compiled once per architecture
# level and an IFUNC resolver picks by what the running cpu reports.
CFLAGS  ?= -O3 -ffast-math -fPIC -shared -fopenmp

libplanner_kernel.so: kernel.c kernel_kinds.h
	$(CC) $(CFLAGS) kernel.c -o $@

# -march=native tunes to THIS cpu and nothing else; PK_NO_MULTIVERSION turns the
# clones off, since cloning a function already compiled for the exact host buys
# nothing and costs code size. The object this produces declares its
# requirements through pk_required_isa, so misusing it is a sentence.
native: CFLAGS := -O3 -march=native -ffast-math -fPIC -shared -fopenmp -DPK_NO_MULTIVERSION
native: clean libplanner_kernel.so

# no -march, no clones: one baseline object, and the floor the other two are
# measured against
portable: CFLAGS := -O3 -ffast-math -fPIC -shared -fopenmp -DPK_NO_MULTIVERSION
portable: clean libplanner_kernel.so

clean:
	rm -f libplanner_kernel.so

.PHONY: native portable clean
