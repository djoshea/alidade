# Rust workspace, lifetimes, and idioms

Captured while scaffolding the `crates/` workspace in Phase 0. The repo has
three crates: `alidade-protocol`, `alidade-core`, and `alidade` (the server,
which provides both a library API and the `alidade` binary).

## Cargo workspaces

A Cargo workspace is one repo containing multiple Rust packages (called
*crates*) that share a single `Cargo.lock`, build cache (`target/`), and
shared package metadata. Cargo's workspace support is built into the tool
itself — no extra layer.

The shape we landed on:

```
Cargo.toml                       # workspace root — defines members + shared metadata
crates/
  alidade-protocol/
    Cargo.toml                   # version.workspace = true, etc.
    src/lib.rs
  alidade-core/
    Cargo.toml
    src/lib.rs
  alidade/
    Cargo.toml
    src/lib.rs                   # library API
    src/main.rs                  # the `alidade` binary
```

### `[workspace.package]` inheritance

The root `Cargo.toml` declares shared metadata once:

```toml
[workspace.package]
version = "0.0.0"
edition = "2024"
rust-version = "1.85"
license = "PolyForm-Noncommercial-1.0.0"
authors = ["Daniel J. O'Shea"]
repository = "https://github.com/djoshea/alidade"
```

Each crate writes `version.workspace = true` to inherit individual fields.
This is the mechanism that makes "lockstep versioning" a one-line knob —
bump the root, all crates move together. Same pattern works for `license`,
`edition`, `authors`, etc.

### `resolver = "2"`

Cargo has two dependency-feature resolvers. v2 is the modern one (default for
new `edition = "2021"`+ projects, but you must opt in explicitly at the
workspace level — it's *not* inherited from edition). It handles feature
unification more correctly across normal/build/dev dependencies. Always set
it on a workspace.

### `lib` vs `bin`

A crate can produce a library (`src/lib.rs`), a binary (`src/main.rs` or
`src/bin/*.rs`), or both. The `alidade` crate is both:

- the **library** (`alidade::version()`) contains testable server logic
- the **binary** (`alidade`) is a tiny shell that calls into the library

This is the standard Rust idiom: keep your binary thin so the logic stays
unit-testable without spinning up a real process.

When the crate name and the binary name match (both `alidade`), Cargo picks
that up automatically — no `[[bin]] name = "..."` override needed. If they
differ (e.g. crate `alidade-server`, binary `alidade`), you'd add that
override in `Cargo.toml`.

### Edition 2024

We use Rust edition 2024 (stabilized in rustc 1.85, Feb 2025). Notable
changes over 2021:

- `let` chains stabilized: `if let Some(x) = foo && x > 0 { ... }`
- `unsafe extern { ... }` blocks
- `gen` keyword reserved (for future generator syntax)
- RPIT (return-position impl trait) lifetime capture rules updated
- Stricter `match` ergonomics around references
- Tail expressions get cleaner drop order

Editions are **per-crate**: choosing 2024 only affects how *our* code is
parsed, not what crates we can depend on. Crates from different editions
interop fine.

## Lifetimes and ownership

The first idiom you'll see everywhere in Rust is the choice between an
*owned* value and a *borrowed reference*. Almost every function-signature
decision is "do I take/return `String` or `&str`, `Vec<T>` or `&[T]`?"

In the `version()` function we wrote:

```rust
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
```

- `&str` is a *borrowed* reference to UTF-8 bytes living somewhere else.
- `'static` is a **lifetime annotation** meaning "this reference is valid
  for the entire program."
- String literals like `"0.0.0"` are baked into the binary's read-only
  data segment, so they always have a `'static` lifetime.

We could have written `String` (an owned, heap-allocated string), but that
would force a heap allocation every call for no reason. `&'static str` says
"I'm handing you a pointer to bytes that already exist and will never go
away" — both faster and a clearer statement of intent.

**Default rule of thumb:** borrows for inputs, owned values for outputs,
unless you have a reason to do otherwise. Here we break the rule for the
output because the data is genuinely static; copying it would be wasteful.

## Macros: the `!` suffix

Rust syntactically distinguishes macros from functions: macros end in `!`.
Examples used so far:

- `env!("CARGO_PKG_VERSION")` — a *compile-time* macro that reads the
  environment variable at build time and substitutes the literal string.
  Cargo sets `CARGO_PKG_VERSION` to the crate's `version` field during
  build, so `version()` returns the literal `"0.0.0"` baked into the
  binary — no runtime cost and guaranteed in sync with `Cargo.toml`.
- `println!("alidade {}", ...)` — needs compile-time format-string
  checking that a regular function can't do in Rust. `{}` placeholders
  require their arguments to implement `Display`; mismatches fail at
  compile time, not runtime.
- `assert!(cond)` — panics if `cond` is false.

If you see `foo!(...)`, that's a macro. If you see `foo(...)`, that's a
function call.

## Doc comments: `//!` vs `///`

Two flavors of Rust doc comments:

- `///` documents the **item that follows it** (a function, struct, etc.).
- `//!` documents the **item that contains it** — at the top of `lib.rs`
  it documents the whole crate; inside a module it documents that module.

These get rendered by `cargo doc` into an HTML site, and `cargo test`
actually compiles and runs code examples inside them (doctests). Docs live
next to code and can't silently rot — broken examples fail CI.

## Tests live next to code

Rust's standard idiom for unit tests:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_nonempty() {
        assert!(!version().is_empty());
    }
}
```

- `#[cfg(test)]` is a **conditional-compilation attribute** — the `mod tests`
  block only gets compiled when running tests, so it doesn't bloat the
  release binary.
- `#[test]` marks a function as a test that `cargo test` discovers and runs.
- `use super::*` brings everything from the parent module (the file itself)
  into scope so we can write `version()` instead of `crate::version()`.

Tests in the same file as the code they exercise; integration tests go in
`tests/` at the crate root. Both styles are idiomatic.

## Library + binary in one crate

When a crate has both `src/lib.rs` and `src/main.rs`, Cargo builds them as
two compilation targets:

- the **library** (importable as `alidade::...`)
- the **binary** (the executable, default-named after the crate)

The binary depends on the library implicitly — that's why `main.rs` writes
`alidade::version()` to reach into its own crate's library half. Same crate,
two outputs. Convention: keep `main.rs` tiny (parse args, set up logging,
hand off to a `run()` in `lib.rs`).
