# Portree

A native macOS debugging tool that shows every attached **USB and Thunderbolt/USB4 device** as a live, foldable, color-coded **hierarchy chart** — with the raw IORegistry depth (full property tables, hex views, driver ownership, event log, replug diffing) that `ioreg` gives you and System Information doesn't.

Pure Swift + SwiftUI. Built with SwiftPM alone — **no Xcode required**. No Electron, no Node, no web views. Data comes straight from IOKit/IORegistry with live hot-plug notifications.

> **Status: working app** (milestones M1–M7 implemented; see PLAN.md).
> - [PLAN.md](PLAN.md) — goals, feature set, milestones, risks
> - [DESIGN.md](DESIGN.md) — full technical design (architecture, IOKit data layer, UI, build system)
> - [mockup/index.html](mockup/index.html) — the original design mockup (open in any browser)

## Features

- **Hierarchy chart** rooted at the SoC: protocol-colored backbone links fan out to USB controllers, Thunderbolt/USB4 domains, and PCIe — foldable subtrees (+N pills), drag-to-pan, pinch/⌘-wheel zoom anchored at the cursor, left→right or top→down layout.
- **Native Thunderbolt/USB4 fabric**: switches, route strings, NVM versions, trained link speeds up to TB5 120 Gb/s, cable/adapter chains.
- **PCIe layer**: link generation + lane width decoded from the Express registers, tunneled devices cross-linked to the TB port carrying them.
- **Four-tab inspector**: curated decode, the *complete* raw property table with a hex viewer for descriptor blobs, interfaces with owning driver/pid, per-device history.
- **Live hot-plug**: arrival glow, 4 s removal ghosts, re-enumeration collapse (the flaky-cable signature), flood-coalesced event log persisted as JSONL.
- **Doctor**: upstream-throttling (red edge), below-rated-speed, power-budget oversubscription (Σ mA vs 3000 mA port limit), hub tier limit, single-TT contention.
- **Record mode**: 1 Hz sampling of *real* byte counters (storage, NICs) — per-node sparklines, animated flow along busy links, an aggregate traffic strip with top talkers, per-device I/O charts. Nothing is ever estimated.
- **Toolbox** (⌘T): curated `ioreg`/`log`/`system_profiler` debugging commands, runnable in-app.
- `portree --dump` prints the full snapshot as JSON for scripting; ⇧⌘E exports from the GUI.

## Why

Existing tools each miss something: System Information's USB pane is shallow (and `system_profiler SPUSBDataType` can return *nothing* while the registry is full — observed on macOS 27), IORegistryExplorer requires Xcode's Additional Tools and shows raw nodes without topology semantics, and the commercial "USB Doctor" app renders Thunderbolt devices only when they act as USB. This tool renders the **native Thunderbolt fabric** — domains, switches, route strings, 40 G/80 G/TB5-120 G links, tunnels — next to the USB tree, cross-linked.

## Building

```sh
make run    # dev
make test   # unit tests (swift-testing)
make app    # assemble ad-hoc-signed Portree.app
```

Requires macOS 15+ and the Xcode Command Line Tools (full Xcode works too). See [DESIGN.md §8](DESIGN.md) for why the Makefile pins `SDKROOT`.

## License

TBD (MIT or Apache-2.0 — see PLAN.md open questions).
