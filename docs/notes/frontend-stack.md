# Frontend stack: Vite + React + TypeScript + pnpm workspaces

Captured while scaffolding `app/` and `packages/protocol/` in Phase 0. The
choice was: a thin TypeScript/React/R3F web client over a Rust websocket
server (see [docs/PLAN.md §3.2](../PLAN.md)).

## The four pieces

### 1. Vite

A modern build tool with two distinct modes:

- **Dev (`pnpm dev`)**: Vite starts a server that serves your source files
  *as native ES modules* directly to the browser. Your
  `<script type="module" src="/src/main.tsx">` triggers the browser to
  request that file; Vite transforms it on the fly (TSX → JS, JSX → React
  calls, etc.) and returns the result. **No bundling happens up front**, so
  dev startup is near-instant regardless of project size. Hot Module
  Replacement (HMR) is built in — edit a `.tsx`, the browser updates without
  reloading.
- **Build (`pnpm build`)**: Vite *does* bundle, using Rollup under the hood,
  producing a `dist/` folder of static assets you can deploy anywhere.
  Tree-shaking, minification, code-splitting all happen here.

Mental model: **dev = browser does most of the work**, asking Vite for
individual files; **build = Rollup produces a real bundle** for production.

`@vitejs/plugin-react` is the plugin that teaches Vite how to handle React's
JSX and Fast Refresh.

### 2. React (functional + hooks, no classes)

Modern React is built from **function components**. A component is a plain
function that returns JSX:

```tsx
function App() {
  return <div>alidade — phase 0</div>;
}
```

**JSX is not HTML.** It's syntactic sugar that the compiler rewrites into
`React.createElement("div", null, "...")` calls. Two consequences:

- Attributes use camelCase: `className` (not `class`), `onClick` (not
  `onclick`).
- `{...}` inside JSX is an *expression* slot — anything that evaluates to a
  value goes there.

**State and effects come from hooks** — `useState`, `useEffect`, etc. Hooks
are the unit of reusable logic in modern React; older classes-and-lifecycle
style is dead. We don't need any hooks in Phase 0 (no state), but they'll
show up everywhere once we wire up the websocket client.

**Rendering:** `ReactDOM.createRoot(elem).render(<App />)` mounts your
top-level component into the DOM. React then *reconciles* — when state
changes, React re-runs the component function, diffs the returned JSX
against the previous render, and patches the DOM minimally.

**This is why R3F maps so cleanly onto our architecture.** React Three
Fiber does the exact same thing but with a three.js scene graph instead of
the DOM. "Server pushes new document state → React reconciles the scene
graph → three.js updates" is one mechanical pipeline, not a custom adapter
per node type.

### 3. TypeScript strict mode

The `tsconfig.json` flags worth knowing:

- `strict: true` — turns on the whole strict family at once
  (`strictNullChecks`, `noImplicitAny`, `strictFunctionTypes`, etc.). Most
  important: `string | null` and `string` are now *different types*; you
  have to handle the null case explicitly. This one knob separates
  "TypeScript catches real bugs" from "TypeScript is a slightly fancier
  IDE."
- `noUncheckedIndexedAccess: true` — `arr[0]` returns `T | undefined`, not
  `T`. Catches the "what if the array's empty" case.
- `verbatimModuleSyntax: true` — forces `import type { Foo }` when
  importing only types. Prevents bundler edge cases.
- `isolatedModules: true` — required for Vite (and any bundler that compiles
  files independently). Each `.ts` file must be analyzable on its own.
- `moduleResolution: "Bundler"` — tells TS to resolve `import` paths the way
  a bundler does, not the way Node does.
- `jsx: "react-jsx"` — uses the new JSX transform (no need to `import React`
  at the top of every file).

The protocol package (`packages/protocol/`) and the app (`app/`) share the
same strict baseline. We get type-checking via `tsc --noEmit` separately
from Vite's transpilation — TS type errors don't block dev (you'd want
them to show up but not block iteration), but they fail CI.

### 4. pnpm workspaces

The `app/package.json` declares:

```json
"dependencies": {
  "@alidade/protocol": "workspace:*"
}
```

`workspace:*` tells pnpm: resolve this from a workspace member, not the npm
registry. Locally, `app/node_modules/@alidade/protocol` becomes a symlink
to `packages/protocol/`. When publishing a workspace member to npm, pnpm
rewrites `workspace:*` to a real version range.

Concrete consequences:

- Edits to `packages/protocol/src/*` are visible to `app/` immediately, no
  install step. (You may need to re-run `tsc` in the protocol package so
  `dist/` is up to date.)
- The workspace has *one* `pnpm-lock.yaml` at the root, covering every
  member. Don't add per-package lockfiles.
- `pnpm -r run <script>` runs `<script>` in every workspace member that
  defines it. `pnpm --filter <pkg> run <script>` targets one.

This is the JS analogue of Cargo's workspace path-deps.

## Why this stack vs. alternatives

Brief reasoning, lifted from [docs/PLAN.md §3.2](../PLAN.md):

- **three.js + R3F** — most mature interactive-3D library; we explicitly
  don't want to write a renderer or shaders. R3F gives the declarative
  scene graph that maps onto server-pushed state.
- **leva** for control panels — first-class R3F integration; the critical
  pattern is that leva is a *view + input device*, never a source of truth
  (PLAN §6).
- **Vite** is the standard build tool for R3F projects and integrates with
  Tauri later.

Rejected: Bevy / egui+wgpu (own-the-renderer overhead), Dioxus/Leptos WASM
(immature 3D story, clunky three.js interop). rerun's all-Rust-to-WASM
path is viable but its priorities are the inverse of ours.

## What's in `app/` for Phase 0

```
app/
  package.json        # name, scripts, deps
  tsconfig.json       # strict TS for src/
  tsconfig.node.json  # separate config for vite.config.ts (Node context)
  vite.config.ts      # Vite + @vitejs/plugin-react
  index.html          # the page Vite serves
  src/
    main.tsx          # React entry point
    App.tsx           # one tiny component
    vite-env.d.ts     # ambient types for Vite's import.meta.env, etc.
```

Why two `tsconfig` files: `vite.config.ts` runs in Node (during build), but
`src/*.tsx` runs in the browser. They need different `lib`, `module`, and
`types` settings. The root `tsconfig.json` references both via TS project
references — `tsc --noEmit` then checks both worlds with their own rules.
