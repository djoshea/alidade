# alidade — Architecture & Build Plan

> **alidade** *(n.)* — the sighting bar of a sextant or surveying instrument, used to line up a
> distant target and take a bearing. Here: a tool for planning experiments, visualizing targeted
> experimental hardware, and navigating the brain.

This document captures the technology choices, their rationale, the system architecture, and a
phased plan of attack. It is the durable design context for the project; pair it with a short
root-level `CLAUDE.md` that carries day-to-day commands, conventions, and the hard invariants.

---

## 1. What we are building

A 3D viewer/controller for CAD-and-volumetric scenes, with a **headless Rust server as the single
source of truth** and **thin web clients** that render and interact. The system is driven both by
humans (in a desktop app or browser) and programmatically (from a Python library, e.g. inside a
Jupyter notebook running `build123d`).

The work is split into two scope tiers so the first does not drown in the second:

- **Prototype tier** — the learning/showcase build: Rust server + R3F/leva web client, STL and
  build123d meshes shipped from Python, a typed scene tree, selection and highlighting, and the
  multi-client plumbing (browser → Tauri desktop → notebook widget).
- **Long-term tier** — the real application: a server-side CAD kernel (opencascade-rs) for exact
  B-rep operations, collision detection with visual localization, exact measurement, volumetric
  (MRI) rendering, and convenience overlays.

---

## 2. Core architecture

### 2.1 One server owns the document; clients are views

A standalone Rust process owns all **document state** (the scene) and exposes a **websocket API**.
Every frontend — a browser tab, a Tauri desktop window, a Jupyter widget — and the Python library
are all just clients of that server. Tauri is a *delivery wrapper* for the web frontend, not a
backend: its Rust shell only creates a window and loads the frontend, which connects to the server
over `ws://localhost:<port>` like any other client.

This is the meshcat/rerun process topology. (Note: rerun's *viewer* is Rust-compiled-to-WASM with
its own renderer; we deliberately take the opposite frontend approach — see §3.2 — but the
server-plus-many-clients shape is the same.)

### 2.2 Document state vs session state

- **Document state** (server-owned, broadcast to all clients): the scene tree, geometry, transforms,
  visibility, colors, transparency, **highlights and annotations**. Highlights are document state
  even though they feel "frontend," because every viewer and every captured image must agree on them.
- **Session state** (per-client, server only relays get/set): primarily **camera/view orientation**.
  Two human viewers orbit independently; Python can still drive a specific client's camera via a
  scoped command. The server routes session commands; it does not store live camera streams.

"Rust owns the truth" is a claim about the *document*, not about ephemeral per-viewer view state.

### 2.3 The clean boundary

The websocket protocol is the single API surface for **all** clients (including the local Tauri
webview). It is defined in **renderer-neutral and kernel-neutral** terms: triangles, normals,
per-triangle entity IDs, edge polylines, points, parametric primitives, volume payloads, and
commands. Two consequences:

- The **renderer is swappable**. three.js today; a Rust/wgpu renderer later would require no server
  change, *as long as the protocol never leaks three.js-specific assumptions* (materials,
  BufferGeometry quirks, client-side raycast semantics).
- The **CAD kernel is swappable**. Tessellation/topology can start in Python and migrate into the
  server later (§3.4) without touching the protocol or the frontend.

Native-shell concerns (file dialogs, menus) are the *only* thing that uses Tauri IPC; scene state
never does.

---

## 3. Technology choices and rationale

### 3.1 Server: Rust + tokio + axum

Rust for the document model, geometry, and (later) CAD-kernel integration. `tokio` async runtime;
`axum` for the websocket server (built-in `axum::extract::ws`) and any HTTP endpoints. The server is
a library crate plus a thin binary, so the document/transport logic is testable without a socket.

### 3.2 Frontend: TypeScript + React + React Three Fiber + leva (+ drei)

- **three.js** is the most mature interactive-3D library; we explicitly do *not* want to write a
  renderer or shaders, and our CAD needs (a handful of meshes with visibility/color/transparency/
  glow) sit squarely in its comfort zone.
- **React Three Fiber (R3F)** gives a declarative scene graph: render the scene tree as components,
  and React reconciles the three.js graph when document state changes. This maps cleanly onto
  "server pushes new state → frontend reflects it."
