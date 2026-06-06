# alidade

> **alidade** *(n.)* — the sighting bar of a sextant or surveying instrument,
> used to line up a distant target and take a bearing.

alidade is a 3D viewer and controller for CAD-and-volumetric scenes: a headless
Rust server owns the document state and exposes a websocket API, and thin web
clients — a browser, a Tauri desktop app, and a Jupyter widget — render and
interact with it. A Python library drives it programmatically via
[`build123d`](https://github.com/gumyr/build123d).

It is intended for planning experiments, visualizing targeted experimental
hardware, and navigating the brain.

## Status

Early development — see [docs/PLAN.md](docs/PLAN.md) for the architecture and
phased roadmap.

## License

alidade is **source-available** and **free for noncommercial use** under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md) (SPDX identifier
`PolyForm-Noncommercial-1.0.0`). This is *not* an open-source license under the
OSI definition; commercial use is not granted by this license.

Required Notice: Copyright 2026 Daniel J. O'Shea
