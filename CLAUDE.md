# CLAUDE.md — alidade

alidade is a 3D viewer/controller for CAD-and-volumetric scenes: a headless Rust server owns the
document state and exposes a websocket API; thin web clients (browser, Tauri desktop, Jupyter
widget) render and interact; a Python library drives it programmatically via `build123d`.

**Full design context is in `docs/PLAN.md`.** Read it for architecture, rationale, the wire-protocol
and data-model design, and the phased roadmap. This file is the day-to-day operating guide.

---

## How we work together (please read first)

The maintainer is fluent in Python and scientific computing but **actively learning Rust and the
modern TypeScript / React / React Three Fiber frontend stack**. Default to a **pedagogical mode** for
Rust and frontend work:

- Work in **small, reviewable increments**. Do not dump large unexplained code blocks; pause at
  natural boundaries.
- After writing a non-trivial Rust or frontend block, **briefly explain what it does and why this
  approach** — name the idiom or concept in play (ownership/borrowing, lifetimes, trait choices,
  error handling for Rust; hooks, reconciliation, R3F scene-graph specifics for the frontend).
  Favor explaining the *why*, not just the syntax.
- **Explicitly invite questions.** The maintainer will often ask "why this?" or "explain this block"
  — answer at the level of underlying concepts, and assume that is welcome, not an interruption.
- When introducing a new crate, library, or pattern, give a one-line "what it is and why we use it."
- Prefer **standard, idiomatic** patterns over clever ones, and say when something is idiomatic.
- Lean harder into explanation in the **early phases**; taper as the maintainer signals fluency
  (they will say so).
- **Python needs less hand-holding** — the maintainer is comfortable there — but keep the typing and
  conventions below strict.

---

## Repository layout

```
crates/alidade-protocol/   wire types (serde); source of truth for the cross-language contract
crates/alidade-core/        scene tree, document model, geometry-agnostic logic
crates/alidade-server/      the server: lib + binary `alidade`
app/                        TypeScript + React + R3F + leva frontend (Vite)
app/src-tauri/              Tauri desktop shell (thin Rust); its OWN Cargo project, NOT in the workspace
python/                     `alidade` PyPI package: ws client + build123d integration
docs/PLAN.md                full architecture & roadmap
```

---

## Commands

(Targets solidify in Phase 0; keep this section updated as tooling lands.)

**Rust** (workspace root):
- Build: `cargo build`
- Run server: `cargo run -p alidade-server`
- Test: `cargo test`
- Lint: `cargo clippy --all-targets --all-features -- -D warnings`
- Format: `cargo fmt`

**Python** (`python/`, via `uv`):
- Sync deps: `uv sync`
- Test: `uv run pytest`
- Lint: `uv run ruff check`
- Format: `uv run ruff format`
- Types: `uv run ty check`

**Frontend** (pnpm workspace at the repo root; `app/`, `packages/*`, `npm/*`):
- Install: `pnpm install` (run at the repo root, not inside `app/`)
- Dev server: `pnpm --filter @alidade/app run dev`
- Build: `pnpm --filter @alidade/app run build`  (runs `tsc -b && vite build`)
- Typecheck (all packages): `pnpm -r run typecheck`
- Build the protocol package only: `pnpm --filter @alidade/protocol run build`
- Tauri (once set up): `pnpm --filter @alidade/app run tauri dev` / `... run tauri build`

`workspace:*` deps (e.g. `app/` → `@alidade/protocol`) resolve to local symlinks; no
registry round-trip during development.

**Protocol bindings:** regenerate TS/Python types from `alidade-protocol`, then verify no drift
(the CI drift check fails if committed generated files differ). Never hand-edit generated bindings.

---

## Conventions

**Python**
- **Full type hints on every signature**; modern syntax (`list[int]`, `X | None`). `uv run ty check`
  must pass. Avoid bare `Any` unless justified with a short comment.
- Format and lint with `ruff`.

**Rust**
- `cargo fmt` and `cargo clippy -D warnings` must be clean.
- Idiomatic error handling (`Result` + `?`); document public items. Prefer clarity over cleverness.

**Frontend**
- TypeScript **strict** mode; functional components + hooks.
- Protocol types are **generated** from `alidade-protocol` and are the source of truth — never
  hand-edit them.
- **leva is a view + input device, never a source of truth** — use the functional `useControls`
  with `set()`, and gate outbound commands on `ctx.fromPanel` (see PLAN §6).

**Commits:** Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, …) to support release
automation later.

---

## Hard invariants (do not violate — full text in PLAN §10)

1. The Rust server is the single source of truth for **document state**.
2. The **websocket protocol is the one API surface** for all clients (including the Tauri webview);
   Tauri IPC is for native-shell concerns only.
3. The protocol is **renderer-neutral and kernel-neutral**.
4. The scene is a **typed tree** with inherited transform/visibility and explicit sibling order;
   every node carries a `type` discriminator from day one.
5. Every node has a **stable addressable path**; objects carry **stable sub-entity IDs**.
6. **Document state is shared/broadcast; session (camera) state is per-client/relayed.** Highlights,
   annotations, and collision results are document state.
7. leva never owns state (see frontend conventions).
8. **Lockstep versioning**; protocol generated from `alidade-protocol` with a CI drift check.

---

## Build process

Build **phase by phase** per PLAN §9 — one GitHub issue and one PR per phase. Do not pull long-term
tier work (CAD kernel, collision, volume rendering, overlays) into the prototype phases. When a phase
introduces a new layer, follow the pedagogical mode above before moving on.
