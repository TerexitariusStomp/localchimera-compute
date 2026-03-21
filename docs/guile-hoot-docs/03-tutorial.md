# Guile Hoot Tutorial

## Overview
This tutorial demonstrates compiling Scheme programs to WebAssembly (WASM) using Guile Hoot and executing them both locally and in web browsers.

## Core Concepts

### Basic Compilation
Start by importing the compilation module and compiling a simple value:
- Use `(hoot compile)` to access compilation functions
- The `compile` procedure converts Scheme expressions to WASM modules
- Results can be tested without leaving the Guile REPL

### Testing Locally
To verify compiled code works:
1. Load the reflection module using `(wasm parse)`
2. Parse the `reflect.wasm` helper binary from the Hoot build directory
3. Create a WASM instance with `hoot-instantiate`
4. Execute using `hoot-load` to retrieve results

### Quick Testing Method
For rapid iteration, use `compile-value` instead—"the compiled WASM module is thrown away, which is just fine for testing throwaway code."

### Example: Factorial Function
Demonstrates compiling a tail-recursive procedure that can be called like a regular Scheme function after compilation.

## Web Browser Deployment

### Steps to Deploy:
1. Compile code to WASM using the assembler
2. Create a project directory and write the binary to disk
3. Copy supporting files: `reflect.js`, `reflect.wasm`, and `wtf8.wasm`
4. Write JavaScript glue code to load and execute the compiled module
5. Create an HTML page that loads the necessary scripts
6. Run a local web server to serve files

### File Structure Required
- HTML entry point
- Compiled WASM binary
- JavaScript runtime library and helpers
- Associated WASM support modules

### Web Server Implementation
The tutorial provides a minimal Scheme-based HTTP server implementation using Guile's built-in web modules to serve files with appropriate MIME types.