- **leva** for the immediate-mode control panels. It integrates natively with R3F (same maintainer
  collective, pmndrs). **Critical pattern:** leva is a *view + input device*, never a source of
  truth — see §6.
- **drei** (`@react-three/drei`) supplies most convenience overlays off the shelf: grids, axes/gizmo
  helpers, `<Line>`/shape primitives, and `<Html>` for screen-anchored labels.
- **Build tool:** Vite (standard for R3F, integrates with Tauri).

**Rejected alternatives and why:** Bevy / egui+wgpu (would mean owning the renderer and an ECS or
shader learning curve we want to avoid); Dioxus/Leptos WASM (immature 3D story, clunky three.js
interop); tweakpane (fine but imperative and framework-agnostic, so more wiring in React than leva).
rerun proves the all-Rust-to-WASM path is viable, but its priorities (own renderer, demanding
point-cloud viz, one codebase native+web) are the inverse of ours.

### 3.3 Desktop & notebook delivery: Tauri + anywidget

- **Tauri** wraps the same web frontend as a native desktop app. Deferrable — the browser is a
  complete client for the prototype; add Tauri when you want a native window, an installable bundle,
  and OS integration. One config step: allow the webview to reach the localhost websocket (CSP).
- **anywidget** for the Jupyter widget: embeds the (reduced) frontend and connects to the server.
  In a notebook there are **two** independent clients of the server — the Python kernel (pushing
  geometry) and the widget's frontend (rendering); they meet at the server, not each other.

### 3.4 Python: `alidade` package + build123d; kernel starts Python-side

- The **`alidade` Python library** is a websocket client: build a model with `build123d`, tessellate
  and extract topology, and ship the bundle to the server; control document state; drive a client's
  camera; request image captures.
- **Kernel location, staged:** start with tessellation + topology extraction **in Python at creation
  time** (build123d/OCP already wraps OpenCascade), shipping mesh+topology to a kernel-free server.
  Migrate to a **server-side kernel (`opencascade-rs`)** when you need server-side STEP ingestion,
  collision, or latency-sensitive exact measurement. Because the protocol is kernel-neutral, this
  move changes neither the wire format nor the frontend.
- **Tooling:** `uv` (envs, build, publish, workspace if multiple Python packages), `ruff`
  (lint+format), `ty` (type checking).

### 3.5 Volume rendering (long-term): three.js, custom shader if needed

The raw MRI volume is the one renderable that may require a shader. We **commit to three.js doing
everything**, including a GLSL volume ray-march if no R3F-compatible volume renderer is good enough,
because integrated CAD-over-MRI needs one scene / one camera / correct depth compositing. NiiVue is
the domain reference (and excellent), but it is its own WebGL2 renderer and does *not* use three.js,
so compositing CAD meshes into it with correct occlusion is the painful seam we avoid. The "wrapped"
MRI view (STL boundary meshes, glassy material) is just meshes and needs nothing special. **Spike**
the CAD-over-volume compositing early (load one MRI + one CAD part) before building much on R3F,
since it is the one thing that could reach back and affect the renderer.

---

## 4. Repository layout (monorepo)

One repo. The deciding factor is that the wire protocol is a single contract across three
languages; a monorepo lets a protocol change update server, frontend, and client in one atomic
commit. Split a component out to its own repo only once it earns an independent release cadence.

```
alidade/
├── crates/                       # Rust workspace
│   ├── alidade-protocol/         # wire types (serde). Source of truth for the contract. Minimal deps.
│   ├── alidade-core/             # scene tree, document model, geometry-agnostic logic
│   └── alidade-server/           # the server: lib + binary `alidade`
│       └── (alidade-kernel/)     # LATER: opencascade-rs wrapper, collision, measurement
├── app/                          # TypeScript + React + R3F + leva frontend (Vite)
│   └── src-tauri/                # Tauri desktop shell (thin Rust) — its OWN Cargo project, NOT in the workspace
├── python/                       # `alidade` on PyPI: ws client + build123d integration
│                                 #   Jupyter widget as an extra: alidade[jupyter] (anywidget)
├── examples/                     # sample scripts and scenes
├── docs/
│   └── PLAN.md                   # this document
├── CLAUDE.md                     # auto-loaded: commands, conventions, invariants
└── .github/workflows/            # path-filtered CI + tag-driven release
```

