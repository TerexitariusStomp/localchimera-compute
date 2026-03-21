# Guile Hoot Status

## Overview

Guile Hoot is an early-stage compiler that transforms Scheme code into WebAssembly (WASM). The project remains under active development with an unstable API.

## Supported Features

Hoot implements a subset of the R7RS-small Scheme specification, supplemented by select Guile-specific capabilities like prompts.

## Unsupported R7RS-small Features

The following features are not yet implemented:

- Libraries and module system (`define-library`, `import`)
- Record types (`define-record-type`)
- Complex number math operations
- Bignum constants (though bignum computation is possible)
- Symbols/keywords in secondary WASM modules
- Mutable strings (`string-set!`)
- Scheme reader (`read`)
- Evaluation features (`eval`, `environment`)
- System interface functions
- Promises (`delay`, `force`)

## Technical Foundation

Hoot leverages modern WASM features including:

- **Tail calls** via `return_call` instructions for efficient recursion
- **GC reference types** for heap allocation managed by the WASM runtime
- **Stringref** (currently lowered to JS String Builtins equivalent)

## Browser Integration Status

JavaScript-to-Scheme interoperability is partially implemented through the reflect.js library, allowing JavaScript to invoke Scheme procedures and examine values. However, a complete foreign function interface for calling host functions from Scheme remains unavailable.
