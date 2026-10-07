# Portree — Technical Design

Native macOS USB/Thunderbolt topology debugger. Swift 6 + SwiftUI, SwiftPM-only build (no Xcode), IOKit/IORegistry as the sole data source. This document is the normative spec; every claim marked **[verified]** was empirically proven on the target machine (macOS 27.0.1, Apple Silicon, Swift 6.4, Command Line Tools only) during the research phase.

---

## 1. Architecture

One SwiftPM package, two targets:

```
Portree/   (repo folder may still be named Hubble locally)
├── Package.swift                 # swift-tools-version 6.x, platforms: [.macOS(.v15)]
├── Makefile                      # ALL builds go through here (SDK pin, bash, test flags)
├── Sources/
│   ├── PortreeCore/               # Library — no UI, headless-testable
│   │   ├── RegistryReader.swift      # thin IOKit wrappers (matching, plane walks, props)
│   │   ├── USBTopologyBuilder.swift  # IOUSB-plane walk → USBNode tree
│   │   ├── TBTopologyBuilder.swift   # TB domain walk → TBNode tree
│   │   ├── CrossLinker.swift         # receptacle / PCIe / DP tunnel correlation
│   │   ├── HotplugMonitor.swift      # IONotificationPort owner, debounce, event rows
│   │   ├── Model.swift               # Snapshot, USBNode, TBNode, InterfaceInfo, PropertyValue
│   │   ├── DiffEngine.swift          # snapshot diff by registry entry ID
│   │   ├── Doctor.swift              # diagnostics (throttle, power, deep chain, TT)
│   │   ├── Identity.swift            # two-level device identity for history
│   │   ├── Format.swift              # speed/UID/NVM/class formatters (unit-tested)
│   │   └── Exporters.swift           # JSON snapshot export, JSONL event log
│   └── PortreeApp/                # Executable — SwiftUI
│       ├── PortreeApp.swift           # @main, @NSApplicationDelegateAdaptor
│       ├── AppStore.swift            # @Observable @MainActor store
│       ├── OutlineView.swift         # sidebar outline
│       ├── GraphView.swift           # hierarchy chart (hero surface)
│       ├── TreeLayout.swift          # Reingold–Tilford layout (pure function)
│       ├── InspectorView.swift       # 4-tab inspector
│       ├── EventLogView.swift        # bottom drawer
│       ├── HexView.swift             # OSData blob viewer
│       └── Theme.swift               # colors, SF Symbols, legend
├── Tests/PortreeCoreTests/        # swift-testing (NOT XCTest — absent from CLT)
├── mockup/index.html             # static UI mockup (design artifact)
├── PLAN.md  DESIGN.md  README.md
└── scripts/make-app.sh           # .app bundle assembly
```

### Data flow (strictly one-way)

```
IOKit callbacks (serial DispatchQueue)        MainActor
┌──────────────────────────────────┐   ┌─────────────────────────────┐
│ HotplugMonitor                   │   │ AppStore (@Observable)      │
│  drain iterators → event rows ───┼──▶│  eventLog (append, coalesce)│
│  poke debouncer (200 ms)         │   │                             │
│  rescan → immutable Snapshot ────┼──▶│  snapshot (withAnimation)   │
└──────────────────────────────────┘   │  diff → arrivals/ghosts     │
                                       │  selection, collapsedIDs,   │
   views never touch IOKit             │  searchText, zoom           │
                                       └──────────────┬──────────────┘
                                                      ▼
                                       OutlineView · GraphView · Inspector
```

**Concurrency model.** Exactly two isolation domains. A dedicated serial `DispatchQueue` owns the `IONotificationPort` and *all* IOKit calls; `MainActor` owns all mutable UI state. Only `Sendable` snapshot structs cross between them. The C notification callbacks receive context through an `Unmanaged` refcon box and do only two things: drain their iterator (generating event rows) and poke the debouncer. Never patch the tree in place — any event triggers a **debounced (200 ms) full re-snapshot** (milliseconds for ~50 nodes; race-free by construction).

**Sendable property bags.** `[String: Any]` is not Sendable and cannot cross to MainActor under Swift 6 language mode. Properties are converted **on the IOKit queue** into:

```swift
enum PropertyValue: Sendable, Codable, Hashable {
    case string(String), int(Int64), double(Double), bool(Bool)
    case data(Data)                       // JSON-exported as base64; hex in UI
    case array([PropertyValue]), dict([String: PropertyValue])
}
```

