# alidade

A 3D viewer and controller for CAD-and-volumetric scenes. A headless Rust
server owns the document state and exposes a websocket API; thin web clients
(browser, Tauri desktop app, Jupyter widget) render and interact with it.
A Python library drives it programmatically via
[`build123d`](https://github.com/gumyr/build123d).

alidade is intended for planning experiments, visualizing targeted
experimental hardware, and navigating the brain.

Project home: <https://github.com/djoshea/alidade>

## Related packages

- **Rust binary / crate:** [`alidade`](https://crates.io/crates/alidade) on
  crates.io — `cargo install alidade`
- **Python client:** [`alidade`](https://pypi.org/project/alidade/) on PyPI
  — `pip install alidade`
- **TypeScript protocol types:**
  [`@alidade/protocol`](https://www.npmjs.com/package/@alidade/protocol) on
  npm

## License

Source-available, free for noncommercial use —
[PolyForm Noncommercial 1.0.0](https://github.com/djoshea/alidade/blob/main/LICENSE.md).
