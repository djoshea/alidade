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

## Implementation notes from Phase 0 scaffolding

The kinds of small decisions and gotchas that come up the first time you
wire this stack together.

### The React entry point (`main.tsx`)

```tsx
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";

const rootElement = document.getElementById("root");
if (rootElement === null) {
  throw new Error("missing #root element in index.html");
}

createRoot(rootElement).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
```

- **`createRoot` (React 18+).** The post-React-17 mount API. You point it at
  a DOM node (`<div id="root">` in our `index.html`) and call `.render(...)`
  with your top-level JSX. React then owns that subtree.
- **Why the `=== null` guard.** With `strict: true` in our tsconfig,
  `getElementById` returns `HTMLElement | null` — TypeScript forces us to
  handle the missing-element case. The error here would only fire if
  someone deleted `<div id="root">` from `index.html`, so a thrown error
  is appropriate.
- **`<StrictMode>` is dev-only paranoia.** In dev, it intentionally
  **double-invokes** component renders, effects, and state updaters to
  surface impure code (anything that depends on render order or has
  side effects in the render body). It does nothing in production builds.
  Leave it on always; you want those bugs found locally, not in
  prod.

### Component return type: `React.JSX.Element`

```tsx
export function App(): React.JSX.Element { ... }
```

The explicit return type isn't required — TypeScript would infer it — but
annotating it gives one extra check: if you ever return `void` or `null`
by mistake from a component, the annotation catches it at the call site
rather than two screens away. Convention varies; the project codebase
should pick one and stick with it.

### Why drop the `.tsx` from imports

We initially wrote `import { App } from "./App.tsx"`. TypeScript's default
behavior disallows `.ts`/`.tsx` extensions in import paths (TS5097) unless
`allowImportingTsExtensions: true` is set — and *that* flag requires
`noEmit: true` and conflicts with `composite: true` (project references
require emit semantics). Easiest path: drop the extension. `import "./App"`
is the conventional style anyway; the bundler and the type-checker both
resolve it to `App.tsx`.

### `vite-env.d.ts`

```ts
/// <reference types="vite/client" />
```

A **triple-slash directive** — a TypeScript-specific compiler instruction
(predates ES modules). This one pulls in Vite's ambient types so things
like `import.meta.env.MODE` (Vite injects this at build) have proper
typing in your source. Without it, `import.meta.env` would be typed as
`any` or unknown. One line per `app/`, then forget it exists.

### pnpm 11's `allowBuilds` safety feature

pnpm 11 introduced a default-deny policy on dependency install scripts.
A package's `postinstall` won't run unless its name is in
`pnpm-workspace.yaml`'s `allowBuilds:` map (or `onlyBuiltDependencies` in
package.json on older pnpm). This blocks supply-chain attacks where a
malicious transitive dep runs arbitrary code on `npm install`.

Tradeoff: some legitimate packages need their postinstall to function.
**esbuild** is one — its postinstall downloads the right native binary
for your platform. Vite depends on esbuild, so the app won't work without
it. We allow it explicitly:

```yaml
allowBuilds:
  esbuild: true
```

Audit any new `allowBuilds` entry the way you'd audit a new dependency:
what does this package's install script actually do, and do you trust it?

### `pnpm --filter`, briefly

You'll see this all over the place:

- `pnpm --filter @alidade/app run typecheck` — run `typecheck` in the
  `@alidade/app` package only.
- `pnpm -r run build` — run `build` in every workspace member that has it.
- `pnpm -F './packages/*' run build` — run `build` in every package under
  `packages/`.

The filter syntax (`--filter`, `-F`) is how you target subsets of the
workspace. It's the JS equivalent of `cargo build -p alidade-core`.