This also fixes JSON export of OSData blobs (`UsbDeviceSignature`, `DROM`, EDID): **base64 in exports, hex viewer in UI**.

---

## 2. Data layer — USB

### 2.1 Enumeration

- **Walk the IOUSB plane recursively from `IORegistryGetRootEntry`** (`IORegistryEntryGetChildIterator` over `kIOUSBPlane` = `"IOUSB"`). This yields **controllers as roots even when idle** — device-only matching (`IOServiceMatching("IOUSBHostDevice")` + parent walks) would lose the two idle receptacle XHCIs on this machine. **[critique fix, M1-blocking]**
- The IOUSB plane reproduces `ioreg -p IOUSB` topology exactly (controllers → hubs → devices). **[verified]**
- One `IORegistryEntryCreateCFProperties` call per node captures everything; CF numbers bridge as proper 64-bit values. **[verified]**
- **Interfaces** are IOService-plane children of each device passing `IOObjectConformsTo(_, "IOUSBHostInterface")` (23 on this machine). One extra level of detail: class triple, endpoint count, `bAlternateSetting`, and `UsbExclusiveOwner` (owning driver/pid — prime debug info). Interfaces appear **in the inspector's Interfaces tab as primary**, with an optional outline toggle; never in the graph. They share the device's selection/search identity. **[critique fix]**
- **No endpoint level in v1**: endpoint descriptors are not registry properties; reading them requires `IOServiceOpen`, which fails when an exclusive owner holds the device.
- No entitlements, sandbox exceptions, sudo, or TCC are needed for any of this. **[verified]**

### 2.2 Key properties (observed key set)

Identity: `idVendor`/`idProduct`/`bcdDevice`/`bcdUSB` (BCD), `USB Product Name`, `USB Vendor Name`, `USB Serial Number` (**present only when `iSerialNumber != 0` — 3 of 21 devices here**), `kUSBContainerID`, `USB Address`, `sessionID` (changes on every replug), `locationID`.

Link: `UsbLinkSpeed` (**Int64 bits/s — the authoritative speed**), `USBSpeed` (enum, see below), `Device Speed` (legacy enum), `USBPortType` (0 Standard, 1 Captive, 2 Internal, 3 Accessory, 5 USB-C), `UsbTunnel` (= Yes ⇒ reached via USB4/TB tunnel).

Power/ownership: `UsbPowerSinkAllocation` (mA from Vbus), `UsbExclusiveOwner`, `IOPowerManagement`. The legacy `Requested Power`/`Available Power`/`PortNum` keys **do not exist** on this OS; port power ceilings (`kUSBWakePortCurrentLimit` = 3000 mA) and `port-statistics` (connect/overcurrent/enumeration-failure counters) live on IOService-plane port objects (`usb-drd*-port-hs/-ss`, `AppleUSB20HubPort`) — read from there, where empty ports are also visible.

Controllers carry `UsbHostControllerProtocolRevision`, `controller-statistics`, `UsbHostControllerTierLimit` (= 6).

### 2.3 Reference tables (in `Format.swift`, unit-tested)

**`USBSpeed` (tIOUSBHostConnectionSpeed): 0 None, 1 Full 12 M, 2 Low 1.5 M, 3 High 480 M, 4 SuperSpeed 5 G, 5 SS+ 10 G, 6 SS+ 20 G.** Note Full/Low are **swapped** vs legacy `Device Speed` (0 Low, 1 Full, 2 High, 3 Super, 4 Super+). Prefer formatting `UsbLinkSpeed` directly; enums are cross-checks only.

**Class codes** (device & interface): 00 composite, 01 Audio, 02 CDC-Control, 03 HID, 06 Still Image/PTP, 07 Printer, 08 Mass Storage, 09 Hub, 0A CDC-Data, 0E Video/UVC, E0 Wireless, EF Miscellaneous, FF Vendor.

**`locationID`** = `0xBBPPPPPP`: top byte = bus, then one nibble per hub tier = port (matches ioreg `@address`). Display-only — topology always comes from parent chains (a nibble cannot express ports > 15).

**Int64 trap [verified]:** `String(format: "%d", int64)` silently truncates 10_000_000_000 to 32 bits. All formatting goes through interpolation-based helpers with fixture tests (10 Gbps, Dell UID).

