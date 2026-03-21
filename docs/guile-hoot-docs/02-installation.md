# Guile Hoot Installation Guide

## Quick Start with GNU Guix

The recommended approach uses the GNU Guix package manager. Simply navigate to the guile-hoot directory and run:

```bash
cd guile-hoot/
guix shell
```

This automatically downloads and compiles all dependencies, providing a ready-to-use environment.

## Manual Installation

### Prerequisites

Building without Guix requires:
- A bleeding-edge version of Guile built from the `main` branch (during development)
- Eventually, stable Guile releases will be supported

### Build Steps

**For Git checkouts**, bootstrap the build system first:
```bash
./bootstrap.sh
```

Note: Official release tarballs include pre-bootstrapped systems and skip this step.

**Then configure and build:**
```bash
./configure
make
```

### Installation

To install system-wide:
```bash
sudo make install
```

The default location is `/usr/local`. To specify a custom path:
```bash
./configure --prefix=/some/where/else
sudo make install
```

### Testing Installation

Without installing, test using the wrapper script:
```bash
./pre-inst-env guile
```

Verify Hoot modules are accessible by running this in the Guile REPL:
```scheme
scheme@(guile-user)> ,use (hoot compile)
```

## Test Suite (Optional)

Run tests with:
```bash
make check
```

This uses two WASM runtimes by default: Hoot's interpreter and V8's `d8` tool. To skip V8 and use only the built-in interpreter:
```bash
make check WASM_HOST=hoot
```
