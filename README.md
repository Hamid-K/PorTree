# Portree

A native macOS debugging tool that shows every attached **USB and Thunderbolt/USB4 device** as a live, foldable, color-coded **hierarchy chart** — with the raw IORegistry depth (full property tables, hex views, driver ownership, event log, replug diffing) that `ioreg` gives you and System Information doesn't.

Pure Swift + SwiftUI. Built with SwiftPM alone — **no Xcode required**. No Electron, no Node, no web views. Data comes straight from IOKit/IORegistry with live hot-plug notifications.

> ⚠️ **Status: design phase.** Implementation has not started yet.
> - [PLAN.md](PLAN.md) — goals, feature set, milestones, risks
> - [DESIGN.md](DESIGN.md) — full technical design (architecture, IOKit data layer, UI, build system)
> - [mockup/index.html](mockup/index.html) — interactive UI mockup (open in any browser)

## Why

Existing tools each miss something: System Information's USB pane is shallow (and `system_profiler SPUSBDataType` can return *nothing* while the registry is full — observed on macOS 27), IORegistryExplorer requires Xcode's Additional Tools and shows raw nodes without topology semantics, and the commercial "USB Doctor" app renders Thunderbolt devices only when they act as USB. This tool renders the **native Thunderbolt fabric** — domains, switches, route strings, 40 G/80 G/TB5-120 G links, tunnels — next to the USB tree, cross-linked.

## Building (once implemented)

```sh
make run    # dev
make test   # unit tests (swift-testing)
make app    # assemble ad-hoc-signed Portree.app
```

Requires macOS 15+ and the Xcode Command Line Tools (full Xcode works too). See [DESIGN.md §8](DESIGN.md) for why the Makefile pins `SDKROOT`.

## License

TBD (MIT or Apache-2.0 — see PLAN.md open questions).