### 2.4 Hub-twin merge (strict guards) **[critique-tightened]**

A USB3 hub is two logical devices (USB2 + USB3 personalities in parallel subtrees — the Dell's entire fan-out). Merge into one visual node only when **all** hold:
1. both nodes have `bDeviceClass == 9`,
2. identical `kUSBContainerID` (absent on 3/21 devices → no merge, show both + link chip),
3. same controller,
4. one personality on a ≤ 480 M link and the other on ≥ 5 G.

Merging is **per-tier and recursive**; a merged card's children = the **union** of both personalities' children (Keychron hangs off the USB2 twin, the X-T5 off the USB3 twin — both appear under one card). The **USB3 personality's registry entry ID is canonical** for selection, collapse state, search, and cross-links; the card shows both link stubs with their speeds. Layout stays a strict tree keyed on the USB3 twin; the USB2 link is drawn as a secondary stub (accepting minor edge crossings rather than adopting a general graph-layout engine).

---

## 3. Data layer — Thunderbolt/USB4

### 3.1 Enumeration **[verified]**

Match **base classes only** — concrete classes vary per device (`IOThunderboltSwitchType7` = Mac root switch, `IOThunderboltSwitchIntelJHL8440` = Dell U2725QE, `IOThunderboltSwitchType3` = Cable Matters adapter):
`IOServiceMatching("IOThunderboltSwitch" | "IOThunderboltPort" | "IOThunderboltController" | "IOThunderboltLocalNode")`.

Registry chain per bus: `acioN` → `AppleThunderboltHALType7` → `AppleThunderboltNHIType7` → `IOThunderboltControllerType7` → NHI `IOThunderboltPort@7` → root `IOThunderboltSwitchType7` → host lane `IOThunderboltPort@N` → *child* `IOThunderboltPort` (device's upstream port) → device switch → repeat. Build the tree from registry parent/child relations, cross-checked by `Depth` / `Route String` / `Upstream Port Number`.

Caveat: `ioreg -c` does **not** filter on this build (prints the whole tree) — never conclude a class is absent from ioreg output; kernel matching works.

### 3.2 Semantics

- **Route string**: one byte per hop, LSB first — Dell = `0x1` (root port 1), Cable Matters = `0x301` (port 3 on the Dell → port 1 on root). ioreg prints decimal, system_profiler hex.
- **UID**: signed CFNumber — reinterpret bit-pattern as UInt64 (Dell −9185171858847104256 = `0x8087B6DC08810300`). **NVM version** = `hex(ROM Version)).(EEPROM Revision)` (68,3 → "44.3").
- **Speeds**: live speed from lane-port `Link Bandwidth` (unit 0.1 Gb/s: 400 = 40G active, 800, 1200 = TB5 capability). `Supported Link Speed` 14 ⇒ TB5-class ("Up to 120 Gb/s"), 12 ⇒ 40G-class. Active 40G = `Current Link Speed 4` + `Width 2`. Display raw numbers when unmapped — **never hardcode exhaustive enums**.
- **Adapter types**: 1 lane, 2 NHI, 0 inactive, 917761/2 DP in/out, 1048833/4 PCIe down/up, 2097409/10 USB3 down/up, 2162945 USB "Gen T" down.

### 3.3 Cross-links (deterministic) **[verified]**

- **Receptacle**: TB root lane port `Socket ID` R ↔ `Port-USB-C@R` (AppleHPM) ↔ XHCI root port's `UsbIOPort` registry path → that receptacle's USB subtree. Exact.
- **PCIe tunnels**: tunneled `IOPCIDevice` has `IOPCITunnelled = Yes` and `Thunderbolt Entry ID` = registry entry ID of the providing TB port (`IORegistryEntryIDMatching`). Exact.
- **DP tunnels**: `Port-USB-C@R/CIO/DisplayPort@N` carries `Tunneled = Yes`, monitor **ProductName + full EDID**, LinkRate/LaneCount, HPD — label DP tunnels with the actual monitor name.
- **Type-C extras** from `Port-USB-C@R`: cable e-marker (SOP': vendor, "Active Cable"), `PlugOrientation`, `CableGeneration/Speed` — surfaced in the inspector's Thunderbolt section.
- Per-device attribution inside a monitor/dock's internal hub fan-out uses the switch's `USB Port Map` — **best-effort, labeled approximate in UI**.

USB and Thunderbolt render as two root sections joined by tappable cross-link chips (jump to and flash the counterpart node).

---

## 4. Hot-plug engine

```swift
let port = IONotificationPortCreate(kIOMainPortDefault)!   // retained for app lifetime
IONotificationPortSetDispatchQueue(port, ioQueue)
// USB:          kIOFirstMatchNotification + kIOTerminatedNotification   [verified kr=0]
// Thunderbolt:  kIOFirstPublishNotification + kIOTerminatedNotification [verified]
//               on IOThunderboltSwitch AND IOThunderboltPort
```

Rules (each one verified the hard way):
1. Every `IOServiceAddMatchingNotification` **consumes its matching dict** — create a fresh dict per call.
2. A notification does not fire until its iterator is **drained**; the first drain **is** the initial population. Callbacks must drain to re-arm.
3. Iterators + port are retained for the app's lifetime; refcon (`Unmanaged` box) carries context into the C callback.
4. USB uses `kIOFirstMatch…`; **TB classes use `kIOFirstPublish…`** — do not copy the USB constant to M4. **[judge fix, normative]**
5. Additional wake sources: `Port-USB-C@R` **general-interest notifications** (cable/orientation/tunnel changes that add/remove no switch) and `NSWorkspace.didWakeNotification` → rescan. **[critique fix]**
6. Any event → 200 ms-debounced full re-snapshot. ⌘R forces one (belt-and-braces against silent disarm).

### Event log mechanics **[critique fix]**

- Rows are generated from the **raw iterator drains, before the debounce** — bounce storms coalesce the *rescan*, never the log.
- A device flapping ≥ 3 times in 3 s coalesces to one row with "×N"; in-memory ring capped at 2 000 rows.
- Persistence: JSONL at `~/Library/Application Support/Portree/events.jsonl`, 5 MB rotation, one file kept.
- Row types: connected, disconnected, **re-enumerated** (see below), speed-retrain, TB link change, rescan.

### Arrival / ghost / re-enumeration presentation **[critique fix]**

The store replaces the tree wholesale, so transient presentation is an overlay:
- **Arrivals** (entry ID in new − old): scale+opacity transition + 1.5 s accent glow (animated shadow).
- **Removals** (old − new): node kept as a **ghost overlay** for 4 s — 40 % opacity, strikethrough, `xmark.circle` — layout keeps the slot, then collapses animated.
- **Replug of the same device** = terminate + publish with *new* entry ID and sessionID. When a ghost's device-identity (§6) matches an arrival within the ghost window, collapse both into a single **"re-enumerated"** presentation (amber pulse) and one log row — this is the most common flaky-cable signature and must not render as ghost + new node side by side.

---

## 5. Doctor diagnostics **[critique fix — reinstated as SHOULD]**

All inputs already exist in the captured data; each diagnosis renders as an edge/node tint plus an inspector callout:

| Diagnosis | Rule | Visual |
|---|---|---|
| Upstream throttling | `UsbLinkSpeed` < device capability (from `bcdUSB`/`USBSpeed`) **and** some upstream link < device capability | **red edge** on the limiting link |
| Device speed cap | device negotiated its own max but below port capability | **orange node border** |
| Power oversubscription | Σ `UsbPowerSinkAllocation` of a port's subtree vs `kUSBWakePortCurrentLimit` (3000 mA) | red power badge |
| Deep hub chain | tier depth vs `UsbHostControllerTierLimit` (= 6) | warning badge on chain |
| TT contention | multiple Full/Low-speed devices behind one single-TT hub (`bDeviceProtocol`) | warning badge |
| Port errors | `port-statistics` overcurrent / enumeration-failure counters > 0 | red counter chip |

---

## 6. Identity & history

**Two-level identity [critique fix]:**
- *Device identity* = VID + PID + serial when a serial exists; otherwise VID + PID + **location path**, with diffs computed on the fallback marked **low-confidence** in the History tab (serial-less devices moving ports must not read as "new device"; two identical serial-less receivers must not collide silently).
- *Instance identity* = device identity + location path + sessionID.

History tab: persisted snapshots per device identity (`Application Support/Portree/history/`); on reconnect, diff descriptors, negotiated speed (retrain detection), and topology position — flag changes (the BadUSB signal). Empty state: "No history yet — this device will be tracked from now on."

---

## 7. UI design

### 7.1 Shell

`NavigationSplitView`: collapsible **sidebar outline**; detail = **graph canvas** (hero, default) with a segmented Outline/Graph picker; `.inspector(isPresented:)` (⌥⌘I) for the detail pane; `.safeAreaInset(edge: .bottom)` event-log drawer (toggleable). Toolbar: search field, filter toggles (hubs, HID, TB section), Refresh, legend (paintpalette), zoom controls. Commands menu: ⌘R refresh, ⌥⌘←/→ collapse/expand all, ⇧⌘E export JSON, ⌘+/⌘−/⌘0 zoom/fit, ⌘G search cycle.

### 7.2 Outline (sidebar)

**`OutlineGroup` + `DisclosureGroup(isExpanded: Binding)`** backed by the store's shared `Set<UInt64>` of collapsed IDs — *not* `List(children:)*, which owns its disclosure state privately and cannot sync with the graph or implement expand/collapse-all. **[critique fix, M2-blocking]** Sections: one per USB controller ("Receptacle N" naming via `usb-drdN` `port-number`), one per TB domain (labeled by Socket ID). Rows: class-symbol chip, name, speed badge. Empty children map to nil (no phantom chevrons).

### 7.3 Graph view (the hierarchy chart)

- **Layout**: hand-rolled Reingold–Tilford tidy tree — a pure function `(tree, collapsedIDs) → [ID: CGPoint]`, cached per snapshot. Left→right flow: controllers/domains left, leaves right.
- **Rendering**: `ScrollView([.horizontal, .vertical])` containing a `ZStack` whose **frame = layoutBounds × zoom** (plain `scaleEffect` inside a ScrollView breaks panning — the content size must actually change). **[critique fix]** One `Canvas` underlay draws rounded orthogonal connector elbows; node cards are `.position()`ed SwiftUI views above it.
- **Edges**: stroke **width by speed tier** (hairline 1.5 M → 6 pt TB5), **color by protocol generation**, dashed for Low/Full speed, midpoint speed label when zoom ≥ 60 % and node count ≤ 150.
- **Node cards**: rounded rect; tinted SF Symbol class chip; name (fallback chain below); speed capsule; badges — tunnel `bolt.horizontal`, serial-present, exclusive-owner, doctor warnings. Border color = speed tier. Merged hub twins: one card, two colored link stubs.
- **Fold**: collapsed nodes show a **"+N" pill**; relayout animates `.snappy`, siblings slide into freed space. Same `Set` drives outline and graph.
- **Pan/zoom**: ScrollView panning + `MagnifyGesture`, clamp 0.25–2.0; ⌘0 fit computes scale from layout bounds vs viewport **minus sidebar/inspector widths**.
- **Perf guards**: gate per-node glow/shadow and edge labels by node count (> 150) and zoom; debounce search-driven relayout per keystroke. `drawingGroup()` only if ever > 500 nodes.

### 7.4 Color & icon system

System colors (auto dark/light); **never color alone** — speed text is always visible; legend popover documents everything.

| Tier | Color | | Class | SF Symbol |
|---|---|---|---|---|
| USB 1.x (1.5/12 M) | `.gray` | | Hub | `cable.connector.horizontal` |
| USB 2.0 (480 M) | `.orange` | | HID | `keyboard` / `computermouse` |
| USB 3.x (5/10/20 G) | `.blue` | | Storage | `externaldrive` |
| USB4 (20–80 G) | `.purple` | | Audio | `mic` |
| Thunderbolt 3/4/5 | `.indigo` | | Camera/PTP | `camera` |
| Error / removed | `.red` | | Network | `network` |
| Infrastructure | `.secondary` | | Display/DP | `display` |
| | | | Controller | `cpu` |
| | | | Vendor/unknown | `questionmark.square.dashed` |

### 7.5 Inspector — four tabs **[graft from debug-depth proposal]**

1. **Decoded**: identity header (name, VID:PID hex + usb.ids names when available, class triple, bcdUSB, serial-if-present), Link (speed, port type, tunnel, retrain history), Power (sink mA vs port limit), Thunderbolt section (route string, UID hex, NVM, cable e-marker, orientation), ContainerID twin chip.
2. **Raw**: `Table` of *every* registry property — key / CF type / value; per-row copy; Copy All; OSData blobs (`UsbDeviceSignature`, `DROM`, EDID) open the **hex viewer**.
3. **Interfaces**: class triples, endpoint counts, alt setting, **`UsbExclusiveOwner` driver/pid**, bound driver stack.
4. **History**: replug diffs per §6, confidence-labeled.

### 7.6 Name fallback chain **[critique fix]**

`USB Product Name` → `kUSBVendorString` + VID:PID hex → `IORegistryEntryGetName` → class-derived label ("USB 3.1 Hub"). Controllers: "Receptacle N (bus B)". TB switches missing `Device Model Name`: vendor + UID short form. Never blank, never dependent on usb.ids (which is COULD).

### 7.7 Empty & error states **[critique fix]**

- Zero USB devices or `kr != 0`: full-canvas **self-diagnostic** view — device count per matching call, kr codes, SDK/OS versions, "compare with `ioreg -p IOUSB`" hint. (The OS already broke `SPUSBDataType` on this machine; if the IOKit walk itself ever returns zero, the app must say so loudly, not render a blank canvas.)
- Zero TB domains (Intel Macs / churn): TB section shows "No Thunderbolt domains found" with the same diagnostic affordance.
- Guarded-read degradation: missing decoded fields render as "—" with the Raw tab always available.
- Empty event log / History: one-line explanatory placeholders.

### 7.8 Persistence

`@AppStorage`: zoom, viewport, collapsed set (by stable identity), inspector tab, drawer visibility, filter toggles, nicknames (COULD). Event log and history per §§4–6.

---

## 8. Build system (no Xcode) — all **[verified]**

Everything goes through `make`; recipes run `/bin/bash` with `/usr/bin/swift` (the user's fish init aborts compound commands; plain `swift` is shadowed by a broken GVM hook).

```make
SDK := /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
SWIFT := /usr/bin/swift
TESTFLAGS := -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib

build:  sdkcheck ; SDKROOT=$(SDK) $(SWIFT) build
run:    sdkcheck ; SDKROOT=$(SDK) $(SWIFT) run
test:   sdkcheck ; SDKROOT=$(SDK) $(SWIFT) test $(TESTFLAGS)
release: sdkcheck ; SDKROOT=$(SDK) $(SWIFT) build -c release
app:    release ; scripts/make-app.sh "$$(SDKROOT=$(SDK) $(SWIFT) build -c release --show-bin-path)"
sdkcheck: ; @test -d $(SDK) || { echo "MacOSX26.sdk missing — see DESIGN.md §8 fallbacks"; exit 1; }
```

Why each line exists:
- **SDK pin**: the default `MacOSX27.0.sdk` makes `@State` & friends macros whose plugin (`libSwiftUIMacros.dylib`) ships **only with Xcode** → "plugin for module 'SwiftUIMacros' not found". The 26 SDK's `@State` is a plain property wrapper. Fallbacks if 26 disappears: the 26.5 SDK (also present), attribute-free `private var x = State(initialValue:…)` stored properties (SwiftUI finds `DynamicProperty` members by reflection), or installing Xcode.
- **SDKROOT doesn't fully propagate** to test bundles under the new build system (observed compiling against 26.5 despite the pin) — `sdkcheck` + the explicit flags keep this loud, and tests must tolerate either SDK.
- **`swift test`** without `TESTFLAGS` fails under CLT for *both* frameworks (swift-testing: TestingMacros plugin not found; XCTest: absent entirely). With the flag, swift-testing runs green. XCTest is banned.
- **`--show-bin-path`**: Swift 6.4's new build system outputs to `.build/out/Products/…`; never hardcode `.build/release`.

### App bundle (`scripts/make-app.sh`)

`Portree.app/Contents/{MacOS,Resources}`; binary → `Contents/MacOS/Portree`; `Info.plist`: `CFBundlePackageType=APPL`, `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleName`, `CFBundleShortVersionString`, `LSMinimumSystemVersion=15.0`, `NSPrincipalClass=NSApplication`, `NSHighResolutionCapable=true`, `CFBundleIconFile=AppIcon` — and **no `LSUIElement`** (it hides the Dock icon). Icon: `sips -z` size set → `iconutil -c icns`. Sign: `codesign --force --sign - Portree.app` (ad-hoc; personal use needs no notarization).

**SwiftPM-executable gotcha [verified]:** without a bundle the process launches as a background app — `@NSApplicationDelegateAdaptor` must call `NSApp.setActivationPolicy(.regular)` + `NSApp.activate(ignoringOtherApps: true)` in `applicationDidFinishLaunching` (kept in the bundled app too; harmless).

Package.swift: `platforms: [.macOS(.v15)]`, PortreeCore gets `linkerSettings: [.linkedFramework("IOKit")]`.

---

## 9. Testing strategy

swift-testing only (see §8). Unit targets, all headless in PortreeCore:
- `Format` fixtures: 10 Gbps Int64 (truncation trap), Dell signed UID → `0x8087B6DC08810300`, NVM `(68,3) → "44.3"`, locationID nibble paths, speed-tier mapping incl. swapped Full/Low enums.
- Topology builders against **recorded snapshot fixtures** (serialized `PropertyValue` trees captured from this machine) — twin-merge guards, union-of-children, canonical IDs; TB route-string/depth cross-checks.
- DiffEngine: arrival/removal/re-enumeration classification incl. the replug (new entry ID, same identity) case.
- Doctor rules against synthetic trees (throttled chain, oversubscribed port, single-TT contention).
- Identity: fallback-key drift cases (serial-less device moves port ⇒ low-confidence, not "new device").

Manual verification per milestone: compare against `ioreg -p IOUSB` / `ioreg -l` output; replug the Shure MV7+ and the Dell chain; sleep/wake cycle.

---

## 10. Decisions log (things deliberately dropped or deferred)

| Decision | Reason |
|---|---|
| No endpoint descriptors in v1 | Not in registry; needs `IOServiceOpen`, blocked by exclusive owners |
| No eject/rename/device actions | Viewer stays read-only; zero entitlements |
| No sounds | Personal preference; event log covers the need |
| `system_profiler` never used for USB; TB enrichment optional + failure-ignored | `SPUSBDataType` returns `[]` on this machine **[verified twice]** |
| Renamed to **Portree** (2026-10-07) | "Hubble" is the commercial app's name |

---

## 11. M7 — System & bandwidth layer, Toolbox (added 2026-10-07)

**PCIe tree.** Enumerate `IOPCIDevice` + bridge nodes; decode `IOPCIExpressLinkStatus`/`IOPCIExpressLinkCapabilities` → link generation (2.5/5/8/16/32 GT/s) and lane width (x1/x2/x4…); bus/device/function from `reg`. Cross-links: tunneled devices via `IOPCITunnelled` + `Thunderbolt Entry ID` (§3.3) back to the carrying TB port; USB controllers that are PCIe functions link to their PCIe node. On Apple Silicon the built-in XHCIs are **SoC-fabric devices, not PCIe** — label them so; only tunneled/bridged devices get a PCIe path.

**System root node.** SoC name (`machdep.cpu.brand_string`), core counts, memory via sysctl; parents the USB controllers, TB domains, and PCIe bridges. No public API exposes internal fabric utilization — the node is static context only.

**Bandwidth overlay** (OFF by default; toolbar toggle + ⌥⌘B):
- *Allocated layer* (registry truth): per-link negotiated speed vs upstream capacity ratio bar; TB per-tunnel allocations from lane-port `Hop Table` + `Maximum/Required Bandwidth Allocated`; DP tunnels = `LinkRate × LaneCount`; USB3 tunnel allocation from the USB "Gen T" adapter.
- *Live layer* (best-effort, 1 Hz polling **only while overlay is on**): storage = `IOBlockStorageDriver` Statistics byte deltas; NICs = matching `en*` interface counters (registry path ↔ BSD name); controllers = `controller-statistics` deltas. No counter → "n/a", never estimated.

**Toolbox pane** (⌘T): curated commands grouped Inspect / Live logs / Thunderbolt / Power — each with description, Copy, and Run-in-app (via `Process`, read-only commands only; sudo ones copy-only). Initial set: `ioreg -p IOUSB -l -w0`, `ioreg -c IOUSBHostDevice -l`, `ioreg -c IOThunderboltSwitch -l -w0`, `ioreg -c IOPCIDevice -l`, `system_profiler SPThunderboltDataType -json`, `log stream --predicate 'subsystem CONTAINS "usb"' --style compact`, `log show --last 5m --predicate 'eventMessage CONTAINS[c] "thunderbolt"'`, `pmset -g`, `sudo dmesg` (copy-only).
