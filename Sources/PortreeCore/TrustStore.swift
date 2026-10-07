import Foundation

/// One device the user has seen and accepted on this Mac.
public struct KnownDevice: Sendable, Codable, Hashable {
    /// `DeviceNode.deviceIdentity` key (vid:pid:serial, vid:pid@location,
    /// or tb:UID).
    public let key: String
    public let vendorID: Int64?
    public let productID: Int64?
    /// Whether the key was serial-backed when learned — gates the
    /// vid:pid fallback match for serial-less devices that move ports.
    public let hasSerial: Bool
    public let name: String
    public let firstSeen: Date

    public init(key: String, vendorID: Int64?, productID: Int64?, hasSerial: Bool, name: String, firstSeen: Date = Date()) {
        self.key = key
        self.vendorID = vendorID
        self.productID = productID
        self.hasSerial = hasSerial
        self.name = name
        self.firstSeen = firstSeen
    }
}

/// Persistent registry of every USB/TB device this Mac has been told to
/// trust — the data half of the "unknown device" guard. JSON under
/// Application Support/Portree; absence of the file means the baseline has
/// not been learned yet (first launch trusts everything currently attached).
public final class TrustStore {

    public private(set) var devices: [KnownDevice]
    /// False until the first learn pass has run (no store file on disk).
    public private(set) var hasBaseline: Bool

    private let fileURL: URL?
    private var byKey: [String: KnownDevice]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? Self.decoder.decode([KnownDevice].self, from: data) {
            devices = decoded
            hasBaseline = true
        } else {
            devices = []
            hasBaseline = false
        }
        byKey = Dictionary(uniqueKeysWithValues: devices.map { ($0.key, $0) })
    }

    public static func defaultFileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Portree", isDirectory: true)
            .appendingPathComponent("known-devices.json")
    }

    /// Exact identity match, with one deliberate relaxation: a serial-less
    /// device moved to another port keeps its trust if the same vid:pid was
    /// learned serial-less. A serial-less clone of a serial-bearing known
    /// device does NOT pass — that asymmetry is the point.
    public func isKnown(_ node: DeviceNode) -> Bool {
        guard let identity = node.deviceIdentity else { return true } // no identity → can't track
        if byKey[identity.key] != nil { return true }
        if !identity.confident, let vid = node.vendorID, let pid = node.productID {
            return devices.contains { !$0.hasSerial && $0.vendorID == vid && $0.productID == pid }
        }
        return false
    }

    /// Add one device (no-op when already known). Returns true if it was new.
    @discardableResult
    public func trust(_ node: DeviceNode) -> Bool {
        guard let identity = node.deviceIdentity, byKey[identity.key] == nil else { return false }
        let entry = KnownDevice(
            key: identity.key,
            vendorID: node.vendorID,
            productID: node.productID,
            hasSerial: node.serialNumber?.isEmpty == false,
            name: node.name
        )
        devices.append(entry)
        byKey[entry.key] = entry
        return true
    }

    /// Learn pass: trust every trackable device in the snapshot and persist.
    /// Returns how many were newly added.
    @discardableResult
    public func learn(from snapshot: Snapshot) -> Int {
        var added = 0
        for root in snapshot.usbRoots + snapshot.tbRoots {
            for node in root.flattened() where node.kind == .usbDevice || node.kind == .tbSwitch {
                if trust(node) { added += 1 }
            }
        }
        hasBaseline = true
        save()
        return added
    }

    public func save() {
        hasBaseline = true
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? Self.encoder.encode(devices) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
