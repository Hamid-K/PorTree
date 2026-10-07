# PorTree

A native macOS inspector for the machine's peripheral fabric: USB, Thunderbolt/USB4, PCIe, and Apple-Fabric devices rendered as one live, foldable topology graph rooted at the SoC — with the raw IORegistry depth that `ioreg` gives you and System Information doesn't.

Pure Swift + SwiftUI. Builds with SwiftPM and the Xcode Command Line Tools alone — no Xcode required, no Electron, no web views. All data comes from IOKit with live hot-plug notifications; nothing is estimated or invented.

![PorTree](docs/screenshot.png)

## Features

| Area | What you get |
|---|---|
| Topology graph | System/SoC node as the root; protocol-colored backbone links fan out to USB controllers, TB/USB4 domains, PCIe bridges, and Apple-Fabric NVMe. Foldable subtrees (+N pills), drag-to-pan, pinch / ⌘-wheel zoom anchored at the cursor, two layout directions, selectable canvas background. View state persists across launches |
| Link encoding | Color = protocol tier (USB 1.x/2.0/3.x/USB4/TB/Apple Fabric), thickness = speed, dashed = low-speed, pink companion line = video on the link (DP tunnel or DisplayLink), red = Doctor-flagged bottleneck. Speed is always printed as text too; persistent legend |
| Thunderbolt / USB4 | Native fabric tree: switches, route strings, NVM versions, trained link speed up to TB5 120 Gb/s, DP-IN vs DP-OUT adapter classification (monitors get display icons, adapters don't), cable chains |
| PCIe / NVMe | Bridges and devices with link generation + lane width from the Express registers; internal (Apple Fabric) and enclosure NVMe as storage nodes with model/firmware/serial and honest interconnect labeling |
| Port occupancy | Per-hub used/total port counts with the free port *numbers* ("free: 2, 5"), port-number labels on attached devices |
| Inspector | Five tabs per node: curated decode, the complete raw property table with hex viewer for descriptor blobs, interfaces with owning driver/pid, per-device history, live I/O chart |
| Hot-plug | Arrival glow, 4 s removal ghosts, re-enumeration collapse (unplug/replug shows one amber pulse, not ghost + new node), flood-coalesced event log persisted as JSONL |
| Baseline diff | Freeze the current state — or load a saved snapshot JSON — then compare against live after any change: added / removed / changed devices, keyed by device identity so old baselines still match. The "why is there a new HID device" button |
| Record mode | 1 Hz sampling of real byte counters (storage, network interfaces) — per-node sparklines, animated flow along busy links, aggregate traffic strip with top talkers. Devices without counters show nothing rather than estimates |
| Host summary | Measured from the registry: TB generation and per-port bandwidth, port count, USB controller count/revision, active DP tunnels; reference-table chip specs (max displays) where known, with an explicit note when a chip has no entry |
| Search | Live filter keeping ancestors, graph glow, match counter, ⌘G cycles through hits |
| Export | Snapshot JSON (⇧⌘E), graph PNG/JPEG, reproducible full-app screenshot — all also available headless (below) |
| Toolbox | Curated `ioreg` / `log` / `system_profiler` / `pmset` debugging commands with one-click copy and in-app run for the read-only ones |

## Compared

Feature rows follow the comparison table on the Hubble product page, extended with what PorTree adds. System Information is macOS's built-in viewer; `ioreg` is the raw registry CLI.

| Feature | PorTree | Hubble | System Info | ioreg |
|---|:-:|:-:|:-:|:-:|
| Graph view | ✓ | ✓ | – | – |
| Inspector panel | ✓ | ✓ | – | – |
| Live updates | ✓ | ✓ | – | – |
| Interactive | ✓ | ✓ | – | – |
| Speed-coded links | ✓ | ✓ | – | – |
| Throttle detection | ✓ | ✓ | – | – |
| Power analysis | ✓ | ✓ | – | – |
| Port occupancy / free ports | ✓ | ✓ | – | – |
| Hot-plug effects | ✓ | ✓ | – | – |
| Device nicknames | – | ✓ | – | – |
| Device eject | – | ✓ | – | – |
| Search | ✓ | ✓ | ✓ | – |
| Export | JSON·PNG·JPEG | PNG·PDF | ✓ | text |
| Native Thunderbolt/USB4 tree (TB5) | ✓ | – | partial | raw |
| PCIe · NVMe · Apple Fabric | ✓ | – | partial | raw |
| Raw IORegistry properties + hex view | ✓ | – | – | ✓ |
| Interfaces with owning driver/pid | ✓ | – | – | partial |
| Port error counters (overcurrent, enum failures) | ✓ | – | – | raw |
| Persisted event log | ✓ | – | – | – |
| Baseline snapshot diff | ✓ | – | – | – |
| Live throughput record mode | ✓ | – | – | – |
| Headless CLI (JSON / images) | ✓ | – | partial | ✓ |
| License | free, noncommercial | $9.99 | built-in | built-in |

## Diagnostics

The Doctor re-runs automatically on every topology change and grades findings as note / warning / problem. Each finding names the device, explains the cause, and is click-to-jump from the central diagnostics panel (stethoscope toolbar button with a live count).

- **Throttled by upstream link** — a device negotiated below its capability because an upstream hop is slower; the limiting link turns red
- **Hub bottlenecked by upstream** — a capable hub on a weaker link, flagged as a shared bottleneck for everything behind it
- **Uplink bandwidth oversubscribed** — the devices behind a hub can collectively demand more than its uplink carries; explicitly labeled as the theoretical worst case from negotiated speeds (record mode shows live usage), co-existing with the per-device rules
- **Below rated speed** — negotiated under provable capability with no upstream culprit (cable/port suspect)
- **TB link trained below capability** — a TB5-class port running at 40/80 Gb/s (cable or peer limit)
- **Power budget** — subtree draw vs the port's real current limit, with an early warning at 80% and a problem when oversubscribed
- **Overcurrent events** — the kernel's per-port overcurrent counter, attributed to the attached device
- **Enumeration/address failures and SuperSpeed link errors** — per-port counters since boot (flaky cable forensics)
- **Hub chain depth** — warning one tier before the controller's tier limit ("one more hub level will fail to enumerate"), problem at the limit
- **Single-TT contention** — multiple low/full-speed devices sharing one transaction translator
- **No free ports** — a fully occupied hub

Rules only fire on provable inputs; a rule that can't prove its data stays silent.

## Requirements

- macOS 15+ (registry keys verified on macOS 26/27, Apple Silicon)
- Xcode Command Line Tools (full Xcode works too; CI builds on GitHub's arm64 runners)
- No entitlements, no sudo, no TCC prompts — reading the IORegistry needs none

## Installing

Grab `PorTree-*.zip` from [Releases](../../releases) — versioned tags plus a rolling `nightly` built from every push to `main`. Builds are ad-hoc signed: right-click → Open on first launch.

## Building

```sh
make run      # build and launch (debug)
make test     # unit tests (swift-testing)
make app      # assemble ad-hoc-signed dist/Portree.app
make icon     # regenerate the app icon
```

The Makefile auto-detects the environment: on CLT-only Macs it pins `SDKROOT` and loads the swift-testing macro plugin explicitly (see [DESIGN.md §8](DESIGN.md)); with full Xcode it uses plain toolchain paths.

## CLI

Flags combine — one registry capture serves all outputs:

```sh
portree --dump > snapshot.json
portree --export-graph graph.png
portree --export-screenshot shot.png
portree --dump --export-graph g.png --export-screenshot s.png > snap.json
```

## Design notes

[DESIGN.md](DESIGN.md) documents the architecture and the IOKit data layer (registry planes, hub-twin merging via ContainerID, hot-plug notification pitfalls, TB route-string/UID decoding); [PLAN.md](PLAN.md) tracks milestones and known gaps. Two principles hold throughout: the registry is the only data source (`system_profiler SPUSBDataType` returned an empty array on the development machine while the registry held 21 devices), and nothing is displayed that can't be proven from it.

## Author

Hamid Kashfi — [@hkashfi](https://x.com/hkashfi)

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) — free to use, modify, and share for any noncommercial purpose; commercial use is not licensed. © 2026 Hamid Kashfi.
