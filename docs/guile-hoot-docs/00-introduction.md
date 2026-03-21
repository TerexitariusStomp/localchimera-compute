# Introduction to Guile Hoot

## Overview

Guile Hoot is a compiler that translates Scheme code into WebAssembly (WASM), designed for GNU Guile. It represents a general-purpose WASM toolchain targeting all major web browsers and native environments.

## The Problem It Solves

For decades, JavaScript dominated web development. While the language has evolved, its design has limitations. Developers seeking alternatives faced a significant constraint: compiling their preferred languages to JavaScript. This approach proved problematic for many languages that don't map cleanly to JavaScript. Scheme, specifically, suffers from JavaScript's lack of tail call optimization, making tail-recursive code compilation awkward.

WASM emerged as a superior alternative, enabling languages like Scheme to run on the web with fewer compromises and improved performance.

## Project Goals and Context

The Spritely Institute, in partnership with Igalia, developed Hoot to support their mission of building decentralized internet infrastructure. Since Goblins—Spritely's distributed object programming environment—is written in Guile, a Guile-to-WASM compiler directly serves their users' needs without requiring JavaScript.

## Advocacy Mission

Beyond immediate goals, Hoot champions dynamic languages' place in client-side web development. The WASM GC proposal made this feasible for garbage-collected languages. By implementing and targeting emerging WASM proposals, Hoot helps advance the broader specification, benefiting Python, Ruby, and other dynamic languages.
