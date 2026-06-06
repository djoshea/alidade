# alidade — learning notes

Pedagogical notes captured during development, mostly for the Rust and modern
frontend stack (TypeScript / React / Vite / pnpm), since those are where the
maintainer is actively learning. Each note is a short essay rather than a
reference — read top to bottom.

## Index

- [Rust workspace, lifetimes, and idioms](rust-workspace.md) — what
  `[workspace.package]` does, `&'static str` vs `String`, `env!`, `#[cfg(test)]`,
  doc-comment flavors, library-vs-binary crates.
- [Frontend stack: Vite + React + TypeScript + pnpm workspaces](frontend-stack.md)
  — how the build tool, the framework, the type system, and the package manager
  fit together.
