import Foundation
import IOKit

/// A raw add/remove event, generated from iterator drains BEFORE the rescan
/// debounce — bounce storms coalesce the rescan, never the log.
public struct RawEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case added, removed
    }
    public let kind: Kind
    public let entryID: UInt64
    public let name: String
    public let className: String
    public let isThunderbolt: Bool
    public let date: Date
}

/// Owns the IONotificationPort and every registration for the app's lifetime.
/// Rules learned the hard way (all verified):
///  - each IOServiceAddMatchingNotification consumes its matching dict — one
///    fresh dict per call;
///  - a notification arms only once its iterator is drained, and callbacks
///    must drain to re-arm; the first drain IS the initial population;
///  - USB uses kIOFirstMatch, Thunderbolt classes use kIOFirstPublish;
///  - everything IOKit happens on one serial queue; only Sendable snapshots
///    leave it.
public final class HotplugMonitor: @unchecked Sendable {

    public typealias EventsHandler = @Sendable ([RawEvent]) -> Void
    public typealias SnapshotHandler = @Sendable (Snapshot) -> Void

    private let queue = DispatchQueue(label: "portree.iokit")
    private var notifyPort: IONotificationPortRef?
    private var registrations: [Registration] = []
    private var pendingRescan: DispatchWorkItem?
    private let onEvents: EventsHandler
    private let onSnapshot: SnapshotHandler

    // Matching-notification constants (string macros don't import from C).
    private static let firstMatch = "IOServiceFirstMatch"
    private static let firstPublish = "IOServiceFirstPublish"
    private static let terminated = "IOServiceTerminate"

    final class Registration {
        unowned let monitor: HotplugMonitor
        let kind: RawEvent.Kind
        let isThunderbolt: Bool
        var iterator: io_iterator_t = 0

        init(monitor: HotplugMonitor, kind: RawEvent.Kind, isThunderbolt: Bool) {
            self.monitor = monitor
            self.kind = kind
            self.isThunderbolt = isThunderbolt
        }
    }

    public init(onEvents: @escaping EventsHandler, onSnapshot: @escaping SnapshotHandler) {
        self.onEvents = onEvents
        self.onSnapshot = onSnapshot
    }

    public func start() {
        queue.async { self.startOnQueue() }
    }

    /// Manual refresh (⌘R) — belt-and-braces against silent disarm.
    public func rescan() {
        queue.async { self.rescanNow() }
    }

    private func startOnQueue() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        register("IOUSBHostDevice", type: Self.firstMatch, kind: .added, thunderbolt: false)
        register("IOUSBHostDevice", type: Self.terminated, kind: .removed, thunderbolt: false)
        register("IOThunderboltSwitch", type: Self.firstPublish, kind: .added, thunderbolt: true)
        register("IOThunderboltSwitch", type: Self.terminated, kind: .removed, thunderbolt: true)
        register("IOThunderboltPort", type: Self.firstPublish, kind: .added, thunderbolt: true)
        register("IOThunderboltPort", type: Self.terminated, kind: .removed, thunderbolt: true)

        rescanNow()
    }

    private func register(_ className: String, type: String, kind: RawEvent.Kind, thunderbolt: Bool) {
        guard let port = notifyPort, let matching = IOServiceMatching(className) else { return }
        let registration = Registration(monitor: self, kind: kind, isThunderbolt: thunderbolt)
        registrations.append(registration)

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let registration = Unmanaged<Registration>.fromOpaque(refcon).takeUnretainedValue()
            registration.monitor.drain(iterator, registration: registration, isInitial: false)
        }

        var iterator: io_iterator_t = 0
        let kr = IOServiceAddMatchingNotification(
            port, type, matching, callback,
            Unmanaged.passUnretained(registration).toOpaque(), &iterator
        )
        guard kr == KERN_SUCCESS else { return }
        registration.iterator = iterator
        drain(iterator, registration: registration, isInitial: true)
    }

    private func drain(_ iterator: io_iterator_t, registration: Registration, isInitial: Bool) {
        var events: [RawEvent] = []
        while true {
            let object = IOIteratorNext(iterator)
            if object == 0 { break }
            events.append(RawEvent(
                kind: registration.kind,
                entryID: Registry.entryID(of: object),
                name: Registry.name(of: object),
                className: Registry.className(of: object),
                isThunderbolt: registration.isThunderbolt,
                date: Date()
            ))
            IOObjectRelease(object)
        }
        guard !isInitial else { return }  // initial drain only arms + populates via rescan
        if !events.isEmpty {
            // IOThunderboltPort events are extremely chatty per plug; surface
            // only device-level rows, but let every event trigger a rescan.
            let visible = events.filter { !($0.isThunderbolt && $0.className.contains("Port")) }
            if !visible.isEmpty { onEvents(visible) }
            scheduleRescan()
        }
    }

    private func scheduleRescan() {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescanNow() }
        pendingRescan = work
        queue.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    private func rescanNow() {
        onSnapshot(Snapshot.capture())
    }
}