**Name availability (checked):** `alidade`, `alidade-protocol`, `alidade-core`, `alidade-server`,
`alidade-kernel` are all free on crates.io; `alidade` is free on PyPI and npm. The bare `alidade`
does double duty as the server binary (`cargo install alidade`) and the Python package
(`pip install alidade` / `import alidade`).

---

## 5. Versioning, CI, and release

- **Lockstep versioning:** the whole repo carries one version; all artifacts publish at that version
  together. Matching version ⇒ guaranteed-compatible protocol across server/client/frontend. Rust
  crates inherit it via `[workspace.package]` (`version.workspace = true`); the Python
  `pyproject.toml` version is the one other field to bump.
- **CI (GitHub Actions, path-filtered):** `rust` (fmt, clippy, test), `python` (ruff, ty, pytest),
  `frontend` (typecheck, build). A **protocol-drift check** regenerates TS/Python types from
  `alidade-protocol` and fails if the committed generated files differ (see §7).
- **Release (tag-driven):** pushing `vX.Y.Z` publishes crates **in dependency order**
  (protocol → core → server) to crates.io, then `uv build` / `uv publish` to PyPI. Graduate to
  `release-plz` (Rust) and/or `release-please` (polyglot, linked versions) when cadence warrants.
- **Claim names early:** publish stub `0.0.0` releases to crates.io and PyPI before there is real
  code, to hold the names and prove the publish pipeline end-to-end.

---

## 6. State synchronization (the leva loop)

leva must be demoted from *owner* to *view + input device*, or it becomes a second source of truth.

- Use the **functional form** of `useControls` to get an imperative `set()`. When the server pushes
  new document state, call `set()` to update what the panel *displays* — leva mirrors, never masters.
- Gate outbound commands on **`ctx.fromPanel`** in `onChange`: `true` means a real user edit (send a
  command to the server), `false` means your own programmatic `set()` (do nothing). This breaks the
  echo loop.

Data flow is one circle: `server document → (ws event) → React mirror → leva via set() →
user edits panel (fromPanel) → command via ws → server updates document → loops`. Server-originated
changes (an algorithm, the Python client) enter at the top and reach the panel identically.

Start **pessimistic** (panel reflects server confirmation; sub-ms over localhost). For a
*continuously dragged* control (global transparency), if a slow/remote round trip makes it feel
laggy, let leva hold the value optimistically *during* the drag and reconcile on release — a
frontend-only concern that never touches "server owns the document."

---

## 7. Wire protocol & data model

### 7.1 Principles

- **Renderer-neutral and kernel-neutral** (§2.3).
- **Addressable paths** for every node (`/world/assembly/part`), giving hierarchy, grouping, and
  "layers" for free. Sub-entities (faces/edges/vertices) carry stable IDs within an object.
- **Upload/parameter split:** heavy geometry (meshes, volumes) is uploaded rarely; cheap property
  changes (visibility, color, transform, slice plane, highlight) are small frequent messages.
- **Binary for geometry:** packed `f32`/`u32` buffers, not JSON; the client wraps them as typed
  arrays straight into `BufferGeometry`.
- **Protocol source of truth** is the `alidade-protocol` crate. Generate TypeScript via `ts-rs`;
  generate Python types via `schemars` → JSON Schema → pydantic (or hand-maintained pydantic
  validated against the schema in CI). The drift check keeps all three honest.

### 7.2 The heterogeneous, typed scene tree

The scene is a **tree** (not a flat set). Three commitments are baked in from the start because they
are painful to retrofit:

1. **Tree with inheritance** — a group's transform and visibility cascade to its children.
2. **A `type` discriminator on every node** — even while `mesh` is the only type, so adding
   `volume`, `primitive`, `label`, etc. later is a new handler, not a schema break.
3. **Explicit sibling order** — required for correct transparency (alpha compositing is
   order-dependent).

