# Guile Hoot Documentation

This folder contains documentation for Guile Hoot, a Scheme to WebAssembly compiler backend for GNU Guile.

## Sources

Documentation extracted from:
- Base documentation (v0.1.0): https://files.spritely.institute/docs/guile-hoot/0.1.0/
- FFI and reflection (latest): https://files.spritely.institute/docs/guile-hoot/latest/

## Contents

### Core Documentation (v0.1.0)
- [00-introduction.md](00-introduction.md) - Overview and project goals
- [01-status.md](01-status.md) - Current implementation status and supported features
- [02-installation.md](02-installation.md) - Installation instructions
- [03-tutorial.md](03-tutorial.md) - Getting started tutorial
- [04-compiling-to-wasm.md](04-compiling-to-wasm.md) - Compilation guide with high-level and low-level tools
- [05-toolchain-reference.md](05-toolchain-reference.md) - Complete toolchain component reference
- [06-contributing.md](06-contributing.md) - How to contribute to the project
- [07-license.md](07-license.md) - License information (Apache 2.0)

### FFI and Reflection (Latest)
- [08-foreign-function-interface.md](08-foreign-function-interface.md) - FFI for calling host functions from Scheme
- [09-javascript-reflection.md](09-javascript-reflection.md) - JavaScript API for loading and interacting with Hoot modules
- [10-guile-reflection.md](10-guile-reflection.md) - Guile API for inspecting Hoot values

## About Guile Hoot

Guile Hoot is:
- A Scheme to WebAssembly compiler
- A general-purpose WASM toolchain
- Built entirely in Scheme
- Developed by Spritely Institute in partnership with Igalia
- Licensed under Apache License 2.0

## Key Features

- Compiles Scheme (subset of R7RS-small) to WebAssembly
- Supports modern WASM features (tail calls, GC, stringref)
- Self-contained toolchain (no external dependencies like binaryen or wabt)
- REPL-driven development workflow
- Interactive debugging tools
- Foreign Function Interface (FFI) for JavaScript/host interop
- Reflection APIs for both JavaScript and Guile environments

## Official Resources

- Codeberg: https://codeberg.org/spritely/hoot (current repository)
- GitLab: https://gitlab.com/spritely/guile-hoot (archived)
- Documentation (latest): https://files.spritely.institute/docs/guile-hoot/latest/
- FFI Demo: https://codeberg.org/spritely/hoot-ffi-demo
- Spritely Institute: https://spritely.institute/
