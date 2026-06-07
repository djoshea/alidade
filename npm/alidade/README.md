# alidade

A 3D viewer and controller for CAD-and-volumetric scenes. A headless Rust
server owns the document state and exposes a websocket API; thin web clients
(browser, Tauri desktop app, Jupyter widget) render and interact with it.

`alidade` (this npm package) is the **JavaScript / TypeScript client** for
the alidade server — the JS analogue of the [`alidade` Python
package](https://pypi.org/project/alidade/). Install it to drive an alidade
server from Node.js, Deno, Bun, or any browser app that wants programmatic
control beyond what the official frontend provides.

```bash
npm install alidade
```

## Status

Early — client API is under active development; only the package name and
project metadata are reserved at this version. Wire protocol types are
already published as
[`@alidade-app/protocol`](https://www.npmjs.com/package/@alidade-app/protocol).

Project home: <https://github.com/djoshea/alidade>

## Related packages

- **Rust binary / crate:** [`alidade`](https://crates.io/crates/alidade) — `cargo install alidade`
- **Python client:** [`alidade`](https://pypi.org/project/alidade/) — `pip install alidade`
- **TS protocol types:** [`@alidade-app/protocol`](https://www.npmjs.com/package/@alidade-app/protocol)

## License

Source-available, free for noncommercial use —
[PolyForm Noncommercial 1.0.0](https://github.com/djoshea/alidade/blob/main/LICENSE.md).
