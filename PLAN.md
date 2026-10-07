# Portree — Project Plan

A personal, fully native macOS debugging tool that shows **every attached USB and Thunderbolt/USB4 device** as a live, foldable, color-coded **hierarchy chart**, with the raw inspection depth a security professional actually needs. Pure Swift + SwiftUI, built with SwiftPM alone (no Xcode required), zero web tech.

> **Status (2026-10-07):** M1–M7 implemented and building; `make run` launches the app, `make app` produces a signed `dist/Portree.app`. Remaining COULD items: usb.ids enrichment, cross-launch replug-history persistence, PNG export, nicknames. See [DESIGN.md](DESIGN.md) for the technical design.

---

## 1. Why build this

The commercial reference ([Hubble — USB Doctor](https://apps.apple.com/us/app/hubble-usb-doctor/id6760142577?mt=12), $9.99, by gingerbeardman) is a nice zoomable USB topology graph, but its own FAQ admits two hard limitations:

1. **Thunderbolt devices appear only when acting as USB** — no native TB/USB4 fabric, no PCIe tunnels, speed tiers stop at TB3/40 Gbps.
2. **Dock-heavy / multi-tier hub layouts are a weak point.**

The development machine is exactly the worst case for both: an Apple Silicon MacBook Pro with **three Thunderbolt/USB4 buses (two TB5-class, "Up to 120 Gb/s")** and a Dell U2725QE monitor whose internal USB4206/USB7206 smart-hub fan-out is a six-tier tree. This project renders the **native Thunderbolt fabric** (domains → switches → ports, route strings, link width/generation, NVM versions, tunnels) *alongside* the USB tree, with deterministic cross-links between the two.

It also goes deeper than the reference app on inspection: full raw IORegistry property tables, hex views of descriptor blobs, driver-ownership info, a persisted event log, and replug history/diff (a practical BadUSB / retrained-link signal).

## 2. Ground truth (verified on this machine, 2026-10-07)

Everything below was **empirically proven** during research — not assumed:

| Fact | Consequence |
|---|---|
| `system_profiler SPUSBDataType -json` returns `[]` while `ioreg -p IOUSB` shows 21 devices | IOKit/IORegistry is the **sole** data source; never shell out to SP for USB |
| A plain Swift script (CLT only, unsigned, no entitlements) enumerated all devices, read all properties, and armed hot-plug notifications | No Xcode, no sandbox exceptions, no TCC prompts needed — the whole data layer is feasible as-is |
| `swift build` of a full SwiftUI app succeeds with CLT **only against `MacOSX26.sdk`** — the default 27.0 SDK's `@State` is a macro whose plugin ships only with Xcode | Every build command must pin `SDKROOT`; Makefile enforces it |
| `swift test` fails under CLT (swift-testing macro plugin not found; XCTest absent) **unless** `-Xswiftc -load-plugin-library -Xswiftc …/libTestingMacros.dylib` is passed | Makefile `test` target bakes the flag in; swift-testing (not XCTest) is mandated |
| `SDKROOT` does **not** fully propagate to test builds under the new build system (compiled against 26.5) | Makefile verifies the pin per target |
| Bare SwiftPM executables launch as background processes | `NSApp.setActivationPolicy(.regular)` + activate in the app delegate |
| TB registry uses varying concrete classes (`IOThunderboltSwitchType7`, `…IntelJHL8440`, `…Type3`) | Match **base classes** only |
| The user's fish init is broken (GVM error) and aborts compound commands | All tooling runs `/bin/bash` + `/usr/bin/swift` |

## 3. Feature set (MoSCoW, post-synthesis)

### Must
- Live USB hierarchy (controllers → hubs → devices) from the IOUSB registry plane, **including idle controllers** as roots
- **Native Thunderbolt/USB4 tree**: domains, switches, lane ports, route strings, 40G/80G/TB5-120G link speeds, NVM versions
- Hierarchy **graph view** (the hero surface): Reingold–Tilford tidy tree, foldable subtrees with "+N" pills, pan/zoom/fit
- Synced **outline view** (sidebar) sharing selection + collapse state with the graph
- Color coding: node border & edge color = protocol/speed tier; edge thickness = speed; SF Symbol = device class; speed text always visible; legend
- Inspector with four tabs: **Decoded / Raw (full property table + hex viewer) / Interfaces (incl. owning driver) / History**
- Live hot-plug: arrival glow, 4 s removal ghosts, "re-enumerated" collapse for replug of the same device
- Event log drawer: timestamped, flood-coalesced, persisted as JSONL
- Hub-twin merge (USB2+USB3 personalities of one physical hub) via ContainerID with strict guards
- Makefile build (SDK pin + verification), manual `.app` bundle, ad-hoc codesign

### Should
- **Doctor diagnostics** (the reference app's headline, all data already in hand): upstream-link throttling (red edges), device speed caps (orange), power oversubscription (`UsbPowerSinkAllocation` vs 3000 mA port limit), deep hub chains (`UsbHostControllerTierLimit` = 6), USB2 transaction-translator contention
- Receptacle cross-links (TB `Socket ID` ↔ `Port-USB-C@R` ↔ XHCI) with jump-and-flash chips; DP tunnel labeled with monitor name from EDID
- Replug history & diff with two-level identity (VID+PID+serial; location-path fallback marked low-confidence)
- Empty-port rendering + `port-statistics` error counters (connect/overcurrent/enumeration-failure)
- JSON snapshot export of both trees with full raw properties
- Search with ancestor-preserving filter and graph glow; sleep/wake rescan; ⌘R manual refresh

### Should (added 2026-10-07, user request → M7)
- **Toolbox pane**: curated USB/TB debugging commands (`ioreg` plane dumps, `system_profiler SPThunderboltDataType`, `log stream` predicates for IOUSBHostFamily/Thunderbolt, power queries) — description + one-click copy, in-app Run for read-only ones, sudo ones copy-only
- **Bandwidth overlay** (OFF by default, toggle): per-link *negotiated-vs-upstream-capacity* share, TB per-tunnel allocations (`Hop Table`, `Maximum/Required Bandwidth Allocated`, DP `LinkRate × LaneCount`)
- **PCIe layer**: enumerate `IOPCIDevice`/bridges — bus/device/function, link generation + lane width from `IOPCIExpressLinkStatus`/`LinkCapabilities` — cross-linked to the TB tunnel carrying them and to USB controllers that sit on PCIe; built-in Apple Silicon controllers labeled "SoC fabric (not PCIe)"
- **System root node**: SoC name/cores (sysctl) parenting controllers and domains

### Could
- **Live throughput sampling** (~1 Hz, only while the bandwidth overlay is on): storage via `IOBlockStorageDriver` Statistics byte counters, USB/TB NICs via their `en*` interface counters, XHCI `controller-statistics` deltas; devices without counters show "n/a" (macOS has no universal per-device byte counter; internal SoC fabric utilization has no public API — stated limitation)
- usb.ids offline vendor/product name enrichment
- Anomaly flags (HID interface on a "charger", serial change on reconnect)
- PCIe tunnel listing per TB port; `SPThunderboltDataType` async enrichment (failure-ignored)
- PNG export of the canvas; persistent nicknames

### Won't (v1)
- Endpoint-level descriptors (requires opening devices; blocked by exclusive owners) — the only reference-app-class feature deliberately dropped, reason documented
- Eject/rename device actions, sound effects, App Store distribution, sandboxing/notarization

## 4. Milestones

| # | Deliverable | Proves / acceptance |
|---|---|---|
| **M1** | Window on screen: SwiftPM scaffold, Makefile (SDK pin + verify, bash, `--show-bin-path`), activation fix, **flat live list** of all attached devices with names + speeds | The entire toolchain + data access in one step; `make run` works |
| **M2** | Real USB tree: IOUSB-plane walk with controllers as roots, interfaces, twin merge, foldable outline, colors/icons/badges, four-tab inspector, search | Tree matches `ioreg -p IOUSB` exactly; raw tab shows every key |
| **M3** | Live core: HotplugMonitor, debounced re-snapshot, entry-ID diffing, event log (+JSONL), arrival/ghost/re-enum presentation, sleep/wake rescan | Replugging a device produces correct animations and log rows; flapping is coalesced |
| **M4** | Thunderbolt native: domain trees, link speeds incl. TB5 labeling, route strings, receptacle cross-links, Type-C/cable panel, tunnel badges | The Dell U2725QE chain renders as on this machine: root → Dell (40G) → Cable Matters adapter |
| **M5** | Graph hero view: RT layout, Canvas edges (color+width), node cards, shared fold state, pan/zoom/fit done right, legend | Hierarchy chart is primary view; collapse animates; zoomed panning works |
| **M6** | Doctor + ship: diagnostics engine, replug history/diff, JSON export, `.app` bundle + icns + codesign, README/build docs | `make app` emits a signed Portree.app; diagnostics flag a real throttled device |
| **M7** | System & bandwidth: PCIe tree (gen/lanes, TB-tunnel cross-links), System/SoC root node, bandwidth overlay (allocated; live sampling best-effort), **record mode with sparklines + animated flow edges**, Toolbox pane | Overlay off by default; Dell DP tunnel shows real allocated Gb/s; record mode graphs a real file copy; toolbox runs `ioreg` in-app |

Sequencing rationale: usefulness ships early (outline + inspector by M2, live by M3); Thunderbolt is core, not stretch (M4); the graph lands once the data under it is trustworthy (M5).

## 5. Risks

| Risk | Mitigation |
|---|---|
| **SDK drift**: a CLT update could drop `MacOSX26.sdk` (the `@State`-macro workaround) | Makefile fails loudly if the SDK is missing; documented fallbacks: attribute-free `State(initialValue:)` pattern, 26.5 SDK, or install Xcode |
| **macOS 27 registry churn**: load-bearing keys (`UsbLinkSpeed`, `Link Bandwidth` semantics) are undocumented, verified on one machine | Treat every key as optional; degrade to enum speeds; Raw tab is always ground truth; empty-state self-diagnostic |
| Notification foot-guns (undrained iterators silently disarm; matching dicts are consumed) | Single `HotplugMonitor` owns all registrations; drain-on-arm in one code path; ⌘R as belt-and-braces |
| Hub-twin merge makes the tree near-DAG | Layout keys on the USB3 personality; USB2 link drawn as secondary stub; strict merge guards (class 9 + ContainerID + same controller + speed split) |
| Plug storms (one dock plug publishes dozens of nodes) | 150–200 ms debounce; full re-walk is milliseconds; event rows generated pre-debounce so nothing is lost |
| Large trees (>100 devices on loaded dock chains) | Gate glow/edge-labels by node count & zoom; virtualize only if ever needed |
| ~~Name collision~~ | Resolved: renamed to **Portree** (2026-10-07) |

## 5b. Known gaps (adversarial review, 2026-10-07)

A 10-agent review (27 findings) confirmed six majors — **all fixed** (sampler baseline keying, bcdUSB capability honesty, ghost↔arrival re-enumeration collapse across snapshots, index refresh on ghost expiry, flap coalescing, plus pinch/menu-zoom polish). Remaining accepted gaps, in rough priority order:

- USB↔TB receptacle **cross-link chips** (Socket ID ↔ Port-USB-C ↔ XHCI) and DP-tunnel monitor naming from EDID — data verified available, UI not wired
- Cross-launch **replug history** (persisted per-identity snapshots + descriptor diffing); History tab is session-scoped today — the baseline-diff feature covers the manual version of this
- `Port-USB-C` interest notifications (cable/orientation changes that add no device) and speed-retrain/TB-link-change event rows
- Twin-merge hardening for non-unique ContainerIDs; TT-contention should also read the merged USB2 personality's protocol
- Ghosts render only for the top-most removed node of an unplugged subtree
- JSONL rows persist with count 1 (flap ×N is in-memory only); `controller-statistics` live layer; receptacle naming via `UsbIOPort` instead of bus-byte heuristic
- Per-port empty-port dots drawn in the graph (occupancy counts + free port numbers shipped 2026-10-08; the per-port visual is the remainder), physical left/right port mapping, nicknames/usb.ids, per-issue ignore persistence

Closed since the review (2026-10-08): aggregate uplink oversubscription, No-Free-Ports, port occupancy + port-number labels, viewport/view-state persistence, search match counter + ⌘G, baseline snapshot diff (capture/load/save + NEW/CHANGED markers), combinable headless exports, CI nightly + release pipeline.

## 6. Open questions (decide before open-sourcing)

1. ~~**Name.**~~ **Resolved 2026-10-07: the app is named _Portree_** (port + tree). The repo folder may still be called `Hubble` locally — rename at will; nothing in the build depends on the folder name.
2. ~~**License.**~~ **Resolved 2026-10-08: PolyForm Noncommercial 1.0.0** (free personal/noncommercial use, no commercial use) — see LICENSE.md.
3. Minimum macOS for other users: code targets macOS 15+, but registry keys are verified only on 26/27 — document as "best on Tahoe+".

## 7. Deliverables in this repo

- [PLAN.md](PLAN.md) — this file
- [DESIGN.md](DESIGN.md) — full technical design (architecture, data layer, UI, build system)
- [mockup/index.html](mockup/index.html) — interactive UI mockup with this machine's real device tree
