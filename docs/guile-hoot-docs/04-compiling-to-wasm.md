# Compiling to WASM in Guile Hoot

## Overview

This section covers the process of converting code to WebAssembly format using Guile Hoot.

## Main Topics

The compilation process is organized into three primary areas:

1. **Invoking the compiler** - Details on how to trigger and configure the compilation process for generating WebAssembly output.

2. **High-level development tools** - Abstractions and utilities designed to streamline the WASM compilation experience for developers, making the process more accessible.

3. **Low-level development tools** - Lower-level interfaces and mechanisms for fine-grained control over WebAssembly generation and optimization.

## High-Level Development Tools

### The `(hoot reflect)` Module

The `(hoot reflect)` module provides mechanisms for examining and working with Scheme values within WASM modules, serving as the primary testing interface for compiler output.

#### Core Module Operations

**Module Instantiation & Loading:**
- `hoot-instantiate`: "Instantiate and return a new Hoot module using the compiled Scheme WASM module"
- `hoot-load`: Executes the module's load thunk and returns reflected results
- Module inspection utilities: `hoot-module?`, `hoot-module-reflector`, `hoot-module-instance`

**Compilation Functions:**
- `compile-value`: Compiles expressions and returns results via reflection
- `compile-call`: Compiles procedures and arguments, executes the call, then returns typed results
- Reflection support: `reflector?`, `reflector-instance`, `reflector-abi`

#### Type Inspection & Manipulation

The module provides predicates and accessors for numerous Scheme types:

**Numeric Types:**
- Complex numbers: `hoot-complex?`, `hoot-complex-real`, `hoot-complex-imag`
- Fractions: `hoot-fraction?`, `hoot-fraction-num`, `hoot-fraction-denom`

**Collections:**
- Pairs: `hoot-pair?`, `mutable-hoot-pair?`, accessors for car/cdr
- Vectors: length, reference, and mutability checking
- Bytevectors & bitvectors: similar inspection capabilities
- Hash tables, weak tables

**Symbols & Keywords:**
- Type checking and name extraction for both

**Advanced Types:**
- Procedures, variables, atomic boxes, fluids, syntax objects, ports, structs, dynamic state

## Low-Level Development Tools

### The `(hoot repl)` Module

The `(hoot repl)` module provides debugging capabilities for inspecting WASM modules. As stated in the documentation, "Hoot's Scheme compiler _should not_ cause low-level WASM runtime errors," but these tools assist when issues arise.

#### Setup

Import the module with:
```scheme
,use (hoot repl)
```

View available commands:
```scheme
,help wasm
```

#### Core REPL Commands

**General Debugging Commands:**

| Command | Purpose |
|---------|---------|
| **wasm-trace** | Execute expressions with verbose instruction tracing |
| **wasm-freq** | Display instruction execution frequency statistics |
| **wasm-catch** | Trap and debug WASM runtime errors |

**Debug Context Commands:**

These commands activate only within a WASM debug REPL session:

| Command | Purpose |
|---------|---------|
| **wasm-stack** | Display current value stack contents |
| **wasm-locals** | Show function local variable states |
| **wasm-pos** | Display function disassembly with highlighted current instruction |
| **wasm-eval** | Execute arbitrary WASM instructions in current context |

**Dual-Mode Commands:**

| Command | Purpose |
|---------|---------|
| **wasm-dump** | Display WASM or current instance information |
| **wasm-continue** | Resume execution or disable stepping |
| **wasm-step** | Pause before next instruction or advance one step |

#### Usage Example

The documentation demonstrates debugging a function containing an `unreachable` instruction by:

1. Defining problematic WAT source
2. Compiling and loading the module
3. Using `,wasm-catch` to trap the error
4. Inspecting stack/locals with dedicated commands
5. Using `,wasm-eval` to modify interpreter state if needed
6. Resuming with `,wasm-continue`

**Important caveat:** Manual state modification bypasses validation, potentially causing undefined behavior.