Node types (mesh is the prototype's only one; the rest are deferred handlers behind the discriminator):

- `group` — internal node; folders, layers, and **assemblies** (a group with CAD semantics).
- `mesh` — triangles + normals + per-triangle face IDs, plus a `topology` block.
- `volume` — a 3D scalar field (MRI); density ray-march or slice-plane views.
- `primitive` — **parametric** shapes (`{kind: cylinder, radius, height, transform}`), instantiated
  client-side, *not* shipped as tessellations.
- `label` — a screen-space annotation (see §7.4).
- helpers — `axes`/gizmo, `grid` (drei-backed).

### 7.3 Object topology (for B-reps; degraded for STL)

A B-rep's topology *is* the logical model; the mesh is a derived artifact. OpenCascade hands us the
mapping: it tessellates per-face (`Poly_Triangulation` per `TopoDS_Face`) and gives per-edge
polylines (`Poly_PolygonOnTriangulation`). So:

```
Object {
  id, path
  provenance: Brep | Mesh
  display_mesh: { vertices, normals, triangles, triangle_face_ids[] }   // render + picking
  topology: {
    faces:    [{ id, surface_type, area, metadata, label? }]
    edges:    [{ id, curve_type, length, polyline:[pt], adjacent_face_ids }]
    vertices: [{ id, point, adjacent_edge_ids }]
  }
  exact_geometry: <server-side handle to the real B-rep>                 // measurement; never sent
}
```

- **Faces** = triangle sets tagged with a face ID (highlight = recolor those triangles).
- **Edges** = exact polylines with IDs, drawn as line overlays (not triangle edges).
- **Vertices** = exact points with IDs, drawn as markers.
- **STL** has no topology: object-level selection is free; face/edge/vertex selection is
  *reconstructed heuristically* (merge coincident verts; region-grow faces by dihedral angle; flag
  feature edges) and is approximate by nature. Same `topology` interface, populated differently.

### 7.4 Annotation labels are a screen-space subsystem

A label's existence and anchor point are **document state**; its resolved 2D position depends on the
current camera (**session-derived**); the de-overlap layout is a per-camera-change label-placement
computation. Do not store screen positions in the document. Use drei `<Html>` for the DOM box +
leader line; build the de-overlap layout on top.

---

## 8. Selection, picking, and measurement

- **Selection filter** (object / face / edge / vertex modes): the same ray hit resolves differently
  per active mode — face mode → the hit triangle's face ID; edge mode → nearest edge polyline;
  vertex mode → nearest vertex; object mode → the node (with **escalation** for assemblies:
  click → part, click again/modifier → parent group). Selection resolves to *any* tree level.
- **Picking:** start with three.js raycasting → hit triangle → `face_id` via a lookup table →
  send `{path, kind, entity_id}`. Scale to GPU **ID-buffer picking** (unique color per entity to an
  offscreen target) only if dense scenes demand it. Edges/vertices pick against their overlays.
- **Highlights are document state** set by the server and broadcast — so a **computed collision** and
  a **manual highlight** flow through the *same* channel; collision is "the server writes the
  highlight automatically," not a new subsystem.
- **Measurement is server-side, on exact geometry.** Route *all* measurement through the server (even
  trivial vertex–vertex) for one code path that always uses exact geometry. Min distance / closest
  point via OpenCascade `BRepExtrema_DistShapeShape`. The server owns transforms too, so it always
  has the *placed* shapes the math needs.

---

## 9. Phased plan of attack

Each phase is a working, demoable deliverable and teaches one layer. Suggested: one GitHub issue per
phase, one PR per phase.

### Prototype tier

- **Phase 0 — Foundations.** Monorepo, Cargo workspace, `uv` Python project, Vite app skeleton. CI
  (rust fmt/clippy/test; ruff/ty/pytest; frontend typecheck/build). Stub `0.0.0` publishes to claim
  names and prove the release pipeline. `alidade-protocol` skeleton + ts-rs / JSON-Schema codegen +
  drift check. *Teaches:* the whole toolchain and release path before any features.

- **Phase 1 — Hello transport.** axum websocket server + a minimal browser page that connects,
  sends one message, and receives a reply. *Teaches:* the ws round trip and the message envelope.

- **Phase 2 — Static R3F scene.** React + R3F + leva; hardcoded boxes; `OrbitControls`; one leva
  panel. No server data. *Teaches:* the declarative scene graph and camera controls.

- **Phase 3 — Server-driven mesh.** Server reads an STL, sends a binary mesh over ws; client builds
  `BufferGeometry` and renders it. *Teaches:* binary IPC, STL parsing, BufferGeometry.

- **Phase 4 — Scene tree + state sync.** Typed scene tree as server document state; client renders
  the tree; leva controls (visibility, per-object color, global transparency) wired through the
  server with the `set()`/`fromPanel` loop (§6). Camera kept client-local (document/session split).
  Add/remove/update nodes pushed from server to client. *Teaches:* the state architecture and the
  tree model.

- **Phase 5 — Python client.** `alidade` package: ws client; `build123d` → tessellate + extract
  topology in Python → ship mesh+topology under a path; add/update/remove **in place** by path.
  *Teaches:* the programmatic-control story and addressable paths.

- **Phase 6 — Selection & highlight.** Selection filter; raycast → entity IDs; server resolves and
  sets highlight (document state) + broadcasts; metadata display; glow via
  `@react-three/postprocessing` (bloom on the highlighted set). *Teaches:* picking and the
  highlight channel.

- **Phase 7 — Tauri desktop client.** Wrap the existing frontend; native window; CSP allows the
  localhost ws. *Teaches:* Tauri as a delivery wrapper.

- **Phase 8 — Jupyter widget.** anywidget embedding the (reduced) frontend; the two-clients-meet-at-
  the-server pattern. *Teaches:* notebook embedding.

- **Phase 9 — Image capture.** Capture from a live frontend (canvas / `readRenderTargetPixels`
  readback) round-tripped to Python. *Teaches:* the binary-return round trip. (Robust headless
  capture via a captive frontend is a later upgrade.)

### Long-term tier (post-prototype)

- **Server-side kernel** — integrate `opencascade-rs`; migrate tessellation/topology and add
  server-side STEP ingestion. Verify the crate's current API coverage and maintenance at adoption;
  budget for OpenCascade boolean robustness (fuzzy tolerances, defensive failure handling).
- **Collision detection** — broad-phase (bounding volumes) then narrow-phase. Start with a
  **triangle-BVH on the meshes you already store** (no kernel needed) for interactive "roughly here"
  glow; upgrade to exact OpenCascade `Section` (contact curves) or `Common` (interpenetration
  volume) for precise localization. Result flows through the highlight channel (glow red).
- **Exact measurement** — `BRepExtrema_DistShapeShape` and friends, server-side.
- **Volume rendering (MRI)** — three.js volume ray-march (custom shader if needed) + slice planes;
  wrapped-view meshes; do the early compositing spike (§3.5).
- **Convenience overlays** — drei grids/gizmos/axes; parametric primitives; screen-space annotation
  labels with de-overlap (§7.4).
- **Assemblies** — multi-part groups with per-part materials and selection escalation.

---

## 10. Locked invariants (do not violate)

1. The Rust server is the single source of truth for **document state**.
2. The **websocket protocol is the one API surface** for all clients, including the local Tauri
   webview. Tauri IPC is for native-shell concerns only.
3. The protocol is **renderer-neutral and kernel-neutral**.
4. The scene is a **typed tree with inherited transform/visibility and explicit sibling order**;
   every node carries a `type` discriminator from day one.
5. Every node has a **stable addressable path**; objects carry **stable sub-entity IDs**.
6. **Document state is shared and broadcast; session (camera) state is per-client and relayed.**
   Highlights/annotations/collision results are document state.
7. leva is a **view + input device**, never a source of truth (`set()` + `fromPanel`).
8. **Lockstep versioning**; protocol is generated from `alidade-protocol` with a CI drift check.

---

## 11. Open decisions / spikes

- **Volume-renderer compositing spike** (do early): confirm CAD-over-MRI depth compositing in
  three.js before building heavily on R3F.
- **Kernel migration timing:** when server-side STEP/collision/measurement justifies pulling
  `opencascade-rs` (vs a Python/OCP sidecar) into the server.
- **Continuous-slider transport:** pessimistic to start; optimistic-during-drag only if a slider
  feels laggy.
